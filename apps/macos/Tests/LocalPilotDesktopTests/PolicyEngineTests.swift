import Testing
@testable import LocalPilotDesktop

/// LocalPilot has full control with no approval prompts, except that terminal
/// commands are locked. URLs are still checked structurally.
struct PolicyEngineTests {
    private let policy = DeterministicPolicyEngine()

    private func action(_ type: ActionType, target: String = "x", text: String? = nil, command: String? = nil, risk: RiskLevel = .low) -> StructuredAction {
        StructuredAction(type: type, targetKind: "k", targetText: target, text: text, command: command, expectedResult: "e", riskLevel: risk, reason: "r")
    }

    @Test(arguments: ["pwd", "ls -la", "git status", "rm -rf build", "RM -RF /"])
    func terminalCommandsAreLocked(_ command: String) {
        let decision = policy.classify(action: action(.runTerminalCommand, command: command), context: .empty)
        #expect(decision.classification == .block)
        #expect(decision.reason.contains("locked"))
    }

    @Test(arguments: ["Submit", "Delete", "Purchase", "Sign in", "Thumbnail"])
    func clicksNeverAskForApproval(_ label: String) {
        #expect(policy.classify(action: action(.click, target: label, risk: .high), context: .empty).classification == .allow)
    }

    @Test(arguments: [ActionType.copy, .paste, .typeTextSafe, .typeTextSensitive, .pressKey, .switchApp, .scroll, .webSearch])
    func otherActionsAreAllowed(_ type: ActionType) {
        #expect(policy.classify(action: action(type, text: "hello", risk: .medium), context: .empty).classification == .allow)
    }

    @Test
    func anyWebsiteIsAllowed() {
        #expect(policy.classify(action: action(.openURL, text: "https://example.com/page"), context: .empty).classification == .allow)
        #expect(policy.classify(action: action(.browserNavigate, text: "https://apple.com"), context: .empty).classification == .allow)
        #expect(policy.classify(action: action(.readWebpage, text: "https://news.ycombinator.com"), context: .empty).classification == .allow)
    }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "ftp://example.com", "myapp://do"])
    func nonWebSchemesAreBlocked(_ url: String) {
        #expect(policy.classify(action: action(.openURL, text: url), context: .empty).classification == .block)
    }

    @Test(arguments: ["https://example.com\\@evil.test", "https://exa mple.com", "https://example.com/\u{0007}"])
    func malformedURLsAreBlocked(_ url: String) {
        #expect(policy.classify(action: action(.browserNavigate, text: url), context: .empty).classification == .block)
    }

    @Test
    func openURLClassifiesTheTextFieldTheExecutorOpens() {
        let decision = policy.classify(action: action(.openURL, target: "https://example.com", text: "file:///etc/passwd"), context: .empty)
        #expect(decision.classification == .block)
    }

    @Test
    func multiActionBatchesAreBlocked() {
        let decision = policy.classifyBatch(actions: [action(.observe), action(.observe)], context: .empty)
        #expect(decision.classification == .block)
    }
}
