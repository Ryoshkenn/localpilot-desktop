import Foundation
import Testing
@testable import LocalPilotDesktop

actor StubTextProvider: LocalModelProvider {
    let configuration: ModelProviderConfiguration
    var completions: [String]

    init(completions: [String]) {
        self.completions = completions
        self.configuration = ModelProviderConfiguration(
            providerName: "stub",
            modelName: "stub-model",
            temperature: 0,
            timeoutSeconds: 1
        )
    }

    func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        completions.removeFirst()
    }

    func healthCheck() async throws {}
    func cancel() async {}
}

/// Records the `format` it was last asked to complete with, so tests can assert
/// the planner forwards the expected structured-output mode.
actor FormatCapturingProvider: LocalModelProvider {
    let configuration: ModelProviderConfiguration
    let canned: String
    private(set) var lastFormat: ModelResponseFormat?

    init(canned: String) {
        self.canned = canned
        self.configuration = ModelProviderConfiguration(
            providerName: "capture",
            modelName: "capture-model",
            temperature: 0,
            timeoutSeconds: 1
        )
    }

    func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        lastFormat = format
        return canned
    }

    func healthCheck() async throws {}
    func cancel() async {}
}

struct PlannerTests {
    @Test
    func plannerParsesStructuredActionFromManagedModelJsonResponse() async throws {
        let provider = StubTextProvider(completions: [
            #"{"type":"wait","target_kind":"timer","target_text":"one second","coordinates":null,"text":null,"command":null,"expected_result":"delay","risk_level":"low","reason":"safe wait"}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let action = try await planner.proposeOneAction(originalTask: "wait", context: .empty, recentMessages: [])

        #expect(action.type == .wait)
        #expect(action.targetKind == "timer")
        #expect(action.riskLevel == .low)
    }

    @Test
    func plannerParsesTargetElementIDFromJson() async throws {
        let provider = StubTextProvider(completions: [
            #"{"type":"click","target_kind":"element","target_text":"Save","target_element_id":3,"expected_result":"clicked","risk_level":"low","reason":"click the save button"}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let action = try await planner.proposeOneAction(originalTask: "save", context: .empty, recentMessages: [])

        #expect(action.type == .click)
        #expect(action.targetElementID == 3)
        #expect(action.coordinates == nil)
    }

    @Test
    func plannerDefaultsTargetElementIDToNilWhenAbsent() async throws {
        let provider = StubTextProvider(completions: [
            #"{"type":"click","target_kind":"point","target_text":"Save","coordinates":[10,20],"expected_result":"clicked","risk_level":"low","reason":"click"}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let action = try await planner.proposeOneAction(originalTask: "save", context: .empty, recentMessages: [])

        #expect(action.targetElementID == nil)
        #expect(action.coordinates == [10, 20])
    }

    @Test
    func plannerParsesMultiActionPlan() async throws {
        let provider = StubTextProvider(completions: [
            #"{"actions":[{"type":"observe","target_kind":"screen","target_text":"screen","expected_result":"state","risk_level":"low","reason":"look"},{"type":"finish","target_kind":"task","target_text":"task","expected_result":"done","risk_level":"low","reason":"complete"}]}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let actions = try await planner.proposeActions(originalTask: "do it", context: .empty, recentMessages: [])

        #expect(actions.count == 2)
        #expect(actions.first?.type == .observe)
        #expect(actions.last?.type == .finish)
    }

    @Test
    func plannerFallsBackToSingleActionObjectForPlans() async throws {
        let provider = StubTextProvider(completions: [
            #"{"type":"wait","target_kind":"timer","target_text":"a beat","expected_result":"delay","risk_level":"low","reason":"wait"}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let actions = try await planner.proposeActions(originalTask: "wait", context: .empty, recentMessages: [])

        #expect(actions.count == 1)
        #expect(actions.first?.type == .wait)
    }

    @Test
    func plannerCapsPlanToMaxActions() async throws {
        let item = #"{"type":"observe","target_kind":"screen","target_text":"s","expected_result":"r","risk_level":"low","reason":"x"}"#
        let items = Array(repeating: item, count: 10).joined(separator: ",")
        let provider = StubTextProvider(completions: ["{\"actions\":[\(items)]}"])
        let planner = JSONActionPlanner(provider: provider)

        let actions = try await planner.proposeActions(originalTask: "t", context: .empty, recentMessages: [], maxActions: 3)

        #expect(actions.count == 3)
    }

    @Test
    func plannerPassesJsonSchemaFormatWhenStructuredOutputEnabled() async throws {
        let canned = #"{"actions":[{"type":"wait","target_kind":"timer","target_text":"a beat","expected_result":"delay","risk_level":"low","reason":"wait"}]}"#
        let provider = FormatCapturingProvider(canned: canned)
        let planner = JSONActionPlanner(provider: provider, structuredOutput: true)

        _ = try await planner.proposeActions(originalTask: "t", context: .empty, recentMessages: [])

        let format = await provider.lastFormat
        guard case .jsonSchema = format else {
            Issue.record("Expected .jsonSchema format, got \(String(describing: format))")
            return
        }
    }

    @Test
    func plannerPassesPlainJsonFormatWhenStructuredOutputDisabled() async throws {
        let canned = #"{"actions":[{"type":"wait","target_kind":"timer","target_text":"a beat","expected_result":"delay","risk_level":"low","reason":"wait"}]}"#
        let provider = FormatCapturingProvider(canned: canned)
        let planner = JSONActionPlanner(provider: provider, structuredOutput: false)

        _ = try await planner.proposeActions(originalTask: "t", context: .empty, recentMessages: [])

        #expect(await provider.lastFormat == .json)
    }

    @Test
    func plannerRecoversJsonWrappedInThinkingAndFences() async throws {
        let provider = StubTextProvider(completions: [
            "<think>The user wants to wait. {not json}</think>\nSure! Here is the action:\n```json\n{\"type\":\"wait\",\"target_kind\":\"timer\",\"target_text\":\"a {beat}\",\"expected_result\":\"delay\",\"risk_level\":\"low\",\"reason\":\"wait\"}\n```"
        ])
        let planner = JSONActionPlanner(provider: provider)

        let actions = try await planner.proposeActions(originalTask: "wait", context: .empty, recentMessages: [])

        #expect(actions.first?.type == .wait)
        #expect(actions.first?.targetText == "a {beat}")
    }

    @Test
    func plannerAcceptsBareActionArray() async throws {
        let provider = StubTextProvider(completions: [
            #"[{"type":"observe","target_kind":"screen","target_text":"s","expected_result":"r","risk_level":"low","reason":"x"},{"type":"finish","target_kind":"task","target_text":"t","expected_result":"done","risk_level":"low","reason":"y"}]"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let actions = try await planner.proposeActions(originalTask: "t", context: .empty, recentMessages: [])

        #expect(actions.map(\.type) == [.observe, .finish])
    }

    @Test
    func invalidReplyErrorQuotesWhatTheModelSaid() async throws {
        let provider = StubTextProvider(completions: [#"{"actions":[{"action":"acknowledge_greeting"}]}"#])
        let planner = JSONActionPlanner(provider: provider)

        do {
            _ = try await planner.proposeActions(originalTask: "hi", context: .empty, recentMessages: [])
            Issue.record("Expected invalid output")
        } catch let PlannerError.invalidOutput(preview) {
            #expect(preview.contains("acknowledge_greeting"))
        }
    }

    @Test
    func planPromptDocumentsTheActionFormat() {
        #expect(JSONActionPlanner.actionFormat.contains("target_element_id"))
        #expect(JSONActionPlanner.actionFormat.contains("web_search"))
        #expect(!JSONActionPlanner.actionFormat.contains("run_terminal_command"))
    }
}

struct ChatResponseTests {
    @Test(arguments: [#"{"reply":"Hi!"}"#, "Hi!", "<think>greet</think>Hi!", #"{"message":"Hi!","actions":[]}"#])
    func greetingIsAReplyWithoutActions(_ raw: String) throws {
        let response = try JSONActionPlanner.parseResponse(raw)
        #expect(response.reply == "Hi!")
        #expect(response.actions.isEmpty)
        #expect(response.todo == nil)
    }

    @Test
    func compactActionsDecodeWithOptionalChecklist() throws {
        let response = try JSONActionPlanner.parseResponse(#"{"actions":[{"type":"open_app","target":"Google Chrome"},{"type":"browser_new_tab","url":"https://example.com"},{"type":"type_text","id":7,"text":"Hello"},{"type":"press_key","key":"cmd+a"}],"todo":["Fill the form"],"reply":"Done"}"#)
        #expect(response.actions.map(\.type) == [.switchApp, .browserNewTab, .typeTextSafe, .pressKey])
        #expect(response.actions[0].targetText == "Google Chrome")
        #expect(response.actions[1].text == "https://example.com")
        #expect(response.actions[2].targetElementID == 7)
        #expect(response.actions[3].text == "cmd+a")
        #expect(response.todo == ["Fill the form"])
        #expect(response.reply == "Done")
    }

    @Test(arguments: [#"{"actions":[{"type":"unknown"}],"reply":"Done"}"#, #"{"actions":"oops","reply":"Done"}"#, #"{"actions":[]}"#, #"{"reply":""}"#, #"{"actions":[{"type":"click"}"#])
    func malformedToolsCannotMasqueradeAsSuccessfulChat(_ raw: String) {
        #expect(throws: PlannerError.self) { try JSONActionPlanner.parseResponse(raw) }
    }

    @Test
    func clippedBatchDoesNotPublishPrematureReply() throws {
        let response = try JSONActionPlanner.parseResponse(#"{"actions":[{"type":"observe"},{"type":"finish"}],"reply":"All done"}"#, maxActions: 1)
        #expect(response.actions.count == 1)
        #expect(response.reply == nil)
    }

    @Test
    func screenshotAndLegacyObservationAreDistinct() throws {
        let screenshot = try JSONActionPlanner.parseResponse(#"{"type":"screenshot"}"#)
        #expect(screenshot.actions.first?.type == .screenshot)
        let old = try JSONActionPlanner.parseResponse(#"{"type":"type_text_safe","target_element_id":3,"text":"Hello"}"#)
        #expect(old.actions.first?.type == .typeTextSafe)
        #expect(old.actions.first?.targetElementID == 3)
    }

    @Test
    func screenshotCoordinatesScaleButScrollDoesNot() throws {
        let image = ScreenshotAttachment(jpegBase64: "test", pixelWidth: 1280, pixelHeight: 720, pointWidth: 1920, pointHeight: 1080)
        // Positions are 0–1000 across and down the screenshot.
        let click = try #require(JSONActionPlanner.parseResponse(#"{"type":"click","coordinates":[500,250]}"#).actions.first)
        #expect(click.inScreenPoints(using: image).coordinates == [960, 270])
        let scroll = try #require(JSONActionPlanner.parseResponse(#"{"type":"scroll","coordinates":[0,-5]}"#).actions.first)
        #expect(scroll.inScreenPoints(using: image).coordinates == [0, -5])
    }

    @Test
    func compactElementClicksCarryObservedLabelsIntoPolicy() throws {
        let click = try #require(JSONActionPlanner.parseResponse(#"{"type":"click","id":4}"#).actions.first)
        let element = AXElementSnapshot(id: 4, role: "Button", label: "Submit", centerX: 10, centerY: 10, width: 20, height: 20)
        guard case let .valid(checked) = ActionValidator.validate(click, elements: [element]) else { Issue.record("Expected valid click"); return }
        #expect(checked.targetText == "Submit")
        #expect(DeterministicPolicyEngine().classify(action: checked, context: .empty).classification == .allow)
        guard case .invalid = ActionValidator.validate(click, elements: []) else { Issue.record("Unobserved id must be rejected"); return }
    }

    @Test
    func browserURLsAndKeyboardChordsAreValidated() throws {
        for raw in [#"{"type":"browser_new_tab","url":"https://example.com"}"#, #"{"type":"browser_switch_tab","target":"2"}"#, #"{"type":"press_key","key":"cmd+shift+t"}"#] {
            let action = try #require(JSONActionPlanner.parseResponse(raw).actions.first)
            guard case .valid = ActionValidator.validate(action) else { Issue.record("Expected valid: \(raw)"); continue }
        }
        for raw in [#"{"type":"browser_navigate","url":"javascript:alert(1)"}"#, #"{"type":"browser_close_tab","target":"0"}"#, #"{"type":"press_key","key":"madeup+a"}"#] {
            let action = try #require(JSONActionPlanner.parseResponse(raw).actions.first)
            guard case .invalid = ActionValidator.validate(action) else { Issue.record("Expected invalid: \(raw)"); continue }
        }
    }
}

@MainActor
final class CountingScreenObserver: ScreenObserving {
    var captures = 0
    var screenshots = 0
    func capture() async -> ScreenObservation {
        captures += 1
        return ScreenObservation(activeApp: "Notes", activeWindow: "Test", screenshotWidth: nil, screenshotHeight: nil, screenshotPNGBase64: nil, accessibilitySummary: nil)
    }
    func captureScreenshot(maxWidth: Int) async -> ScreenshotAttachment? { screenshots += 1; return nil }
}

@MainActor
struct ChatResponseRoutingTests {
    @Test(arguments: [false, true])
    func cannedRepliesAreFiledWithoutUnnecessaryPlanningOrObservation(computerReply: Bool) async throws {
        let client = MockHTTPClient()
        await client.route("http://127.0.0.1:1234/v1/models", HTTPResponse(data: Data(#"{"data":[{"id":"fixture"}]}"#.utf8), statusCode: 200))
        let canned = computerReply ? #"{"actions":[{"type":"open_app","target":"Notes"}],"reply":"Opened Notes."}"# : #"{"reply":"Hi!"}"#
        let payload = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": canned]]]])
        await client.enqueue(HTTPResponse(data: payload, statusCode: 200))
        let observer = CountingScreenObserver()
        let spy = SpyComputerController()
        let controller = AgentController(
            logger: LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "chat-fixture-\(UUID()).jsonl")),
            settingsStore: SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "chat-fixture-\(UUID()).json")),
            screenObserver: observer,
            executor: LocalPilotActionExecutor(screenObserver: observer, computerController: spy), httpClient: client
        )
        controller.settings.toolCallingMode = .jsonCompatibility
        controller.settings.modelProviderMode = .localServer
        controller.settings.serverBaseURL = "http://127.0.0.1:1234/v1"
        controller.settings.plannerModel = "fixture"
        controller.start(task: computerReply ? "Open Notes" : "hi")
        for _ in 0..<100 where controller.runStatus.isActive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.runStatus == .done)
        if computerReply {
            #expect(controller.messages.last?.text.contains("Opened Notes.") == true)
            #expect(controller.messages.last?.text.contains("Dry run") == true)
            #expect(controller.messages.last?.outcome == .done)
            #expect(controller.messages.dropLast().last?.action == .switchApp)
        } else {
            #expect(controller.messages.last?.text == "Hi!")
            #expect(controller.messages.last?.outcome == nil)
        }
        #expect(controller.messages.last?.action == nil)
        #expect(controller.stepCount == (computerReply ? 1 : 0))
        #expect(await client.requests.filter { $0.url.path.hasSuffix("completions") }.count == 1)
        #expect(await spy.switchedApps.isEmpty)
        #expect(controller.overlayState == .idle)
        #expect(observer.captures == 0)
        #expect(observer.screenshots == 0)
        #expect(await spy.clicks.isEmpty)
    }
}
