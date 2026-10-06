import Foundation
import Testing
@testable import LocalPilotDesktop

private func nativeProvider(_ client: MockHTTPClient) -> OpenAICompatibleProvider {
    OpenAICompatibleProvider(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, configuration: ModelProviderConfiguration(providerName: "fixture", modelName: "fixture", temperature: 0.1, timeoutSeconds: 2), httpClient: client)
}

private func nativeReply(_ text: String? = nil, calls: [NativeToolCall] = [], finish: String = "stop", reasoning: String? = nil) throws -> HTTPResponse {
    let message = NativeMessage(role: "assistant", content: text, toolCalls: calls, reasoningContent: reasoning)
    return HTTPResponse(data: try JSONSerialization.data(withJSONObject: ["choices": [["message": message.payload, "finish_reason": finish]]]), statusCode: 200)
}

private func call(_ name: String, _ arguments: String = "{}", id: String = "call_1") -> NativeToolCall {
    NativeToolCall(id: id, function: .init(name: name, arguments: arguments))
}

struct NativeToolTransportTests {
    @Test
    func normalTextUsesToolsAutoWithoutCustomReplySchemaOrThinkingOverride() async throws {
        let client = MockHTTPClient()
        await client.enqueue(try nativeReply("Hi!"))
        let response = try await nativeProvider(client).respond(messages: [NativeMessage(role: "user", content: "hi")], tools: NativeToolRegistry.definitions)
        #expect(response.content == "Hi!")
        #expect(response.toolCalls.isEmpty)
        let body = try #require(await client.requests.first?.jsonBody)
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["parallel_tool_calls"] as? Bool == false)
        #expect(body["response_format"] == nil)
        #expect(body["chat_template_kwargs"] == nil)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == NativeToolRegistry.definitions.count)
        let open = try #require(tools[0]["function"] as? [String: Any])
        #expect(open["name"] as? String == "open_app")
    }

    @Test
    func nullContentWithToolCallsAndReasoningIsPreserved() throws {
        let requested = call("open_app", #"{"name":"Notes"}"#)
        let response = try OpenAICompatibleProvider.decodeNativeResponse(nativeReply(calls: [requested], finish: "tool_calls", reasoning: "private reasoning").data)
        #expect(response.content == nil)
        #expect(response.toolCalls == [requested])
        #expect(response.reasoningContent == "private reasoning")
    }

    @Test
    func partialAndDuplicateCallsAreRejectedBeforeExecution() throws {
        #expect(throws: NativeToolError.self) {
            try OpenAICompatibleProvider.decodeNativeResponse(nativeReply(calls: [call("open_app", "{")], finish: "length").data)
        }
        #expect(throws: NativeToolError.self) {
            try OpenAICompatibleProvider.decodeNativeResponse(nativeReply(calls: [call("observe"), call("screenshot")]).data)
        }
        #expect(throws: NativeToolError.self) {
            try OpenAICompatibleProvider.decodeNativeResponse(nativeReply("Done", finish: "tool_calls").data)
        }
    }

    @Test
    func unsupportedServerDoesNotSilentlyRemoveTools() async throws {
        let client = MockHTTPClient()
        await client.enqueue(HTTPResponse(data: Data("tools not supported".utf8), statusCode: 400))
        await #expect(throws: ModelProviderError.self) {
            try await nativeProvider(client).respond(messages: [NativeMessage(role: "user", content: "hi")], tools: NativeToolRegistry.definitions)
        }
        #expect(await client.requests.count == 1)
    }

    @Test
    func schemasAreSmallSeparateAndComplete() throws {
        #expect(NativeToolRegistry.definitions.count < 20)
        #expect(Set(NativeToolRegistry.definitions.map(\.name)).count == NativeToolRegistry.definitions.count)
        let fixtures = [
            "open_app": #"{"name":"Notes"}"#, "observe": #"{"mode":"app_state"}"#,
            "click": #"{"id":1}"#, "double_click": #"{"x":10,"y":20}"#,
            "type_text": #"{"id":2,"text":"hello"}"#, "press_key": #"{"key":"cmd+a"}"#,
            "scroll": #"{"lines":-5,"id":3}"#, "browser_new_tab": "{}",
            "browser_navigate": #"{"url":"https://example.com"}"#,
            "browser_switch_tab": #"{"tab":2}"#, "browser_close_tab": #"{"tab":2}"#,
            "wait": "{}", "update_todo": #"{"items":["Fill form"]}"#,
            "web_search": #"{"query":"swift actors"}"#, "read_webpage": #"{"url":"https://example.com"}"#
        ]
        for tool in NativeToolRegistry.definitions {
            let args = try #require(fixtures[tool.name])
            _ = try tool.decode(arguments: args)
            let function = try #require(tool.payload["function"] as? [String: Any])
            let schema = try #require(function["parameters"] as? [String: Any])
            #expect(schema["additionalProperties"] as? Bool == false)
            #expect((schema["properties"] as? [String: Any])?["type"] == nil)
        }
    }

    @Test(arguments: [call("click", #"{"x":1}"#), call("click", #"{"id":1,"x":1,"y":2}"#), call("open_app", #"{"name":null}"#), call("open_app", #"{"name":"Notes","command":"rm"}"#), call("browser_switch_tab", #"{"tab":1.5}"#), call("unknown"), call("type_text", "broken json")])
    func invalidArgumentsAreRejected(_ requested: NativeToolCall) {
        #expect(throws: NativeToolError.self) { try NativeToolRegistry.resolve(requested) }
    }

    @Test
    func nativeModeIsDefaultAndCompatibilityChoicePersists() throws {
        #expect(AppSettings.defaultValue.toolCallingMode == .native)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).toolCallingMode == .native)
        var settings = AppSettings.defaultValue
        settings.toolCallingMode = .jsonCompatibility
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).toolCallingMode == .jsonCompatibility)
    }
}

@MainActor
struct NativeToolSessionTests {
    @Test
    func toolResultKeepsCallIDAndImageContextInNextRequest() async throws {
        let client = MockHTTPClient()
        let requested = call("open_app", #"{"name":"Notes"}"#, id: "server_id_42")
        await client.enqueue(try nativeReply("I'll open Notes.", calls: [requested], finish: "tool_calls", reasoning: "model reasoning"))
        await client.enqueue(try nativeReply("Notes is open."))
        let chat = [ChatMessage(role: .user, text: "Open Notes")]
        let session = NativeToolSession(provider: nativeProvider(client), conversation: chat, dryRun: false)
        let first = try await session.next(context: .empty, conversation: chat)
        let action = try #require(first.actions.first)
        #expect(action.type == .switchApp)
        #expect(first.reply == nil)
        #expect(session.preamble == "I'll open Notes.")
        session.complete(action: action, result: "Opened Notes.")
        var context = AgentContext.empty
        context.screenshot = ScreenshotAttachment(jpegBase64: "aW1hZ2U=", pixelWidth: 1280, pixelHeight: 720, pointWidth: 1920, pointHeight: 1080)
        let second = try await session.next(context: context, conversation: chat)
        #expect(second.reply == "Notes is open.")
        let body = try #require(await client.requests.last?.jsonBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool", "user"])
        #expect(messages[2]["reasoning_content"] as? String == "model reasoning")
        #expect(messages[3]["tool_call_id"] as? String == "server_id_42")
        #expect(messages[3]["content"] as? String == "Opened Notes.")
        let imageParts = try #require(messages[4]["content"] as? [[String: Any]])
        #expect(imageParts[1]["type"] as? String == "image_url")
    }

    @Test
    func invalidToolAndAbandonedToolEachReceiveAResult() async throws {
        let client = MockHTTPClient()
        await client.enqueue(try nativeReply(calls: [call("unknown", id: "bad")]))
        await client.enqueue(try nativeReply(calls: [call("observe", #"{"mode":"app_state"}"#, id: "skipped")]))
        await client.enqueue(try nativeReply("Paused action wasn't executed."))
        let chat = [ChatMessage(role: .user, text: "Look")]
        let session = NativeToolSession(provider: nativeProvider(client), conversation: chat, dryRun: true)
        #expect(try await session.next(context: .empty, conversation: chat).actions.isEmpty)
        #expect(try await session.next(context: .empty, conversation: chat).actions.count == 1)
        _ = try await session.next(context: .empty, conversation: chat)
        let results = session.messages.filter { $0.role == "tool" }
        #expect(results.map(\.toolCallID) == ["bad", "skipped"])
        #expect(results.allSatisfy { $0.content?.contains("Not executed") == true })
    }

    @Test
    func parallelRequestsAreReturnedAsUnexecutedResults() async throws {
        let client = MockHTTPClient()
        await client.enqueue(try nativeReply(calls: [call("observe", id: "one"), call("screenshot", id: "two")]))
        let session = NativeToolSession(provider: nativeProvider(client), conversation: [], dryRun: true)
        let response = try await session.next(context: .empty, conversation: [])
        #expect(response.actions.isEmpty)
        #expect(session.messages.filter { $0.role == "tool" }.map(\.toolCallID) == ["one", "two"])
    }

    @Test
    func optionalTodoUsesNativeToolResults() async throws {
        let client = MockHTTPClient()
        await client.enqueue(try nativeReply(calls: [call("update_todo", #"{"items":["Open app","Fill form"]}"#)]))
        let session = NativeToolSession(provider: nativeProvider(client), conversation: [], dryRun: true)
        let response = try await session.next(context: .empty, conversation: [])
        #expect(response.todo == ["Open app", "Fill form"])
        #expect(response.actions.isEmpty)
        session.completeChecklist()
        #expect(session.messages.last?.role == "tool")
    }
}

/// Fixture playback only: no model server, screenshots, or live OS actions.
@MainActor
struct NativeToolRoutingTests {
    @Test(arguments: [false, true])
    func cannedNativeMessagesRouteIntoChatAndExecution(computerTask: Bool) async throws {
        let client = MockHTTPClient()
        await client.route("http://127.0.0.1:1234/v1/models", HTTPResponse(data: Data(#"{"data":[{"id":"fixture"}]}"#.utf8), statusCode: 200))
        if computerTask { await client.enqueue(try nativeReply(calls: [call("open_app", #"{"name":"Notes"}"#)], finish: "tool_calls")) }
        await client.enqueue(try nativeReply(computerTask ? "Dry run: Notes would open." : "Hi!"))
        let observer = CountingScreenObserver()
        let spy = SpyComputerController()
        let controller = AgentController(logger: LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "native-log-\(UUID()).jsonl")), settingsStore: SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "native-settings-\(UUID()).json")), screenObserver: observer, executor: LocalPilotActionExecutor(screenObserver: observer, computerController: spy), httpClient: client)
        controller.selectModel("fixture", on: LocalModelServer(name: "fixture", baseURL: URL(string: "http://127.0.0.1:1234/v1")!, models: ["fixture"]))
        controller.start(task: computerTask ? "Open Notes" : "hi")
        for _ in 0..<100 where controller.runStatus.isActive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.runStatus == .done)
        #expect(controller.messages.last?.text == (computerTask ? "Dry run: Notes would open." : "Hi!"))
        #expect(controller.stepCount == (computerTask ? 1 : 0))
        #expect(await spy.switchedApps.isEmpty)
        #expect(controller.overlayState == .idle)
        if !computerTask { #expect(observer.captures == 0); #expect(observer.screenshots == 0) }
        let requests = await client.requests.filter { $0.url.path.hasSuffix("completions") }
        #expect(requests.count == (computerTask ? 2 : 1))
        if computerTask {
            let messages = try #require(requests.last?.jsonBody?["messages"] as? [[String: Any]])
            let result = try #require(messages.first { $0["role"] as? String == "tool" })
            #expect(result["tool_call_id"] as? String == "call_1")
            #expect((result["content"] as? String)?.contains("Dry-run") == true)
        }
    }
}

@MainActor
final class PictureScreenObserver: ScreenObserving {
    var areas: [ScreenshotArea] = []
    func capture() async -> ScreenObservation {
        ScreenObservation(activeApp: "Chrome", activeWindow: "Test", screenshotWidth: nil, screenshotHeight: nil, screenshotPNGBase64: nil, accessibilitySummary: nil)
    }
    func captureScreenshot(maxWidth: Int) async -> ScreenshotAttachment? { nil }
    func captureScreenshot(maxWidth: Int, area: ScreenshotArea) async -> ScreenshotAttachment? {
        areas.append(area)
        return ScreenshotAttachment(jpegBase64: "aW1hZ2U=", pixelWidth: 800, pixelHeight: 600, pointWidth: 400, pointHeight: 300, originX: 50, originY: 60, area: area)
    }
}

@MainActor
struct ObserveScreenshotTests {
    @Test
    func observeScreenshotReturnsThePictureWithItsOwnResult() async throws {
        let client = MockHTTPClient()
        await client.route("http://127.0.0.1:1234/v1/models", HTTPResponse(data: Data(#"{"data":[{"id":"fixture"}]}"#.utf8), statusCode: 200))
        await client.enqueue(try nativeReply(calls: [call("observe", #"{"mode":"screenshot"}"#, id: "look")], finish: "tool_calls"))
        await client.enqueue(try nativeReply(calls: [call("observe", #"{"mode":"screenshot","area":"screen"}"#, id: "again")], finish: "tool_calls"))
        await client.enqueue(try nativeReply("I can see the page."))
        let observer = PictureScreenObserver()
        let spy = SpyComputerController()
        let controller = AgentController(logger: LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "shot-log-\(UUID()).jsonl")), settingsStore: SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "shot-settings-\(UUID()).json")), screenObserver: observer, executor: LocalPilotActionExecutor(screenObserver: observer, computerController: spy), httpClient: client)
        controller.selectModel("fixture", on: LocalModelServer(name: "fixture", baseURL: URL(string: "http://127.0.0.1:1234/v1")!, models: ["fixture"]))
        controller.start(task: "What's on the page?")
        for _ in 0..<200 where controller.runStatus.isActive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.runStatus == .done)
        #expect(observer.areas == [.window, .screen])
        #expect(controller.stepScreenshots.count == 2)

        let requests = await client.requests.filter { $0.url.path.hasSuffix("completions") }
        let messages = try #require(requests.last?.jsonBody?["messages"] as? [[String: Any]])
        // Each result is followed directly by its picture...
        let lookIndex = try #require(messages.firstIndex { $0["tool_call_id"] as? String == "look" })
        #expect((messages[lookIndex]["content"] as? String)?.contains("front window") == true)
        let againIndex = try #require(messages.firstIndex { $0["tool_call_id"] as? String == "again" })
        let picture = try #require(messages[againIndex + 1]["content"] as? [[String: Any]])
        #expect(picture.contains { $0["type"] as? String == "image_url" })
        // ...and only the newest picture stays in the context.
        let images = messages.filter { ($0["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image_url" } == true }
        #expect(images.count == 1)
        #expect((messages[lookIndex + 1]["content"] as? String)?.contains("out of date") == true)
    }
}

@MainActor
struct PictureFirstTests {
    @Test
    func afterAnActionTheModelGetsAPictureInsteadOfAnElementList() async throws {
        let client = MockHTTPClient()
        await client.route("http://127.0.0.1:1234/v1/models", HTTPResponse(data: Data(#"{"data":[{"id":"fixture"}]}"#.utf8), statusCode: 200))
        await client.enqueue(try nativeReply(calls: [call("open_app", #"{"name":"Notes"}"#)], finish: "tool_calls"))
        await client.enqueue(try nativeReply("Notes is open."))
        let observer = PictureScreenObserver()
        let controller = AgentController(logger: LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "pic-log-\(UUID()).jsonl")), settingsStore: SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "pic-settings-\(UUID()).json")), screenObserver: observer, executor: LocalPilotActionExecutor(screenObserver: observer, computerController: SpyComputerController()), httpClient: client)
        controller.selectModel("fixture", on: LocalModelServer(name: "fixture", baseURL: URL(string: "http://127.0.0.1:1234/v1")!, models: ["fixture"]))
        controller.start(task: "Open Notes")
        for _ in 0..<200 where controller.runStatus.isActive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.runStatus == .done)
        #expect(observer.areas == [.window])

        let requests = await client.requests.filter { $0.url.path.hasSuffix("completions") }
        let messages = try #require(requests.last?.jsonBody?["messages"] as? [[String: Any]])
        let screen = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(screen.contains { $0["type"] as? String == "image_url" })
        let text = screen.compactMap { $0["text"] as? String }.joined()
        #expect(text.contains("Where you are"))
        #expect(!text.contains("elements:"))
    }
}

@MainActor
struct ScreenshotCoordinateTests {
    @Test
    func clicksUseTheZeroToThousandScaleAndPixelsAreRejected() async throws {
        let client = MockHTTPClient()
        await client.route("http://127.0.0.1:1234/v1/models", HTTPResponse(data: Data(#"{"data":[{"id":"fixture"}]}"#.utf8), statusCode: 200))
        await client.enqueue(try nativeReply(calls: [call("observe", "{}", id: "look")], finish: "tool_calls"))
        await client.enqueue(try nativeReply(calls: [call("click", #"{"x":1280,"y":400}"#, id: "pixels")], finish: "tool_calls"))
        await client.enqueue(try nativeReply(calls: [call("click", #"{"x":500,"y":500}"#, id: "scaled")], finish: "tool_calls"))
        await client.enqueue(try nativeReply("Clicked."))
        let observer = PictureScreenObserver()
        let spy = SpyComputerController()
        let store = SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "coord-settings-\(UUID()).json"))
        var settings = AppSettings.defaultValue
        settings.dryRunExecutionOnly = false
        try store.save(settings)
        let controller = AgentController(logger: LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "coord-log-\(UUID()).jsonl")), settingsStore: store, screenObserver: observer, executor: LocalPilotActionExecutor(screenObserver: observer, computerController: spy, dryRun: false), httpClient: client)
        controller.selectModel("fixture", on: LocalModelServer(name: "fixture", baseURL: URL(string: "http://127.0.0.1:1234/v1")!, models: ["fixture"]))
        controller.start(task: "Click the middle")
        for _ in 0..<300 where controller.runStatus.isActive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.runStatus == .done)
        // The window is 400x300 points at (50, 60); the middle is (250, 210).
        #expect(await spy.clicks == [CGPoint(x: 250, y: 210)])
        let requests = await client.requests.filter { $0.url.path.hasSuffix("completions") }
        let messages = try #require(requests.last?.jsonBody?["messages"] as? [[String: Any]])
        let rejected = messages.first { $0["tool_call_id"] as? String == "pixels" }?["content"] as? String
        #expect(rejected?.contains("0 and 1000") == true)
    }
}
