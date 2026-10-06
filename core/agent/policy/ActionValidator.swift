import Foundation

/// Checks that an action is well-formed before policy sees it, and repairs the
/// unambiguous cases. Malformed actions are not dangerous, just wrong, so the
/// loop feeds the problem back to the planner instead of ending the task.
public enum ActionValidator {
    public enum Outcome: Equatable, Sendable {
        case valid(StructuredAction)
        /// The planner should retry; the string explains what to fix.
        case invalid(String)
    }

    public static func validate(_ action: StructuredAction, elements: [AXElementSnapshot] = []) -> Outcome {
        switch action.type {
        case .openURL, .browserNavigate:
            // The model may put the URL in either field; use whichever parses.
            guard let url = [action.text, action.targetText].compactMap({ $0 }).compactMap(webURL).first else {
                return .invalid("open_url needs a full http(s) URL, e.g. \"https://example.com\", in \"text\". Got target_text \"\(action.targetText)\".")
            }
            return .valid(action.with(text: url))
        case .browserNewTab:
            let raw = action.text ?? action.targetText
            if raw.isEmpty { return .valid(action) }
            guard let url = webURL(raw) else { return .invalid("browser_new_tab needs an http(s) url or no url for a blank tab.") }
            return .valid(action.with(text: url))
        case .browserSwitchTab, .browserCloseTab:
            guard let index = Int(action.text ?? action.targetText), index > 0 else {
                return .invalid("Use a 1-based Chrome tab number in target, from observe.")
            }
            return .valid(action)
        case .click, .doubleClick:
            if let id = action.targetElementID {
                guard elements.contains(where: { $0.id == id }) else {
                    return .invalid("\(action.type.rawValue) targets element \(id), which is not in the latest observation. Use a listed element id or coordinates.")
                }
                return .valid(action.withTarget(elements.first { $0.id == id }!.label))
            }
            guard let coordinates = action.coordinates, coordinates.count >= 2,
                  coordinates.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                return .invalid("\(action.type.rawValue) needs \"target_element_id\" from the element list, or \"coordinates\" [x, y].")
            }
            return .valid(action)
        case .typeTextSafe, .paste:
            guard let text = action.text, !text.isEmpty else {
                return .invalid("\(action.type.rawValue) needs the text to enter in \"text\".")
            }
            if let id = action.targetElementID {
                guard elements.contains(where: { $0.id == id }) else { return .invalid("Field id is not in the latest observation. Use observe first.") }
            }
            return .valid(action)
        case .pressKey:
            let key = (action.text ?? action.targetText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard KeyboardKeys.chord(for: key) != nil else {
                return .invalid("press_key supports named keys, letters, digits, and cmd/ctrl/alt/shift combinations (e.g. cmd+a). Got \"\(key)\".")
            }
            return .valid(action)
        case .runTerminalCommand:
            return .invalid("Terminal commands are locked. Use the app, browser, or web tools instead.")
        case .webSearch:
            let query = (action.text ?? action.targetText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return .invalid("web_search needs a query in \"text\".") }
            return .valid(action.with(text: query))
        case .readWebpage:
            let url = (action.text ?? action.targetText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let checked = webURL(url) else {
                return .invalid("read_webpage needs a full http(s) URL in \"text\".")
            }
            return .valid(action.with(text: checked))
        case .switchApp:
            let name = (action.text ?? action.targetText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return .invalid("switch_app needs the app name in \"target_text\".")
            }
            return .valid(action)
        case .scroll:
            if let id = action.targetElementID, !elements.contains(where: { $0.id == id }) {
                return .invalid("Scroll element id is not in the latest observation. Use observe first, or omit id to scroll the window.")
            }
            return .valid(action)
        case .observe, .screenshot, .copy, .wait, .finish, .askUser, .typeTextSensitive:
            return .valid(action)
        }
    }

    private static func webURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

extension StructuredAction {
    func withTarget(_ target: String) -> StructuredAction {
        StructuredAction(id: id, type: type, targetKind: targetKind, targetText: target, coordinates: coordinates, targetElementID: targetElementID, text: text, command: command, expectedResult: expectedResult, riskLevel: riskLevel, reason: reason)
    }

    func inScreenPoints(using screenshot: ScreenshotAttachment) -> StructuredAction {
        guard targetElementID == nil, let coordinates, [.click, .doubleClick, .typeTextSafe].contains(type) else { return self }
        return StructuredAction(id: id, type: type, targetKind: targetKind, targetText: targetText, coordinates: screenshot.toScreenPoints(coordinates), targetElementID: targetElementID, text: text, command: command, expectedResult: expectedResult, riskLevel: riskLevel, reason: reason)
    }

    func with(text: String?) -> StructuredAction {
        StructuredAction(
            id: id,
            type: type,
            targetKind: targetKind,
            targetText: targetText,
            coordinates: coordinates,
            targetElementID: targetElementID,
            text: text,
            command: command,
            expectedResult: expectedResult,
            riskLevel: riskLevel,
            reason: reason
        )
    }

    /// Identity of what the action does, ignoring its explanation fields.
    var signature: String {
        [type.rawValue, targetText, text ?? "", command ?? "", targetElementID.map(String.init) ?? "",
         coordinates.map { $0.map { String(Int($0.rounded())) }.joined(separator: ",") } ?? ""]
            .joined(separator: "|")
    }

    /// The question an ask_user action poses.
    var question: String {
        let candidates = [text, targetText, reason].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return candidates.first { !$0.isEmpty && $0.count > 3 } ?? "What should I do next?"
    }
}
