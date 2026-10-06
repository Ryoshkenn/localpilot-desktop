import Foundation
import Testing
@testable import LocalPilotDesktop

actor MockHTTPClient: HTTPClient {
    private(set) var requests: [HTTPRequest] = []
    var responses: [HTTPResponse] = []
    /// Responses keyed by URL, used before falling back to the queue.
    var routes: [String: HTTPResponse] = [:]

    func enqueue(_ response: HTTPResponse) {
        responses.append(response)
    }

    func route(_ url: String, _ response: HTTPResponse) {
        routes[url] = response
    }

    func data(for request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if let routed = routes[request.url.absoluteString] {
            return routed
        }
        if responses.isEmpty {
            throw URLError(.cannotConnectToHost)
        }
        return responses.removeFirst()
    }
}

private func json(_ string: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(data: Data(string.utf8), statusCode: status)
}

private func completion(_ content: String) -> HTTPResponse {
    let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
    return json(#"{"choices":[{"message":{"role":"assistant","content":\#(escaped)}}]}"#)
}

private let base = URL(string: "http://127.0.0.1:1234/v1")!

private func makeProvider(_ client: MockHTTPClient, model: String = "qwen3.5-4b") -> OpenAICompatibleProvider {
    OpenAICompatibleProvider(
        baseURL: base,
        configuration: ModelProviderConfiguration(providerName: "local_server", modelName: model, temperature: 0.1, timeoutSeconds: 42),
        httpClient: client
    )
}

struct OpenAICompatibleProviderTests {
    @Test
    func completeSendsChatRequestAndReturnsContent() async throws {
        let client = MockHTTPClient()
        await client.enqueue(completion("hello"))
        let provider = makeProvider(client)

        let reply = try await provider.complete(prompt: "hi", system: "be brief", format: nil)

        #expect(reply == "hello")
        let request = try #require(await client.requests.first)
        #expect(request.url.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
        #expect(request.method == "POST")
        #expect(request.timeoutSeconds == 42)
        let body = try #require(request.jsonBody)
        #expect(body["model"] as? String == "qwen3.5-4b")
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(body["response_format"] == nil)
    }

    @Test
    func jsonSchemaFormatBecomesResponseFormat() async throws {
        let client = MockHTTPClient()
        await client.enqueue(completion("{}"))
        let provider = makeProvider(client)

        _ = try await provider.complete(prompt: "p", system: nil, format: .jsonSchema(name: "localpilot_plan", schema: StructuredOutputSchema.plan))

        let body = try #require(await client.requests.first?.jsonBody)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["name"] as? String == "localpilot_plan")
        #expect(schema["schema"] is [String: Any])
    }

    @Test
    func rejectedResponseFormatIsRetriedWithoutIt() async throws {
        let client = MockHTTPClient()
        await client.enqueue(json(#"{"error":"response_format not supported"}"#, status: 400))
        await client.enqueue(completion("ok"))
        let provider = makeProvider(client)

        let reply = try await provider.complete(prompt: "p", system: nil, format: .jsonSchema(name: "x", schema: StructuredOutputSchema.action))

        #expect(reply == "ok")
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests[0].jsonBody?["response_format"] != nil)
        #expect(requests[1].jsonBody?["response_format"] == nil)
    }

    @Test
    func serverErrorsSurfaceStatusAndBody() async throws {
        let client = MockHTTPClient()
        await client.enqueue(json("model crashed", status: 500))
        let provider = makeProvider(client)

        await #expect(throws: ModelProviderError.badStatus(500, "model crashed")) {
            try await provider.complete(prompt: "p", system: nil, format: nil)
        }
    }

    @Test
    func unreadableCompletionIsInvalidResponse() async throws {
        let client = MockHTTPClient()
        await client.enqueue(json(#"{"unexpected":true}"#))
        let provider = makeProvider(client)

        await #expect(throws: ModelProviderError.invalidResponse) {
            try await provider.complete(prompt: "p", system: nil, format: nil)
        }
    }

    @Test
    func emptyModelNameFailsFast() async throws {
        let client = MockHTTPClient()
        let provider = makeProvider(client, model: "")

        await #expect(throws: ModelProviderError.noModelSelected) {
            try await provider.complete(prompt: "p", system: nil, format: nil)
        }
        #expect(await client.requests.isEmpty)
    }

    @Test
    func healthCheckRequiresTheModelToBeServed() async throws {
        let client = MockHTTPClient()
        await client.route("http://127.0.0.1:1234/v1/models", json(#"{"data":[{"id":"holo-3.1-4b"}]}"#))

        try await makeProvider(client, model: "holo-3.1-4b").healthCheck()
        await #expect(throws: ModelProviderError.modelNotAvailable("qwen3.5-4b")) {
            try await makeProvider(client, model: "qwen3.5-4b").healthCheck()
        }
    }

    @Test
    func replyInReasoningFieldIsRecovered() throws {
        // LM Studio routes a thinking model's whole reply to reasoning_content.
        let data = Data(#"{"choices":[{"message":{"content":"","reasoning_content":"{\"actions\":[]}"},"finish_reason":"stop"}]}"#.utf8)
        #expect(try OpenAICompatibleProvider.decodeContent(data) == #"{"actions":[]}"#)
    }

    @Test
    func contentWinsWhenItHoldsTheJson() throws {
        let data = Data(#"{"choices":[{"message":{"content":"\n{\"ok\":true}","reasoning_content":"thinking {about} it"},"finish_reason":"stop"}]}"#.utf8)
        #expect(try OpenAICompatibleProvider.decodeContent(data) == "\n{\"ok\":true}")
    }

    @Test
    func thinkingThatExhaustsTheBudgetIsReported() {
        let data = Data(#"{"choices":[{"message":{"content":"","reasoning_content":"hmm, let me think"},"finish_reason":"length"}]}"#.utf8)
        #expect(throws: ModelProviderError.outOfTokens) {
            try OpenAICompatibleProvider.decodeContent(data)
        }
    }

    @Test
    func requestAsksHybridModelsToSkipThinking() async throws {
        let client = MockHTTPClient()
        await client.enqueue(completion("{}"))
        _ = try await makeProvider(client).complete(prompt: "p", system: nil, format: nil)

        let body = try #require(await client.requests.first?.jsonBody)
        let kwargs = try #require(body["chat_template_kwargs"] as? [String: Any])
        #expect(kwargs["enable_thinking"] as? Bool == false)
    }

    @Test
    func discoveryReportsRespondingServersAndHidesEmbeddingModels() async {
        let client = MockHTTPClient()
        await client.route("http://127.0.0.1:1234/v1/models", json(#"{"data":[{"id":"qwen3.5-4b"},{"id":"text-embedding-nomic"}]}"#))
        await client.route("http://127.0.0.1:11434/v1/models", json(#"{"data":[{"id":"holo:4b"}]}"#))
        await client.route("http://10.0.0.5:9000/v1/models", json(#"{"data":[]}"#))

        let servers = await LocalModelDiscovery.discover(extra: [URL(string: "http://10.0.0.5:9000/v1")!], httpClient: client)

        #expect(servers.map(\.name) == ["LM Studio", "Ollama", "Custom server"])
        #expect(servers[0].models == ["qwen3.5-4b"])
        #expect(servers[1].models == ["holo:4b"])
        #expect(servers[2].models.isEmpty)
    }
}

struct StructuredOutputSchemaTests {
    @Test
    func actionSchemaParsesAndDescribesTheActionShape() throws {
        let json = StructuredOutputSchema.action
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        #expect(object["type"] as? String == "object")
        #expect(object["additionalProperties"] as? Bool == false)

        let properties = try #require(object["properties"] as? [String: Any])
        // target_element_id must be present so element-targeting survives the
        // structured-output constraint.
        #expect(properties["id"] != nil)

        let typeProperty = try #require(properties["type"] as? [String: Any])
        let typeEnum = try #require(typeProperty["enum"] as? [String])
        #expect(typeEnum.contains("click"))
        #expect(typeEnum.contains("observe"))
        // The enum is derived from ActionType.allCases, so every case appears.
        #expect(typeEnum.count == ActionType.allCases.count)
    }

    @Test
    func planSchemaWrapsActionsArrayWithBounds() throws {
        let json = StructuredOutputSchema.plan
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let properties = try #require(object["properties"] as? [String: Any])
        let actions = try #require(properties["actions"] as? [String: Any])
        #expect(actions["type"] as? String == "array")
        #expect(actions["minItems"] == nil)
        #expect(properties["reply"] != nil)
        #expect(properties["todo"] != nil)
        #expect(actions["maxItems"] as? Int == 6)
        #expect(actions["items"] is [String: Any])
    }
}

struct ScreenshotRequestTests {
    @Test
    func plannerForwardsImageInMultimodalContent() async throws {
        let client = MockHTTPClient()
        await client.enqueue(completion(#"{"reply":"I see the screen."}"#))
        let planner = JSONActionPlanner(provider: makeProvider(client))
        var context = AgentContext.empty
        context.screenshot = ScreenshotAttachment(jpegBase64: "aW1hZ2U=", pixelWidth: 1280, pixelHeight: 720, pointWidth: 1920, pointHeight: 1080)
        let response = try await planner.proposeResponse(originalTask: "Look", context: context, recentMessages: [])
        #expect(response.reply == "I see the screen.")
        let body = try #require(await client.requests.first?.jsonBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "text")
        #expect((content[0]["text"] as? String)?.contains("0-1000") == true)
        let image = try #require(content[1]["image_url"] as? [String: Any])
        #expect(image["url"] as? String == "data:image/jpeg;base64,aW1hZ2U=")
    }
}
