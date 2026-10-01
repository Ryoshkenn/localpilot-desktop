import AppKit
import CoreGraphics

/// Synthesizes mouse, keyboard, and scroll events.
@MainActor
final class Input {
    private let source = CGEventSource(stateID: .hidSystemState)

    func click(at point: CGPoint, count: Int, button: String) {
        let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case "right": (.rightMouseDown, .rightMouseUp, .right)
        case "middle": (.otherMouseDown, .otherMouseUp, .center)
        default: (.leftMouseDown, .leftMouseUp, .left)
        }
        post(.mouseMoved, at: point, button: cgButton)
        usleep(30_000)
        for index in 1...count {
            post(down, at: point, button: cgButton, clickState: Int64(index))
            usleep(25_000)
            post(up, at: point, button: cgButton, clickState: Int64(index))
            usleep(40_000)
        }
    }

    func type(_ text: String, delay: useconds_t = 6_000) {
        // Newlines become Return presses so multi-line text works in editors.
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { try? press(combo: "return") }
            typeChunks(line, delay: delay)
        }
    }

    /// Type text one character at a time. Each event carries the real key
    /// code (some web views ignore events that only carry a Unicode string)
    /// plus the Unicode string, so the right character arrives even on
    /// non-US layouts.
    private func typeChunks(_ text: String, delay: useconds_t) {
        for character in text {
            let units = Array(String(character).utf16)
            let (code, shift) = Self.keyStroke(for: character) ?? (0, false)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            if shift {
                down.flags = .maskShift
                up.flags = .maskShift
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(delay)
        }
    }

    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func keyStroke(for character: Character) -> (CGKeyCode, Bool)? {
        if character == " " { return (49, false) }
        if character == "\t" { return (48, false) }
        if let base = shifted[character], let code = keyCode(for: String(base)) { return (code, true) }
        let lower = String(character).lowercased()
        guard lower.count == 1, let code = keyCode(for: lower) else { return nil }
        return (code, character.isUppercase)
    }

    func press(combo: String) throws {
        // Accept "cmd+l", "Cmd-L", "command l", "⌘L", "ctrl+shift+tab".
        var normalized = combo.lowercased()
            .replacingOccurrences(of: "⌘", with: "cmd+")
            .replacingOccurrences(of: "⇧", with: "shift+")
            .replacingOccurrences(of: "⌥", with: "alt+")
            .replacingOccurrences(of: "⌃", with: "ctrl+")
        if !normalized.contains("+"), normalized.contains("-"), normalized.count > 1 {
            normalized = normalized.replacingOccurrences(of: "-", with: "+")
        }
        normalized = normalized.replacingOccurrences(of: " ", with: "+")
        let parts = normalized.split(separator: "+").map { String($0) }.filter { !$0.isEmpty }
        guard let keyName = parts.last else { throw HelperError("empty key combo") }
        guard let code = Self.keyCode(for: keyName) else { throw HelperError("unknown key: \(keyName)") }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command", "meta", "super", "win": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw HelperError("unknown modifier: \(modifier)")
            }
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw HelperError("could not create key event")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    func scroll(direction: String, lines: Int, at point: CGPoint) {
        post(.mouseMoved, at: point, button: .left)
        usleep(30_000)
        let (dy, dx): (Int32, Int32) = switch direction {
        case "up": (Int32(lines), 0)
        case "left": (0, Int32(lines))
        case "right": (0, -Int32(lines))
        default: (-Int32(lines), 0)
        }
        // Several small events scroll more reliably than one large one.
        let steps = max(1, lines / 3)
        for _ in 0..<steps {
            if let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                                   wheel1: dy / Int32(steps), wheel2: dx / Int32(steps), wheel3: 0) {
                event.location = point
                event.post(tap: .cghidEventTap)
            }
            usleep(25_000)
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int64 = 1) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
    }

    static func keyCode(for key: String) -> CGKeyCode? {
        let table: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "spacebar": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "forwarddelete": 117, "del": 117, "home": 115, "end": 119,
            "pageup": 116, "page_up": 116, "pgup": 116, "pagedown": 121, "page_down": 121, "pgdn": 121,
            "left": 123, "arrowleft": 123, "right": 124, "arrowright": 124, "down": 125, "arrowdown": 125,
            "up": 126, "arrowup": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
            "f10": 109, "f11": 103, "f12": 111,
        ]
        return table[key]
    }
}
