import AppKit
import Foundation

struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
final class Server {
    let target = TargetApp()
    lazy var observer = Observer(target: target)
    lazy var input = Input()
    lazy var indicator = Indicator()

    func handle(line: String) async -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["id": NSNull(), "ok": false, "error": "invalid JSON request"]
        }
        let id = request["id"] ?? NSNull()
        guard let command = request["cmd"] as? String else {
            return ["id": id, "ok": false, "error": "missing cmd"]
        }
        let args = request["args"] as? [String: Any] ?? [:]
        return await run(command: command, args: args, requestID: id)
    }

    func run(command: String, args: [String: Any], requestID: Any) async -> [String: Any] {
        do {
            let result = try await dispatch(command: command, args: args)
            return ["id": requestID, "ok": true, "result": result]
        } catch {
            return ["id": requestID, "ok": false, "error": String(describing: error)]
        }
    }

    private func dispatch(command: String, args: [String: Any]) async throws -> [String: Any] {
        switch command {
        case "ping":
            return ["pong": true, "pid": ProcessInfo.processInfo.processIdentifier]
        case "permissions":
            return [
                "accessibility": AXIsProcessTrusted(),
                "screenRecording": CGPreflightScreenCaptureAccess(),
            ]
        case "observe":
            return try observer.observe(maxElements: args.int("maxElements") ?? 150)
        case "screenshot":
            return try await Screenshot.capture(
                target: target,
                observer: observer,
                area: args.string("area") ?? "window",
                maxWidth: args.int("maxWidth") ?? 1280,
                marks: args.bool("marks") ?? false
            )
        case "click":
            return try await click(args)
        case "type":
            return try await type(args)
        case "key":
            guard let combo = args.string("keys") ?? args.string("key") else { throw HelperError("missing keys") }
            try activateTarget()
            try input.press(combo: combo)
            await settle(args, defaultMs: 250)
            return ["pressed": combo]
        case "scroll":
            return try await scroll(args)
        case "open_app":
            guard let name = args.string("name") else { throw HelperError("missing name") }
            let app = try await Apps.open(name: name)
            target.set(app)
            await target.waitForWindow(timeout: 6)
            await settle(args, defaultMs: 400)
            return ["app": app.localizedName ?? name, "bundleId": app.bundleIdentifier ?? ""]
        case "open_url":
            guard let url = args.string("url") else { throw HelperError("missing url") }
            let app = try await Apps.open(url: url, appName: args.string("app"), currentTarget: target.application)
            if let app { target.set(app) }
            await target.waitForWindow(timeout: 6)
            await observer.waitForPageLoad(timeout: args.double("timeout") ?? 8)
            await settle(args, defaultMs: 300)
            return ["opened": url, "app": app?.localizedName ?? ""]
        case "focus_app":
            guard let name = args.string("name") else { throw HelperError("missing name") }
            guard let app = Apps.running(named: name) else { throw HelperError("app not running: \(name)") }
            target.set(app)
            try activateTarget()
            await settle(args, defaultMs: 250)
            return ["app": app.localizedName ?? name]
        case "apps":
            return ["apps": Apps.runningList(), "target": target.application?.localizedName ?? NSNull()]
        case "wait":
            let ms = args.int("ms") ?? 1000
            try await Task.sleep(nanoseconds: UInt64(max(0, min(ms, 30_000))) * 1_000_000)
            return ["waited": ms]
        case "indicator":
            indicator.update(
                visible: args.bool("visible") ?? true,
                label: args.string("label"),
                point: args.double("x").flatMap { x in args.double("y").map { CGPoint(x: x, y: $0) } }
            )
            return ["ok": true]
        case "tree":
            return ["tree": observer.dumpTree(maxDepth: args.int("depth") ?? 25, maxNodes: args.int("maxNodes") ?? 1500)]
        case "select":
            guard let id = args.int("id"), let option = args.string("option") else { throw HelperError("select needs id and option") }
            guard let element = observer.element(id) else { throw HelperError("element \(id) is not on screen any more; observe again") }
            try activateTarget()
            indicator.update(visible: true, label: "choose \(option)", point: element.center)
            // Native pop-ups expose their menu: open it and press the item.
            if !element.inWeb, let chosen = await observer.select(id, option: option) {
                await settle(args, defaultMs: 300)
                return ["selected": chosen]
            }
            // Web <select>: focus without opening it and type to select.
            AXUIElementSetAttributeValue(element.handle, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try await Task.sleep(nanoseconds: 150_000_000)
            input.type(option)
            try await Task.sleep(nanoseconds: 400_000_000)
            let value = AX.string(element.handle, kAXValueAttribute) ?? ""
            if value.lowercased().hasPrefix(option.lowercased()) || value.lowercased() == option.lowercased() {
                return ["selected": value, "method": "type-ahead"]
            }
            // Last resort: open it with a real click, type, and confirm.
            input.click(at: element.center, count: 1, button: "left")
            try await Task.sleep(nanoseconds: 350_000_000)
            input.type(option)
            try input.press(combo: "return")
            await settle(args, defaultMs: 300)
            let final = AX.string(element.handle, kAXValueAttribute) ?? ""
            if !final.lowercased().contains(option.lowercased()) {
                throw HelperError("could not choose \"\(option)\"; the pop-up shows \"\(final)\"")
            }
            return ["selected": final, "method": "menu-keys"]
        case "release":
            target.release()
            indicator.update(visible: false, label: nil, point: nil)
            return ["released": true]
        default:
            throw HelperError("unknown command: \(command)")
        }
    }

    // MARK: Actions

    private func activateTarget() throws {
        guard target.activate() else {
            throw HelperError("no target app: open or focus an app first")
        }
    }

    private func click(_ args: [String: Any]) async throws -> [String: Any] {
        let count = max(1, min(args.int("count") ?? 1, 3))
        let button = args.string("button") ?? "left"
        try activateTarget()
        if let id = args.int("id") {
            guard let element = observer.element(id) else {
                throw HelperError("element \(id) is not on screen any more; observe again")
            }
            indicator.update(visible: true, label: "click \(element.summary)", point: element.center)
            var method = "mouse"
            // Chromium accepts AXPress on web links but often ignores it, so
            // page content there gets a real click.
            let chromiumWeb = element.inWeb && target.application.map(Observer.isChromium) == true
            let forceMouse = args.string("mode") == "mouse" || chromiumWeb
            if count == 1, button == "left", !forceMouse, observer.press(id) {
                method = "ax-press"
            } else {
                input.click(at: element.center, count: count, button: button)
            }
            await settle(args, defaultMs: 450)
            return ["clicked": element.summary, "method": method]
        }
        guard let x = args.double("x"), let y = args.double("y") else {
            throw HelperError("click needs an element id or x and y")
        }
        let point = CGPoint(x: x, y: y)
        indicator.update(visible: true, label: "click", point: point)
        input.click(at: point, count: count, button: button)
        await settle(args, defaultMs: 450)
        return ["clicked": ["x": x, "y": y], "method": "mouse"]
    }

    private func type(_ args: [String: Any]) async throws -> [String: Any] {
        let text = args.string("text") ?? ""
        try activateTarget()
        var focusedVia = "current focus"
        if let id = args.int("id") {
            guard let element = observer.element(id) else {
                throw HelperError("element \(id) is not on screen any more; observe again")
            }
            indicator.update(visible: true, label: "type into \(element.summary)", point: element.center)
            if observer.focus(id) {
                focusedVia = "ax-focus"
            } else {
                input.click(at: element.center, count: 1, button: "left")
                focusedVia = "click"
            }
            // Web fields open autofill suggestions on focus; let that settle.
            try await Task.sleep(nanoseconds: element.inWeb ? 300_000_000 : 120_000_000)
        }
        if args.bool("replace") ?? (args.int("id") != nil) {
            try input.press(combo: "cmd+a")
            try await Task.sleep(nanoseconds: 60_000_000)
            if text.isEmpty { try input.press(combo: "delete") }
        }
        var method = "keys"
        if !text.isEmpty, insertViaAccessibility(text) {
            method = "ax-insert"
        } else {
            input.type(text)
        }
        // Check a replaced field really holds the text: autofill pop-ups and
        // slow pages can swallow the first keystrokes.
        if let id = args.int("id"), args.bool("replace") ?? true, !text.isEmpty, !text.contains("\n"),
           let element = observer.element(id), element.role != "password" {
            try await Task.sleep(nanoseconds: 150_000_000)
            if !(AX.string(element.handle, kAXValueAttribute) ?? "").contains(text) {
                try input.press(combo: "cmd+a")
                try input.press(combo: "delete")
                try await Task.sleep(nanoseconds: 250_000_000)
                input.type(text, delay: 40_000)
                method = "keys-retry"
                try await Task.sleep(nanoseconds: 150_000_000)
                if !(AX.string(element.handle, kAXValueAttribute) ?? "").contains(text),
                   AXUIElementSetAttributeValue(element.handle, kAXValueAttribute as CFString, text as CFString) == .success {
                    method = "ax-value"
                }
            }
        }
        if args.bool("submit") ?? false {
            try await Task.sleep(nanoseconds: 80_000_000)
            try input.press(combo: "return")
        }
        await settle(args, defaultMs: (args.bool("submit") ?? false) ? 700 : 200)
        return ["typed": text.count, "focus": focusedVia, "method": method, "submitted": args.bool("submit") ?? false]
    }

    /// Insert text into a native (non-web) text control through accessibility.
    /// Unlike synthesized keystrokes this bypasses autocorrect and smart
    /// quotes, and is instant. Web content needs real key events for its
    /// input handlers, so it is left to the keyboard path.
    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let app = target.application else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = AX.element(appElement, kAXFocusedUIElementAttribute) else { return false }
        let role = AX.string(focused, kAXRoleAttribute) ?? ""
        guard ["AXTextArea", "AXTextField", "AXComboBox"].contains(role), !isInsideWebContent(focused) else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        let before = AX.string(focused, kAXValueAttribute) ?? ""
        guard AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        let after = AX.string(focused, kAXValueAttribute) ?? ""
        return after != before || after.contains(text)
    }

    private func isInsideWebContent(_ element: AXUIElement) -> Bool {
        var node: AXUIElement? = element
        var depth = 0
        while let current = node, depth < 40 {
            let role = AX.string(current, kAXRoleAttribute)
            if role == "AXWebArea" { return true }
            if role == "AXWindow" || role == "AXApplication" { return false }
            node = AX.element(current, kAXParentAttribute)
            depth += 1
        }
        return false
    }

    private func scroll(_ args: [String: Any]) async throws -> [String: Any] {
        let direction = (args.string("direction") ?? "down").lowercased()
        let amount = max(1, min(args.int("amount") ?? 5, 30))
        try activateTarget()
        var point: CGPoint?
        if let id = args.int("id"), let element = observer.element(id) {
            point = element.center
        } else if let frame = target.focusedWindowFrame() {
            point = CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.6)
        }
        guard let point else { throw HelperError("nothing to scroll") }
        indicator.update(visible: true, label: "scroll \(direction)", point: point)
        input.scroll(direction: direction, lines: amount, at: point)
        await settle(args, defaultMs: 350)
        return ["scrolled": direction, "amount": amount]
    }

    private func settle(_ args: [String: Any], defaultMs: Int) async {
        let ms = args.int("settleMs") ?? defaultMs
        if ms > 0 { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
        await observer.waitForPageLoad(timeout: 2)
    }

    // MARK: Encoding

    static func encode(_ object: [String: Any], pretty: Bool) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"failed to encode response"}"#
        }
        return string
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let value = self[key] as? String { return value }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? NSNumber { return value.intValue }
        if let value = self[key] as? String {
            let digits = value.trimmingCharacters(in: CharacterSet(charactersIn: "#[] "))
            return Int(digits)
        }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = self[key] as? NSNumber { return value.doubleValue }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? NSNumber { return value.boolValue }
        if let value = self[key] as? String { return ["true", "yes", "1"].contains(value.lowercased()) }
        return nil
    }
}
