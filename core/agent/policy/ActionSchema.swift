import Foundation

public enum ActionType: String, Codable, Sendable, CaseIterable {
    case observe
    case screenshot
    case click
    case doubleClick = "double_click"
    case typeTextSafe = "type_text"
    case typeTextSensitive = "type_text_sensitive"
    case pressKey = "press_key"
    case scroll
    case copy
    case paste
    case openURL = "open_url"
    case runTerminalCommand = "run_terminal_command"
    case switchApp = "open_app"
    case browserNewTab = "browser_new_tab"
    case browserNavigate = "browser_navigate"
    case browserSwitchTab = "browser_switch_tab"
    case browserCloseTab = "browser_close_tab"
    case wait
    case finish
    case askUser = "ask_user"
    case webSearch = "web_search"
    case readWebpage = "read_webpage"

    /// Alternate spellings small models commonly produce. Older LocalPilot
    /// names are included so saved logs and prompts keep decoding.
    static let aliases: [String: ActionType] = [
        "switch_app": .switchApp, "launch_app": .switchApp, "activate_app": .switchApp, "open_application": .switchApp,
        "type_text_safe": .typeTextSafe, "type": .typeTextSafe, "input": .typeTextSafe, "fill": .typeTextSafe,
        "key": .pressKey, "keypress": .pressKey, "hotkey": .pressKey, "shortcut": .pressKey,
        "new_tab": .browserNewTab, "navigate": .browserNavigate, "go_to": .browserNavigate,
        "switch_tab": .browserSwitchTab, "close_tab": .browserCloseTab,
        "done": .finish, "ask": .askUser, "look": .observe,
        "search": .webSearch, "search_web": .webSearch, "google": .webSearch,
        "fetch": .readWebpage, "read_url": .readWebpage, "fetch_url": .readWebpage, "read_page": .readWebpage,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_")
        guard let type = ActionType(rawValue: normalized) ?? Self.aliases[normalized] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown action type \(raw)"))
        }
        self = type
    }

    /// Whether the action affects the computer (and so engages Agent Mode).
    public var touchesComputer: Bool {
        switch self {
        case .wait, .finish, .askUser, .webSearch, .readWebpage: false
        default: true
        }
    }
}

public enum RiskLevel: String, Codable, Sendable {
    case low
    case medium
    case high
}

public struct StructuredAction: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let type: ActionType
    public let targetKind: String
    public let targetText: String
    public let coordinates: [Double]?
    /// Accessibility element in the latest observation. The executor uses its
    /// live handle for semantic press/fill, falling back to its current frame.
    public let targetElementID: Int?
    public let text: String?
    public let command: String?
    public let expectedResult: String
    public let riskLevel: RiskLevel
    public let reason: String

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case targetKind = "target_kind"
        case targetText = "target_text"
        case coordinates
        case targetElementID = "target_element_id"
        case text
        case command
        case expectedResult = "expected_result"
        case riskLevel = "risk_level"
        case reason
    }

    public init(
        id: UUID = UUID(),
        type: ActionType,
        targetKind: String,
        targetText: String,
        coordinates: [Double]? = nil,
        targetElementID: Int? = nil,
        text: String? = nil,
        command: String? = nil,
        expectedResult: String,
        riskLevel: RiskLevel,
        reason: String
    ) {
        self.id = id
        self.type = type
        self.targetKind = targetKind
        self.targetText = targetText
        self.coordinates = coordinates
        self.targetElementID = targetElementID
        self.text = text
        self.command = command
        self.expectedResult = expectedResult
        self.riskLevel = riskLevel
        self.reason = reason
    }

    /// Short field names small models tend to use; accepted alongside the
    /// canonical names. Only `type` is required.
    private enum AliasKeys: String, CodingKey {
        case target
        case element
        case elementID = "element_id"
        case shortID = "id"
        case url
        case query
        case key
        case risk
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let aliases = try decoder.container(keyedBy: AliasKeys.self)
        self.type = try container.decode(ActionType.self, forKey: .type)
        self.id = UUID()
        self.targetKind = (try? container.decodeIfPresent(String.self, forKey: .targetKind)) ?? ""
        self.coordinates = Self.decodeCoordinates(container)
        // `id` is the element number in the short form; a UUID `id` from an
        // encoded action is ignored because every decoded action gets a new id.
        self.targetElementID = Self.decodeInt(container, .targetElementID)
            ?? Self.decodeInt(aliases, .elementID) ?? Self.decodeInt(aliases, .element) ?? Self.decodeInt(aliases, .shortID)
        let url = try? aliases.decodeIfPresent(String.self, forKey: .url)
        let key = try? aliases.decodeIfPresent(String.self, forKey: .key)
        let query = try? aliases.decodeIfPresent(String.self, forKey: .query)
        self.text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? url ?? query ?? key
        self.targetText = (try? container.decodeIfPresent(String.self, forKey: .targetText))
            ?? (try? aliases.decodeIfPresent(String.self, forKey: .target))
            ?? url ?? key ?? ""
        self.command = try? container.decodeIfPresent(String.self, forKey: .command)
        self.expectedResult = (try? container.decodeIfPresent(String.self, forKey: .expectedResult)) ?? ""
        self.riskLevel = (try? container.decodeIfPresent(RiskLevel.self, forKey: .riskLevel))
            ?? (try? aliases.decodeIfPresent(RiskLevel.self, forKey: .risk)) ?? .low
        self.reason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? ""
    }

    private static func decodeInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite, value >= 0, value < Double(Int.max), value.rounded() == value { return Int(value) }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func decodeCoordinates(_ container: KeyedDecodingContainer<CodingKeys>) -> [Double]? {
        if let values = try? container.decodeIfPresent([Double].self, forKey: .coordinates) { return values }
        // Some models emit {"x":..,"y":..} instead of a pair.
        if let point = try? container.decodeIfPresent([String: Double].self, forKey: .coordinates),
           let x = point["x"], let y = point["y"] {
            return [x, y]
        }
        return nil
    }

    /// Human-readable one-liner used in step cards and logs.
    public var summary: String {
        if !expectedResult.isEmpty { return expectedResult }
        let subject = [text, targetText.isEmpty ? nil : targetText, command, targetElementID.map { "element \($0)" }]
            .compactMap { $0 }
            .first ?? ""
        return subject.isEmpty ? type.rawValue : "\(type.rawValue) \(subject)"
    }
}

/// An ordered plan of one or more actions proposed in a single planner turn.
///
/// The planner may look ahead and propose several steps at once, but this is
/// only a *proposal*: the orchestrator still gates and executes each action one
/// at a time (policy + guard + Stop/Pause checks + re-observation between
/// steps). No action in a plan executes without passing the full pipeline.
public struct ActionPlan: Codable, Equatable, Sendable {
    /// Steps to run, possibly empty for a pure chat reply.
    public let actions: [StructuredAction]
    /// Text for the user. Alone it is a chat answer; with actions it is the
    /// final message once they all succeed, so no extra planning call is needed.
    public let reply: String?
    /// Optional checklist for longer tasks. Never required.
    public let todo: [String]?

    public init(actions: [StructuredAction], reply: String? = nil, todo: [String]? = nil) {
        self.actions = actions
        self.reply = reply
        self.todo = todo
    }

    private enum CodingKeys: String, CodingKey {
        case actions
        case action
        case reply
        case message
        case response
        case todo
        case plan
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var actions = try container.decodeIfPresent([StructuredAction].self, forKey: .actions) ?? []
        if actions.isEmpty, let single = try container.decodeIfPresent(StructuredAction.self, forKey: .action) {
            actions = [single]
        }
        let reply = [CodingKeys.reply, .message, .response]
            .lazy
            .compactMap { try? container.decodeIfPresent(String.self, forKey: $0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let todo = (try? container.decodeIfPresent([String].self, forKey: .todo))
            ?? (try? container.decodeIfPresent([String].self, forKey: .plan))
        guard !actions.isEmpty || reply != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Plan has neither actions nor a reply"))
        }
        self.actions = actions
        self.reply = reply
        self.todo = todo?.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actions, forKey: .actions)
        try container.encodeIfPresent(reply, forKey: .reply)
        try container.encodeIfPresent(todo, forKey: .todo)
    }
}

public struct AgentContext: Codable, Equatable, Sendable {
    public var activeApp: String?
    public var activeWindow: String?
    public var currentDomain: String?
    public var allowedDomains: Set<String>
    public var allowedApps: Set<String>
    public var allowedFolders: Set<String>
    public var visibleText: String
    public var activeFieldKind: String?
    /// Actionable elements from the observation this context was built from.
    /// Used only to show where an element-targeted action will land.
    public var elements: [AXElementSnapshot] = []
    public var screenshot: ScreenshotAttachment? = nil

    public static let empty = AgentContext(
        activeApp: nil,
        activeWindow: nil,
        currentDomain: nil,
        allowedDomains: [],
        allowedApps: [],
        allowedFolders: [],
        visibleText: "",
        activeFieldKind: nil
    )
}

public enum PolicyClassification: String, Codable, Sendable {
    case allow
    case askUser = "ask_user"
    case block
}

public struct PolicyDecision: Codable, Equatable, Sendable {
    public let classification: PolicyClassification
    public let reason: String
}
