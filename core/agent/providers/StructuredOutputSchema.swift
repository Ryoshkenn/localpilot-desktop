import Foundation

/// Compact model-facing schema. Legacy verbose actions still decode in logs.
public enum StructuredOutputSchema {
    public static var action: String { serialize(actionSchemaObject) }
    public static var plan: String {
        serialize([
            "type": "object", "additionalProperties": false,
            "properties": [
                "reply": ["type": "string"],
                "actions": ["type": "array", "maxItems": 6, "items": actionSchemaObject],
                "todo": ["type": "array", "items": ["type": "string"]]
            ],
            "anyOf": [["required": ["reply"]], ["required": ["actions"]]]
        ])
    }

    private static var actionSchemaObject: [String: Any] {
        [
            "type": "object", "additionalProperties": false, "required": ["type"],
            "properties": [
                "type": ["type": "string", "enum": ActionType.allCases.map(\.rawValue)],
                "target": ["type": "string"], "id": ["type": "integer", "minimum": 0],
                "text": ["type": "string"], "url": ["type": "string"], "key": ["type": "string"],
                "coordinates": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                "command": ["type": "string"]
            ]
        ]
    }

    private static func serialize(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
