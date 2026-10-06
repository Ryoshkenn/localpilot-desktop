import Foundation

/// The model has full control of the Mac with no approval prompts, with one
/// exception: terminal commands are locked. URLs are still checked
/// structurally so only real http(s) pages can be opened.
public struct DeterministicPolicyEngine: Sendable {
    public init() {}

    public func classifyBatch(actions: [StructuredAction], context: AgentContext) -> PolicyDecision {
        guard actions.count == 1 else {
            return .init(classification: .block, reason: "Multi-action batches are blocked in v1.")
        }
        guard let action = actions.first else {
            return .init(classification: .block, reason: "No action was provided.")
        }
        return classify(action: action, context: context)
    }

    public func classify(action: StructuredAction, context: AgentContext) -> PolicyDecision {
        switch action.type {
        case .runTerminalCommand:
            return .init(classification: .block, reason: "Terminal commands are locked.")
        case .browserNewTab:
            let url = action.text ?? action.targetText
            return url.isEmpty ? .init(classification: .allow, reason: "Blank Chrome tab.") : classifyURL(url, context: context)
        case .openURL, .browserNavigate, .readWebpage:
            // Classify exactly the string the executor will open, which is
            // `text ?? targetText`. Reading only `targetText` here would let an
            // action carry a benign `targetText` while opening a different URL
            // via `text`.
            return classifyURL(action.text ?? action.targetText, context: context)
        default:
            return .init(classification: .allow, reason: "Allowed: LocalPilot has full control except the terminal.")
        }
    }

    private func classifyURL(_ rawURL: String, context: AgentContext) -> PolicyDecision {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Browsers treat backslashes as path separators, but URL/URLComponents
        // parse them inconsistently. A string like "https://allowed.com\\@evil.test"
        // can yield a benign host here while the executor's URL(string:) resolves
        // a different destination. Reject backslashes and embedded whitespace/
        // control characters rather than risk a parser-differential bypass.
        if trimmed.contains("\\") {
            return .init(classification: .block, reason: "URL contains a backslash and is blocked.")
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 }) {
            return .init(classification: .block, reason: "URL contains whitespace or control characters and is blocked.")
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            return .init(classification: .block, reason: "Invalid URL is blocked.")
        }

        // Only http(s) is openable by the executor; everything else
        // (file:, javascript:, data:, ftp:, custom app schemes, ...) is blocked
        // so it cannot reach the OS even if the executor changes.
        guard scheme == "http" || scheme == "https" else {
            return .init(classification: .block, reason: "Non-web URL scheme is blocked.")
        }

        // `URLComponents.host` excludes any user-info component, so a spoof like
        // "https://allowed.com@evil.com" yields host "evil.com" (the real
        // destination), which correctly fails the allowlist below.
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            return .init(classification: .block, reason: "URL has no host and is blocked.")
        }

        return .init(classification: .allow, reason: "Web page \(host) is allowed.")
    }
}
