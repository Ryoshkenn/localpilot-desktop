import Foundation
import Testing
@testable import LocalPilotDesktop

struct ActionValidatorTests {
    private func action(_ type: ActionType, target: String = "t", text: String? = nil, command: String? = nil, coordinates: [Double]? = nil, element: Int? = nil) -> StructuredAction {
        StructuredAction(type: type, targetKind: "k", targetText: target, coordinates: coordinates, targetElementID: element,
                         text: text, command: command, expectedResult: "e", riskLevel: .low, reason: "r")
    }

    @Test
    func openURLTakesTheURLFromWhicheverFieldHasIt() {
        guard case .valid(let fixed) = ActionValidator.validate(action(.openURL, target: "https://example.com", text: "the site")) else {
            Issue.record("Expected valid"); return
        }
        #expect(fixed.text == "https://example.com")
    }

    @Test
    func openURLWithoutAURLIsSentBack() {
        guard case .invalid(let problem) = ActionValidator.validate(action(.openURL, target: "Safari")) else {
            Issue.record("Expected invalid"); return
        }
        #expect(problem.contains("http"))
    }

    @Test
    func clicksNeedATarget() {
        #expect(ActionValidator.validate(action(.click)) != .valid(action(.click)))
        guard case .valid = ActionValidator.validate(action(.click, coordinates: [10, 20])) else { Issue.record("coords"); return }
        let element = AXElementSnapshot(id: 3, role: "Button", label: "OK", centerX: 1, centerY: 1, width: 1, height: 1)
        guard case .valid = ActionValidator.validate(action(.click, element: 3), elements: [element]) else { Issue.record("element"); return }
        guard case .invalid = ActionValidator.validate(action(.click, element: 9), elements: [element]) else { Issue.record("stale element"); return }
    }

    @Test
    func keysMustBeSupported() {
        guard case .invalid = ActionValidator.validate(action(.pressKey, target: "scroll_down")) else { Issue.record("key"); return }
        guard case .valid = ActionValidator.validate(action(.pressKey, target: "Return")) else { Issue.record("return"); return }
    }
}

@MainActor
struct HarnessRecoveryTests {
    private func reply(_ actions: String) -> HTTPResponse {
        let content = String(data: try! JSONEncoder().encode(#"{"actions":["# + actions + "]}"), encoding: .utf8)!
        return HTTPResponse(data: Data(#"{"choices":[{"message":{"content":\#(content)},"finish_reason":"stop"}]}"#.utf8), statusCode: 200)
    }

    private func step(_ type: String, target: String = "x", extra: String = "") -> String {
        #"{"type":"\#(type)","target_kind":"k","target_text":"\#(target)",\#(extra)"expected_result":"e","risk_level":"low","reason":"r"}"#
    }

    private func makeController(_ client: MockHTTPClient) async -> AgentController {
        await client.route("http://127.0.0.1:1234/v1/models", HTTPResponse(data: Data(#"{"data":[{"id":"m"}]}"#.utf8), statusCode: 200))
        let controller = AgentController(
            logger: LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "recovery-\(UUID().uuidString).jsonl")),
            settingsStore: SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "recovery-\(UUID().uuidString).json")),
            screenObserver: StubScreenObserver(observation: ScreenObservation(
                activeApp: "Notes", activeWindow: nil, screenshotWidth: nil, screenshotHeight: nil,
                screenshotPNGBase64: nil, accessibilitySummary: nil
            )),
            httpClient: client
        )
        controller.settings.toolCallingMode = .jsonCompatibility
        controller.selectModel("m", on: LocalModelServer(name: "LM Studio", baseURL: URL(string: "http://127.0.0.1:1234/v1")!, models: ["m"]))
        return controller
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test
    func invalidStepIsFedBackAndTheModelRecovers() async {
        let client = MockHTTPClient()
        await client.enqueue(reply(step("open_url", target: "Safari")))
        await client.enqueue(reply(step("finish")))
        let controller = await makeController(client)

        controller.start(task: "open the site")
        await waitUntil { controller.runStatus == .done }

        #expect(controller.runStatus == .done)
        let secondPrompt = await client.requests.compactMap { $0.jsonBody?["messages"] as? [[String: Any]] }.last?.last?["content"] as? String
        #expect(secondPrompt?.contains("Rejected open_url") == true)
    }

    @Test
    func repeatedInvalidStepsStopTheRun() async {
        let client = MockHTTPClient()
        for _ in 0..<HarnessLimits.maxConsecutiveCorrections {
            await client.enqueue(reply(step("click")))
        }
        let controller = await makeController(client)

        controller.start(task: "click it")
        await waitUntil { controller.runStatus == .blocked }

        #expect(controller.runStatus == .blocked)
        #expect(controller.messages.last?.text.contains("invalid steps in a row") == true)
    }

    @Test
    func askUserPausesUntilAnswered() async {
        let client = MockHTTPClient()
        await client.enqueue(reply(step("ask_user", target: "Which folder should I use?")))
        await client.enqueue(reply(step("finish")))
        let controller = await makeController(client)

        controller.start(task: "sort my files")
        await waitUntil { controller.pendingQuestion != nil }
        #expect(controller.runStatus == .paused)
        #expect(controller.pendingQuestion == "Which folder should I use?")

        controller.continueTask(instruction: "Downloads")
        await waitUntil { controller.runStatus == .done }

        #expect(controller.runStatus == .done)
        #expect(controller.pendingQuestion == nil)
        let lastPrompt = await client.requests.compactMap { $0.jsonBody?["messages"] as? [[String: Any]] }.last?.last?["content"] as? String
        #expect(lastPrompt?.contains("- Downloads") == true)
    }

    @Test
    func identicalStepsStopTheRun() async {
        let client = MockHTTPClient()
        for _ in 0..<HarnessLimits.maxIdenticalSteps {
            await client.enqueue(reply(step("press_key", target: "return", extra: #""text":"return","#)))
        }
        let controller = await makeController(client)

        controller.start(task: "submit")
        await waitUntil { controller.runStatus == .blocked }

        #expect(controller.runStatus == .blocked)
        #expect(controller.messages.last?.text.contains("repeated the same") == true)
    }
}
