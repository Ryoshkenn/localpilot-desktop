import Foundation
import Testing
@testable import LocalPilotDesktop

/// Serves a canned SSE body through the streaming path.
private struct StreamingHTTPClient: HTTPClient {
    let body: String
    var supportsStreaming: Bool { true }

    func data(for request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(data: Data(#"{"data":[{"id":"m"}]}"#.utf8), statusCode: 200)
    }

    func lines(for request: HTTPRequest) async throws -> AsyncThrowingStream<String, Error> {
        let lines = body.components(separatedBy: "\n")
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GenerationEvent] = []
    var events: [GenerationEvent] { lock.withLock { stored } }
    func record(_ event: GenerationEvent) { lock.withLock { stored.append(event) } }
}

struct StreamingTests {
    @Test
    func streamedToolCallIsReassembledWithPhases() async throws {
        let body = """
        data: {"choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"Need "}}]}

        data: {"choices":[{"index":0,"delta":{"reasoning_content":"Finder."}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"open_app","arguments":""}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"app\\":"}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"Finder\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":812,"completion_tokens":9}}

        data: [DONE]
        """
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:1234/v1")!,
            configuration: ModelProviderConfiguration(providerName: "p", modelName: "m", temperature: 0, timeoutSeconds: 5),
            httpClient: StreamingHTTPClient(body: body)
        )
        let recorder = EventRecorder()
        let message = try await provider.respond(messages: [NativeMessage(role: "user", content: "hi")], tools: [], onEvent: recorder.record)

        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls.first?.function.name == "open_app")
        #expect(message.toolCalls.first?.function.arguments == #"{"app":"Finder"}"#)
        #expect(message.reasoningContent == "Need Finder.")
        let events = recorder.events
        guard case .prefill(let estimate) = events.first else { Issue.record("No prefill event"); return }
        #expect(estimate > 0)
        #expect(events.contains(.reasoning("Finder.")))
        #expect(events.contains(.toolCall(name: "open_app", arguments: "")))
        guard case .usage(let promptTokens, let seconds) = events.last else { Issue.record("No usage event"); return }
        #expect(promptTokens == 812)
        #expect(seconds >= 0)
    }

    @Test
    func livePhaseFollowsWhatIsStreaming() {
        var live = LiveGeneration()
        #expect(live.phase == .prefilling)
        live.reasoningTokens = 3
        #expect(live.phase == .thinking(tokens: 3))
        live.contentTokens = 1
        #expect(live.phase == .writing(tokens: 1))
        live.toolName = "click"
        #expect(live.phase == .callingTool(name: "click"))
    }

    @Test
    func promptEstimateCountsTextAndImages() {
        let text = NativeMessage(role: "user", content: String(repeating: "a", count: 4_000))
        #expect(PromptSizeEstimator.tokens(messages: [text], tools: []) >= 1_000)
        let shot = ScreenshotAttachment(jpegBase64: "", pixelWidth: 10, pixelHeight: 10, pointWidth: 10, pointHeight: 10)
        let withImage = NativeMessage(role: "user", content: "x", screenshot: shot)
        #expect(PromptSizeEstimator.tokens(messages: [withImage], tools: []) >= PromptSizeEstimator.tokensPerImage)
    }

    @Test
    func nonSSEBodyFallsBackToPlainDecoding() throws {
        var accumulator = NativeStreamAccumulator()
        let body = #"{"choices":[{"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}]}"#
        #expect(accumulator.consume(line: body).isEmpty)
        let message = try OpenAICompatibleProvider.decodeNativeResponse(accumulator.completionData())
        #expect(message.content == "Hi")
    }
}

struct GenerationSettingsTests {
    @Test
    func onlySetParametersAreSent() {
        let payload = GenerationSettings(maxTokens: 2_048, topK: 40, seed: 7, stopSequences: ["END", ""]).payload
        #expect(payload["max_tokens"] as? Int == 2_048)
        #expect(payload["top_k"] as? Int == 40)
        #expect(payload["seed"] as? Int == 7)
        #expect(payload["stop"] as? [String] == ["END"])
        #expect(payload["top_p"] == nil)
        #expect(payload["repeat_penalty"] == nil)
    }

    @Test
    func oldSettingsFilesGetDefaultGeneration() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"temperature":0.3}"#.utf8))
        #expect(settings.generation == .defaultValue)
        #expect(settings.temperature == 0.3)
    }
}

@MainActor
struct ConversationTests {
    @Test
    func conversationRoundTripsThroughStore() throws {
        let store = ConversationStore(directory: URL.temporaryDirectory.appending(path: "chats-\(UUID().uuidString)"))
        let taskID = UUID()
        var step = ChatMessage(role: .agent, text: "Open Finder", action: .switchApp, detail: "open_app({})")
        step.result = "Opened Finder"
        let conversation = Conversation(title: "Switch to Finder", messages: [
            ChatMessage(role: .user, text: "Switch to Finder"),
            step,
            ChatMessage(role: .agent, text: "Done.", outcome: .done),
        ], taskIDs: [taskID])
        try store.save(conversation)

        let loaded = try #require(store.load(id: conversation.id))
        #expect(loaded.messages == conversation.messages)
        #expect(loaded.messages[1].result == "Opened Finder")
        let summary = try #require(store.summaries().first)
        #expect(summary.stepCount == 1)
        #expect(summary.taskIDs == [taskID])
        #expect(summary.preview == "Done.")
    }

    @Test
    func olderMessagesWithoutNewFieldsStillDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","role":"agent","text":"hi","timestamp":0}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        #expect(message.detail == nil)
        #expect(!message.isThought)
    }

    @Test
    func controllerSavesAndReopensChats() async throws {
        let directory = URL.temporaryDirectory.appending(path: "controller-chats-\(UUID().uuidString)")
        let controller = AgentController(
            logger: LocalEventLogger(fileURL: directory.appending(path: "log.jsonl")),
            settingsStore: SettingsStore(fileURL: directory.appending(path: "settings.json")),
            useModelLoop: false
        )
        controller.start(task: "Switch to Finder")
        let id = try #require(controller.conversationID)
        controller.stop()

        for _ in 0..<100 where controller.conversationStore.load(id: id)?.messages.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.newConversation()
        #expect(controller.messages.isEmpty)
        #expect(controller.conversationID == nil)

        controller.openConversation(id: id)
        #expect(controller.conversationID == id)
        #expect(controller.messages.first?.text == "Switch to Finder")
        #expect(controller.messages.count == 2)
        #expect(controller.conversationStore.summaries().first?.title == "Switch to Finder")
    }
}

@MainActor
struct ReplyTrimmingTests {
    @Test
    func leadingBlankLinesAreRemovedFromReplies() async {
        let client = MockHTTPClient()
        await client.route("http://127.0.0.1:1234/v1/models", HTTPResponse(data: Data(#"{"data":[{"id":"m"}]}"#.utf8), statusCode: 200))
        await client.enqueue(HTTPResponse(
            data: Data(#"{"choices":[{"message":{"role":"assistant","content":"\n\nHello there."},"finish_reason":"stop"}]}"#.utf8),
            statusCode: 200
        ))
        let directory = URL.temporaryDirectory.appending(path: "trim-\(UUID().uuidString)")
        let controller = AgentController(
            logger: LocalEventLogger(fileURL: directory.appending(path: "log.jsonl")),
            settingsStore: SettingsStore(fileURL: directory.appending(path: "settings.json")),
            httpClient: client
        )
        controller.selectModel("m", on: LocalModelServer(name: "LM Studio", baseURL: URL(string: "http://127.0.0.1:1234/v1")!, models: ["m"]))
        controller.start(task: "hi")
        for _ in 0..<200 where controller.runStatus == .running {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.messages.last?.text == "Hello there.")
        #expect(controller.liveGeneration == nil)
    }
}

@MainActor
struct WebResearchTests {
    @Test
    func parsesDuckDuckGoResults() {
        let html = """
        <div class="result"><h2><a rel="nofollow" class="result__a" href="https://developer.apple.com/documentation/swift/actor">Actor | Apple <b>Developer</b></a></h2>
        <a class="result__snippet" href="https://developer.apple.com/documentation/swift/actor">A common protocol to which all <b>actors</b> conform &amp; more.</a></div>
        <div class="result"><h2><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&amp;rut=x">Example</a></h2></div>
        """
        let results = WebResearch.parseResults(html)
        #expect(results.count == 2)
        #expect(results[0].title == "Actor | Apple Developer")
        #expect(results[0].url == "https://developer.apple.com/documentation/swift/actor")
        #expect(results[0].snippet == "A common protocol to which all actors conform & more.")
        #expect(results[1].url == "https://example.com/a?b=1")
    }

    @Test
    func pageTextDropsScriptsAndTags() {
        let text = WebResearch.plainText("<html><head><style>p{}</style><script>var x=1</script></head><body><h1>Title</h1><p>Hello&nbsp;<b>world</b> &#8212; ok</p></body></html>")
        #expect(text == "Title\nHello world — ok")
    }

    @Test
    func searchGoesThroughTheExecutorEvenInDryRun() async {
        let client = MockHTTPClient()
        await client.enqueue(HTTPResponse(data: Data(#"<a class="result__a" href="https://swift.org">Swift</a>"#.utf8), statusCode: 200))
        let executor = LocalPilotActionExecutor(screenObserver: StubScreenObserver(observation: ScreenObservation(
            activeApp: nil, activeWindow: nil, screenshotWidth: nil, screenshotHeight: nil, screenshotPNGBase64: nil, accessibilitySummary: nil
        )), webClient: client, dryRun: true)
        let action = StructuredAction(type: .webSearch, targetKind: "", targetText: "", text: "swift language", expectedResult: "", riskLevel: .low, reason: "")
        let result = await executor.execute(action)
        #expect(result.contains("https://swift.org"))
        let url = await client.requests.first?.url.absoluteString
        #expect(url?.contains("q=swift%20language") == true)
    }
}

struct ToolValidationTests {
    private func action(_ type: ActionType, text: String? = nil, command: String? = nil, element: Int? = nil) -> StructuredAction {
        StructuredAction(type: type, targetKind: "", targetText: "", targetElementID: element, text: text, command: command, expectedResult: "", riskLevel: .low, reason: "")
    }

    @Test
    func terminalCommandsGoBackToTheModelAsLocked() {
        guard case .invalid(let problem) = ActionValidator.validate(action(.runTerminalCommand, command: "pwd")) else {
            Issue.record("Expected invalid"); return
        }
        #expect(problem.contains("locked"))
        #expect(!NativeToolRegistry.definitions.contains { $0.name == "run_terminal_command" })
    }

    @Test
    func webToolsNeedTheirInputs() {
        guard case .invalid = ActionValidator.validate(action(.webSearch, text: "  ")) else { Issue.record("empty query"); return }
        guard case .valid = ActionValidator.validate(action(.webSearch, text: "weather")) else { Issue.record("query"); return }
        guard case .invalid = ActionValidator.validate(action(.readWebpage, text: "example.com")) else { Issue.record("bare host"); return }
        guard case .valid = ActionValidator.validate(action(.readWebpage, text: "https://example.com")) else { Issue.record("url"); return }
    }

    @Test
    func scrollInsideAnElementNeedsAnObservedID() {
        let element = AXElementSnapshot(id: 3, role: "ScrollArea", label: "", centerX: 1, centerY: 1, width: 1, height: 1)
        guard case .valid = ActionValidator.validate(action(.scroll, element: 3), elements: [element]) else { Issue.record("observed"); return }
        guard case .invalid = ActionValidator.validate(action(.scroll, element: 9), elements: [element]) else { Issue.record("stale"); return }
        guard case .valid = ActionValidator.validate(action(.scroll)) else { Issue.record("window scroll"); return }
    }
}

struct ScreenshotObserveTests {
    @Test func observeCanAskForAPictureOfTheWindowOrScreen() throws {
        func resolve(_ name: String, _ arguments: String) throws -> StructuredAction? {
            let call = NativeToolCall(id: "1", function: .init(name: name, arguments: arguments))
            if case .action(let action) = try NativeToolRegistry.resolve(call) { return action }
            return nil
        }
        // A screenshot of the window is the default way to look.
        #expect(try resolve("observe", "{}")?.type == .screenshot)
        #expect(try resolve("observe", "{}")?.targetText == "window")
        #expect(throws: NativeToolError.self) { try resolve("scroll", #"{"lines":-5}"#) }
        #expect(!NativeToolRegistry.definitions.contains { $0.name == "scroll" })
        let typeAt = try resolve("type_text", #"{"text":"hi","x":40,"y":80}"#)
        #expect(typeAt?.coordinates == [40, 80])
        #expect(throws: NativeToolError.self) { try resolve("type_text", #"{"text":"hi","x":40}"#) }
        #expect(try resolve("observe", #"{"mode":"app_state"}"#)?.type == .observe)
        let window = try resolve("observe", #"{"mode":"screenshot"}"#)
        #expect(window?.type == .screenshot)
        #expect(window?.targetText == "window")
        #expect(try resolve("observe", #"{"mode":"screenshot","area":"screen"}"#)?.targetText == "screen")
        #expect(try resolve("screenshot", "{}")?.targetText == "window")
        #expect(throws: NativeToolError.self) { try resolve("observe", #"{"mode":"video"}"#) }
        // The schema advertises the two modes.
        let observe = NativeToolRegistry.definitions.first { $0.name == "observe" }!
        let properties = (observe.payload["function"] as! [String: Any])["parameters"] as! [String: Any]
        let mode = (properties["properties"] as! [String: Any])["mode"] as! [String: Any]
        #expect((mode["enum"] as! [Any]).compactMap { $0 as? String } == ["screenshot", "app_state"])
    }

    @Test func windowScreenshotCoordinatesMapThroughTheWindowOrigin() {
        let shot = ScreenshotAttachment(jpegBase64: "", pixelWidth: 1000, pixelHeight: 500, pointWidth: 500, pointHeight: 250, originX: 100, originY: 40, area: .window)
        // 0–1000 across a 500x250-point window at (100, 40).
        #expect(shot.toScreenPoints([200, 400]) == [200, 140])
        #expect(ScreenshotAttachment.isOnScale([1000, 0]))
        #expect(!ScreenshotAttachment.isOnScale([1280, 400]))
    }

    @Test func oldScreenshotsDecodeAsFullScreen() throws {
        let json = #"{"jpegBase64":"","pixelWidth":10,"pixelHeight":10,"pointWidth":20,"pointHeight":20}"#
        let shot = try JSONDecoder().decode(ScreenshotAttachment.self, from: Data(json.utf8))
        #expect(shot.area == .screen)
        #expect(shot.toScreenPoints([500, 500]) == [10, 10])
    }
}
