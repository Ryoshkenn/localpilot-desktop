import Foundation

/// JSON values keep model arguments typed and Sendable without sharing `Any`.
public enum ToolValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([ToolValue]), object([String: ToolValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([ToolValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ToolValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var string: String? { if case .string(let v) = self { v } else { nil } }
    var number: Double? { if case .number(let v) = self { v } else { nil } }
    var strings: [String]? {
        guard case .array(let values) = self, values.allSatisfy({ $0.string != nil }) else { return nil }
        return values.compactMap(\.string)
    }
}

public struct NativeToolCall: Codable, Equatable, Sendable {
    public struct Function: Codable, Equatable, Sendable {
        public var name: String
        public var arguments: String
    }
    public var id: String
    public var type: String = "function"
    public var function: Function
}

public struct NativeMessage: Sendable, Equatable {
    public var role: String
    public var content: String?
    public var toolCalls: [NativeToolCall] = []
    public var toolCallID: String? = nil
    public var reasoningContent: String? = nil
    public var screenshot: ScreenshotAttachment? = nil

    var payload: [String: Any] {
        var value: [String: Any] = ["role": role]
        if let screenshot {
            value["content"] = [
                ["type": "text", "text": content ?? "Current screen"],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + screenshot.jpegBase64]]
            ]
        } else { value["content"] = content.map { $0 as Any } ?? NSNull() }
        if !toolCalls.isEmpty {
            value["tool_calls"] = toolCalls.map {
                ["id": $0.id, "type": $0.type, "function": ["name": $0.function.name, "arguments": $0.function.arguments]] as [String: Any]
            }
        }
        if let toolCallID { value["tool_call_id"] = toolCallID }
        if let reasoningContent { value["reasoning_content"] = reasoningContent }
        return value
    }
}

public struct ToolParameter: Sendable {
    public enum Kind: Sendable { case string, integer, number, strings }
    public var name: String
    public var kind: Kind
    public var description: String
    public var required: Bool = true
    /// Allowed values, advertised to the model as a JSON-schema enum. The
    /// resolver still decides what to accept, so aliases can keep working.
    public var options: [String]? = nil

    var schema: [String: Any] {
        let type: String = switch kind { case .string: "string"; case .integer: "integer"; case .number: "number"; case .strings: "array" }
        var schema: [String: Any] = ["type": required ? type as Any : [type, "null"], "description": description]
        if case .strings = kind { schema["items"] = ["type": "string"] }
        if let options { schema["enum"] = required ? options : (options as [Any]) + [NSNull()] }
        return schema
    }

    func accepts(_ value: ToolValue) -> Bool {
        if value == .null { return !required }
        switch kind {
        case .string: return value.string != nil
        case .integer: return value.number.map { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) && $0.rounded() == $0 } ?? false
        case .number: return value.number?.isFinite == true
        case .strings: return value.strings != nil
        }
    }
}

public enum NativeToolIntent: Sendable { case action(StructuredAction), todo([String]) }

/// A tool owns its public signature and argument-to-action adapter. The registry
/// feeds both the API schemas and dispatch, so names/arguments cannot drift.
public struct NativeToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let parameters: [ToolParameter]
    let resolve: @Sendable ([String: ToolValue]) throws -> NativeToolIntent

    public var payload: [String: Any] {
        ["type": "function", "function": [
            "name": name, "description": description,
            "parameters": ["type": "object", "additionalProperties": false,
                           "properties": Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.schema) }),
                           "required": parameters.filter(\.required).map(\.name)]
        ]]
    }

    public func decode(arguments: String) throws -> NativeToolIntent {
        guard let values = try? JSONDecoder().decode([String: ToolValue].self, from: Data(arguments.utf8)),
              Set(values.keys).isSubset(of: Set(parameters.map(\.name))) else {
            throw NativeToolError.invalidArguments("\(name) expects an object containing only its documented arguments.")
        }
        for parameter in parameters {
            guard let value = values[parameter.name] else {
                if parameter.required { throw NativeToolError.invalidArguments("\(name) needs \(parameter.name).") }
                continue
            }
            guard parameter.accepts(value) else { throw NativeToolError.invalidArguments("Invalid \(parameter.name) for \(name).") }
        }
        return try resolve(values)
    }
}

public enum NativeToolError: LocalizedError, Sendable {
    case invalidArguments(String)
    case unsupported
    case invalidResponse
    case truncated
    case tooManyCorrections
    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let reason): reason
        case .unsupported: "This provider does not support native tools. Choose a tool-capable model/server or JSON compatibility in Settings."
        case .invalidResponse: "The server returned an invalid native tool response. Check its model chat template and tool parser, or select JSON compatibility in Settings."
        case .truncated: "The model response was cut off. No partial tool call was executed."
        case .tooManyCorrections: "The model repeatedly returned invalid tool calls. Check the server's tool support or select JSON compatibility in Settings."
        }
    }
}

public enum NativeToolRegistry {
    private static func parameter(_ name: String, _ kind: ToolParameter.Kind, _ description: String, optional: Bool = false, options: [String]? = nil) -> ToolParameter {
        ToolParameter(name: name, kind: kind, description: description, required: !optional, options: options)
    }

    private static func action(_ type: ActionType, target: String = "", text: String? = nil, id: Int? = nil, coordinates: [Double]? = nil, command: String? = nil) -> NativeToolIntent {
        .action(StructuredAction(type: type, targetKind: "", targetText: target, coordinates: coordinates, targetElementID: id, text: text, command: command, expectedResult: "", riskLevel: .low, reason: ""))
    }

    private static func screenshotAction(area: String?) throws -> NativeToolIntent {
        guard let area = ScreenshotArea(rawValue: area?.lowercased() ?? "window") else {
            throw NativeToolError.invalidArguments("Screenshot area must be \"window\" or \"screen\".")
        }
        return action(.screenshot, target: area.rawValue)
    }

    private static func pointer(_ type: ActionType, description: String) -> NativeToolDefinition {
        NativeToolDefinition(name: type.rawValue, description: description, parameters: [
            parameter("x", .number, "0-1000 across your latest screenshot (0 = left edge).", optional: true),
            parameter("y", .number, "0-1000 down your latest screenshot (0 = top edge).", optional: true),
            parameter("id", .integer, "Element ID from app_state, instead of x and y.", optional: true)
        ]) { args in
            let id = args["id"]?.number.map(Int.init)
            let x = args["x"]?.number, y = args["y"]?.number
            guard (id != nil && x == nil && y == nil) || (id == nil && x != nil && y != nil) else {
                throw NativeToolError.invalidArguments("Use either id or both x and y.")
            }
            return action(type, id: id, coordinates: x.flatMap { x in y.map { [x, $0] } })
        }
    }

    public static let definitions: [NativeToolDefinition] = [
        NativeToolDefinition(name: "open_app", description: "Open or activate a macOS app.", parameters: [parameter("name", .string, "Application name, e.g. Notes or Google Chrome.")]) {
            action(.switchApp, target: $0["name"]!.string!)
        },
        NativeToolDefinition(name: "observe", description: "Look at the computer. By default you get a screenshot of the front app's window; click and type at points in it with x and y on a 0-1000 scale. mode \"app_state\" gives a text list of the app's elements with IDs instead, only for when you need exact text or can't make something out in the picture.", parameters: [
            parameter("mode", .string, "\"screenshot\" (default) or \"app_state\".", optional: true, options: ["screenshot", "app_state"]),
            parameter("area", .string, "Screenshot only: \"window\" (the front app's window, default) or \"screen\" (the whole display).", optional: true, options: ["window", "screen"]),
        ]) { args in
            switch args["mode"]?.string?.lowercased() ?? "screenshot" {
            case "screenshot", "picture", "image": return try screenshotAction(area: args["area"]?.string)
            case "app_state", "elements", "text", "accessibility": return action(.observe)
            default: throw NativeToolError.invalidArguments("observe mode must be \"screenshot\" or \"app_state\".")
            }
        },
        pointer(.click, description: "Click a point in your latest screenshot (x, y), or an element ID from app_state."),
        pointer(.doubleClick, description: "Double-click a point in your latest screenshot (x, y), or an element ID from app_state."),
        NativeToolDefinition(name: "type_text", description: "Type text. Give x and y from your latest screenshot to click that box first, an element ID from app_state to fill that field, or neither to type into the focused field.", parameters: [
            parameter("text", .string, "Text to enter."),
            parameter("x", .number, "0-1000 across your latest screenshot, at the box.", optional: true),
            parameter("y", .number, "0-1000 down your latest screenshot, at the box.", optional: true),
            parameter("id", .integer, "Field ID from app_state.", optional: true),
        ]) { args in
            let id = args["id"]?.number.map(Int.init)
            let x = args["x"]?.number, y = args["y"]?.number
            guard (x == nil) == (y == nil), id == nil || x == nil else {
                throw NativeToolError.invalidArguments("type_text takes x and y together, or an id, or neither.")
            }
            return action(.typeTextSafe, text: args["text"]!.string!, id: id, coordinates: x.flatMap { x in y.map { [x, $0] } })
        },
        NativeToolDefinition(name: "press_key", description: "Press a key or shortcut, e.g. return, tab, cmd+a, cmd+shift+t.", parameters: [parameter("key", .string, "Key or shortcut.")]) { action(.pressKey, text: $0["key"]!.string!) },
        NativeToolDefinition(name: "browser_new_tab", description: "Open a Chrome tab. Omit URL for a blank tab.", parameters: [parameter("url", .string, "Full http(s) URL.", optional: true)]) { action(.browserNewTab, text: $0["url"]?.string) },
        NativeToolDefinition(name: "browser_navigate", description: "Navigate Chrome's active tab to an http(s) URL.", parameters: [parameter("url", .string, "Full http(s) URL.")]) { action(.browserNavigate, text: $0["url"]!.string!) },
        NativeToolDefinition(name: "browser_switch_tab", description: "Switch Chrome tabs in its front window; observe lists tab numbers.", parameters: [parameter("tab", .integer, "1-based tab number.")]) { action(.browserSwitchTab, target: String(Int($0["tab"]!.number!))) },
        NativeToolDefinition(name: "browser_close_tab", description: "Close a Chrome tab in its front window.", parameters: [parameter("tab", .integer, "1-based tab number from observe.")]) { action(.browserCloseTab, target: String(Int($0["tab"]!.number!))) },
        NativeToolDefinition(name: "wait", description: "Wait briefly for an app or page to update.", parameters: []) { _ in action(.wait) },
        NativeToolDefinition(name: "update_todo", description: "Optional checklist for a longer task. Replace the list; pass [] to clear it. Unnecessary for quick requests.", parameters: [parameter("items", .strings, "Short checklist items.")]) { .todo($0["items"]!.strings!) },
        NativeToolDefinition(name: "web_search", description: "Search the web and get titles, URLs and snippets. Use it whenever you are unsure of a fact, a current event, or the exact URL of a page, instead of guessing.", parameters: [parameter("query", .string, "Search query.")]) { action(.webSearch, text: $0["query"]!.string!) },
        NativeToolDefinition(name: "read_webpage", description: "Fetch a web page and read its text without opening the browser. Good for checking search results. Pages that need JavaScript may be empty; open those in Chrome.", parameters: [parameter("url", .string, "Full http(s) URL.")]) { action(.readWebpage, text: $0["url"]!.string!) }
    ]

    public static func resolve(_ call: NativeToolCall) throws -> NativeToolIntent {
        // Screenshots are an observe mode now. Models that still call the old
        // `screenshot` tool get the same thing.
        if call.function.name == "scroll" {
            throw NativeToolError.invalidArguments("Scrolling isn't available. Work from screenshots: click what you can see, follow links, navigate to a URL, or use read_webpage to read a whole page.")
        }
        if call.function.name == "screenshot" {
            let area = (try? JSONDecoder().decode([String: ToolValue].self, from: Data(call.function.arguments.utf8)))?["area"]?.string
            return try screenshotAction(area: area)
        }
        guard let definition = definitions.first(where: { $0.name == call.function.name }) else {
            throw NativeToolError.invalidArguments("Unknown tool \(call.function.name). Use one of the provided tools.")
        }
        return try definition.decode(arguments: call.function.arguments)
    }
}
