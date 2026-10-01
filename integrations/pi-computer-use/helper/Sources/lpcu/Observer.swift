import AppKit
import ApplicationServices

/// One actionable element from the last observation.
struct ObservedElement {
    let id: Int
    let role: String
    let label: String
    let value: String?
    let frame: CGRect
    let handle: AXUIElement
    let focused: Bool
    let pressable: Bool
    var inWeb = false

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    var summary: String {
        label.isEmpty ? "[\(id)] \(role)" : "[\(id)] \(role) \"\(label)\""
    }

    var json: [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "role": role,
            "label": label,
            "x": Int(frame.midX.rounded()),
            "y": Int(frame.midY.rounded()),
            "w": Int(frame.width.rounded()),
            "h": Int(frame.height.rounded()),
        ]
        if let value { object["value"] = value }
        if focused { object["focused"] = true }
        return object
    }
}

/// Reads the target app's accessibility tree into a flat, numbered list of
/// actionable elements plus the visible text, which is what small models can
/// reason over far better than raw pixels.
@MainActor
final class Observer {
    private let target: TargetApp
    private var registry: [Int: ObservedElement] = [:]

    init(target: TargetApp) {
        self.target = target
    }

    func element(_ id: Int) -> ObservedElement? {
        guard let element = registry[id] else { return nil }
        // The element may have moved or disappeared since the observation.
        if let frame = AX.frame(element.handle), frame.width > 0 {
            return ObservedElement(id: element.id, role: element.role, label: element.label, value: element.value,
                                   frame: frame, handle: element.handle, focused: element.focused, pressable: element.pressable,
                                   inWeb: element.inWeb)
        }
        return nil
    }

    var currentElements: [ObservedElement] {
        registry.values.sorted { $0.id < $1.id }
    }

    // MARK: Observe

    private static let roleNames: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "textfield", "AXTextArea": "textarea",
        "AXSearchField": "searchfield", "AXSecureTextField": "password", "AXCheckBox": "checkbox",
        "AXRadioButton": "radio", "AXPopUpButton": "popup", "AXComboBox": "combobox",
        "AXMenuButton": "menubutton", "AXMenuItem": "menuitem", "AXSlider": "slider", "AXTab": "tab",
        "AXTabButton": "tab", "AXDisclosureTriangle": "disclosure", "AXRow": "row", "AXIncrementor": "stepper",
        "AXColorWell": "colorwell", "AXDateField": "datefield", "AXSwitch": "switch", "AXToggle": "toggle",
        "AXCell": "cell", "AXImage": "image", "AXMenuBarItem": "menu",
    ]

    /// Roles listed only when they carry a press action (web divs, images).
    private static let pressOnlyRoles: Set<String> = ["AXImage", "AXGroup", "AXStaticText", "AXCell"]

    private static let pressRoles: Set<String> = [
        "button", "link", "checkbox", "radio", "menuitem", "popup", "menubutton", "tab", "disclosure",
        "switch", "toggle", "image", "menu",
    ]

    private static let textRoles: Set<String> = ["textfield", "textarea", "searchfield", "password", "combobox", "datefield"]

    private struct Walk {
        var elements: [ObservedElement] = []
        var text: [String] = []
        var textLength = 0
        var visited = 0
        var bounds: CGRect = .null
        var focused: AXUIElement?
        var webArea: AXUIElement?
        var url: String?
        var maxElements = 150
        /// Set while walking page content, so it can be listed before browser chrome.
        var inWeb = false
        var skip: AXUIElement?
    }

    func observe(maxElements: Int) throws -> [String: Any] {
        registry = [:]
        guard AXIsProcessTrusted() else { throw HelperError("Accessibility permission is not granted to the terminal running pi") }
        guard let app = target.application else {
            return ["app": NSNull(), "elements": [], "text": "", "note": "no target app; open one with open_app"]
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if Self.isChromium(app) {
            // Chromium only builds its web accessibility tree for clients that ask.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }

        var walk = Walk()
        walk.maxElements = max(10, min(maxElements, 400))
        walk.focused = AX.element(appElement, kAXFocusedUIElementAttribute)
        let window = target.focusedWindow()
        walk.bounds = Self.visibleBounds(window: window)

        // Open menus are modal and float outside the window; list them first.
        for menu in openMenus(appElement) {
            visit(menu, depth: 0, insideElement: false, into: &walk)
        }
        if let window {
            // Page content first: it's what tasks are about, and browser
            // chrome (tab strips, sidebars) can otherwise use up the budget.
            if let webArea = findWebArea() {
                walk.inWeb = true
                visit(webArea, depth: 0, insideElement: false, into: &walk)
                walk.inWeb = false
                walk.skip = webArea
            }
            visit(window, depth: 0, insideElement: false, into: &walk)
        } else {
            visit(appElement, depth: 0, insideElement: false, into: &walk)
        }

        for element in walk.elements { registry[element.id] = element }

        var result: [String: Any] = [
            "app": app.localizedName ?? "",
            "bundleId": app.bundleIdentifier ?? "",
            "window": window.flatMap { AX.string($0, kAXTitleAttribute) } ?? "",
            "elements": walk.elements.map(\.json),
            "text": walk.text.joined(separator: " | "),
            "truncated": walk.elements.count >= walk.maxElements,
        ]
        if let url = walk.url { result["url"] = url }
        if let scroll = Self.scrollPosition(webArea: walk.webArea, window: window) { result["scroll"] = scroll }
        if let frame = window.flatMap(AX.frame) {
            result["windowFrame"] = ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
        }
        if let focused = walk.elements.first(where: \.focused) { result["focusedId"] = focused.id }
        return result
    }

    func openMenus(_ appElement: AXUIElement) -> [AXUIElement] {
        var menus: [AXUIElement] = []
        for child in AX.elements(appElement, kAXChildrenAttribute) ?? [] where AX.string(child, kAXRoleAttribute) == "AXMenu" {
            menus.append(child)
        }
        // Web pop-up menus (Safari <select>) open in their own small window.
        for window in AX.elements(appElement, kAXWindowsAttribute) ?? []
        where AX.string(window, kAXSubroleAttribute) != "AXStandardWindow" {
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            while !queue.isEmpty {
                let (node, depth) = queue.removeFirst()
                if AX.string(node, kAXRoleAttribute) == "AXMenu" { menus.append(node); continue }
                if depth < 4 { queue += (AX.elements(node, kAXChildrenAttribute) ?? []).map { ($0, depth + 1) } }
            }
        }
        if let menuBar = AX.element(appElement, kAXMenuBarAttribute) {
            for item in AX.elements(menuBar, kAXChildrenAttribute) ?? [] where AX.bool(item, kAXSelectedAttribute) == true {
                menus.append(contentsOf: (AX.elements(item, kAXChildrenAttribute) ?? []).filter {
                    AX.string($0, kAXRoleAttribute) == "AXMenu"
                })
            }
        }
        return menus
    }

    private func visit(_ node: AXUIElement, depth: Int, insideElement: Bool, into walk: inout Walk) {
        guard depth <= 60, walk.elements.count < walk.maxElements, walk.visited < 8000 else { return }
        walk.visited += 1
        if let skip = walk.skip, CFEqual(skip, node) { return }

        let rawRole = AX.string(node, kAXRoleAttribute) ?? ""
        let subrole = AX.string(node, kAXSubroleAttribute)
        if rawRole == "AXWebArea", walk.webArea == nil {
            walk.webArea = node
            walk.url = AX.url(node, "AXURL")
        }

        // Skip hidden and off-screen subtrees early (big win on long web pages).
        let frame = AX.frame(node)
        if let frame, !walk.bounds.isNull, frame.width > 0, frame.height > 0, !walk.bounds.intersects(frame),
           rawRole != "AXWindow", rawRole != "AXMenu" {
            return
        }

        var isElement = false
        let roleKey = subrole == "AXSecureTextField" || subrole == "AXSearchField" || subrole == "AXTabButton"
            || subrole == "AXSwitch" || subrole == "AXToggle" ? subrole! : rawRole
        if var role = Self.roleNames[roleKey] {
            if Self.pressOnlyRoles.contains(rawRole) && !AX.actions(node).contains(kAXPressAction as String) {
                role = ""
            }
            if !role.isEmpty, let frame, frame.width > 2, frame.height > 2,
               walk.bounds.isNull || walk.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
               AX.bool(node, kAXEnabledAttribute) != false, AX.bool(node, "AXHidden") != true {
                let label = Self.label(of: node, role: role)
                // Unlabeled cells, images, and thin splitters add noise without
                // telling the model anything.
                let keepsUnlabeled = Self.textRoles.contains(role)
                    || ["checkbox", "radio", "popup", "slider", "stepper", "switch", "toggle", "combobox"].contains(role)
                let noise = label.isEmpty && (!keepsUnlabeled || min(frame.width, frame.height) < 8)
                if !noise {
                    let id = walk.elements.count
                    let focused = walk.focused.map { CFEqual($0, node) } ?? false
                    walk.elements.append(ObservedElement(
                        id: id, role: role, label: label, value: Self.value(of: node, role: role),
                        frame: frame, handle: node, focused: focused,
                        pressable: Self.pressRoles.contains(role), inWeb: walk.inWeb
                    ))
                    isElement = true
                }
            }
        }

        var isHeading = false
        if !insideElement, !isElement, rawRole == "AXHeading", walk.textLength < 2500 {
            let text = Self.clean(AX.string(node, kAXTitleAttribute)).isEmpty
                ? Self.descendantText(node, depth: 0, budget: 120) : Self.clean(AX.string(node, kAXTitleAttribute))
            if !text.isEmpty {
                // Mark headings so the model can tell titles from body text.
                walk.text.append("# " + text)
                walk.textLength += text.count + 2
                isHeading = true
            }
        }
        if !insideElement, !isElement, rawRole == "AXStaticText", walk.textLength < 2500 {
            if let text = (AX.string(node, kAXValueAttribute) ?? AX.string(node, kAXTitleAttribute))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
               walk.text.last != text {
                let bounded = String(text.prefix(400))
                walk.text.append(bounded)
                walk.textLength += bounded.count
            }
        }

        // Rows and links already carry their text as the label.
        let childrenInside = insideElement || isHeading || (isElement && ["link", "button", "row", "menuitem", "tab"].contains(walk.elements.last?.role ?? ""))
        // Pop-up and menu-button children are their (closed) menus.
        if rawRole == "AXPopUpButton" || rawRole == "AXMenuButton" { return }
        guard let children = AX.elements(node, kAXChildrenAttribute) else { return }
        for child in children {
            if walk.elements.count >= walk.maxElements || walk.visited >= 8000 { return }
            visit(child, depth: depth + 1, insideElement: childrenInside, into: &walk)
        }
    }

    /// How far the main content is scrolled, 0 (top) to 1 (bottom), from the
    /// vertical scroll bar of the page or the window's largest scroll area.
    private static func scrollPosition(webArea: AXUIElement?, window: AXUIElement?) -> Double? {
        var scrollArea: AXUIElement?
        if let webArea, let parent = AX.element(webArea, kAXParentAttribute), AX.string(parent, kAXRoleAttribute) == "AXScrollArea" {
            scrollArea = parent
        } else if let window {
            var best: (AXUIElement, CGFloat)?
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            var visited = 0
            while !queue.isEmpty, visited < 400 {
                let (node, depth) = queue.removeFirst()
                visited += 1
                if AX.string(node, kAXRoleAttribute) == "AXScrollArea", let frame = AX.frame(node) {
                    let area = frame.width * frame.height
                    if area > (best?.1 ?? 0) { best = (node, area) }
                    continue
                }
                if depth < 8 { queue += (AX.elements(node, kAXChildrenAttribute) ?? []).map { ($0, depth + 1) } }
            }
            scrollArea = best?.0
        }
        guard let scrollArea, let bar = AX.element(scrollArea, kAXVerticalScrollBarAttribute),
              let value = AX.number(bar, kAXValueAttribute) else { return nil }
        return (value * 100).rounded() / 100
    }

    private static func visibleBounds(window: AXUIElement?) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var screens = NSScreen.screens.reduce(CGRect.null) { bounds, screen in
            let frame = screen.frame
            return bounds.union(CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height))
        }
        if let window, let frame = AX.frame(window) {
            let visible = screens.isNull ? frame : screens.intersection(frame)
            if !visible.isNull, visible.width > 0 { screens = visible }
        }
        return screens
    }

    private static func label(of node: AXUIElement, role: String) -> String {
        var candidates = [
            AX.string(node, kAXTitleAttribute),
            AX.string(node, kAXDescriptionAttribute),
            AX.element(node, kAXTitleUIElementAttribute).flatMap { AX.string($0, kAXValueAttribute) },
        ]
        if textRoles.contains(role) {
            candidates.append(AX.string(node, kAXPlaceholderValueAttribute))
        }
        candidates.append(AX.string(node, kAXHelpAttribute))
        for candidate in candidates {
            let trimmed = clean(candidate)
            if !trimmed.isEmpty { return trimmed }
        }
        if !textRoles.contains(role), role != "popup", role != "slider" {
            if let value = AX.string(node, kAXValueAttribute), !clean(value).isEmpty { return clean(value) }
            let text = descendantText(node, depth: 0, budget: 80)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func clean(_ text: String?) -> String {
        guard let text else { return "" }
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 80 ? String(collapsed.prefix(77)) + "..." : collapsed
    }

    /// Text inside an element without its own label. Icon descriptions
    /// ("Arrow Down Circle") are only used when there is no real text.
    private static func descendantText(_ node: AXUIElement, depth: Int, budget: Int) -> String {
        var images: [String] = []
        let text = descendantText(node, depth: depth, budget: budget, images: &images)
        return text.isEmpty ? clean(images.first) : text
    }

    private static func descendantText(_ node: AXUIElement, depth: Int, budget: Int, images: inout [String]) -> String {
        guard depth < 5, budget > 0, let children = AX.elements(node, kAXChildrenAttribute) else { return "" }
        var parts: [String] = []
        var remaining = budget
        for child in children.prefix(12) {
            let role = AX.string(child, kAXRoleAttribute)
            var piece = ""
            if role == "AXStaticText" || role == "AXTextField" {
                piece = clean(AX.string(child, kAXValueAttribute))
            } else if role == "AXImage" {
                let description = clean(AX.string(child, kAXDescriptionAttribute))
                if !description.isEmpty { images.append(description) }
            }
            if piece.isEmpty, role != "AXImage" {
                piece = descendantText(child, depth: depth + 1, budget: remaining, images: &images)
            }
            if !piece.isEmpty {
                parts.append(piece)
                remaining -= piece.count
                if remaining <= 0 { break }
            }
        }
        return clean(parts.joined(separator: " "))
    }

    private static func value(of node: AXUIElement, role: String) -> String? {
        switch role {
        case "textfield", "textarea", "searchfield", "combobox", "datefield":
            let value = AX.string(node, kAXValueAttribute) ?? ""
            return value.count > 200 ? String(value.prefix(197)) + "..." : value
        case "password":
            let length = (AX.string(node, kAXValueAttribute) ?? "").count
            return length == 0 ? "" : "(\(length) chars hidden)"
        case "checkbox", "radio", "switch", "toggle":
            guard let number = AX.number(node, kAXValueAttribute) else { return nil }
            return number == 0 ? "off" : "on"
        case "popup":
            return clean(AX.string(node, kAXValueAttribute) ?? AX.string(node, kAXTitleAttribute))
        case "slider", "stepper":
            return AX.number(node, kAXValueAttribute).map { String(format: "%g", $0) }
        case "tab", "row":
            return AX.bool(node, kAXSelectedAttribute) == true || AX.number(node, kAXValueAttribute) == 1 ? "selected" : nil
        default:
            return nil
        }
    }

    static func isChromium(_ app: NSRunningApplication) -> Bool {
        let ids: Set<String> = [
            "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
            "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        ]
        return app.bundleIdentifier.map(ids.contains) ?? false
    }

    // MARK: Actions on elements

    /// Press the element through accessibility. Returns false when the role
    /// doesn't support it, so the caller falls back to a real mouse click.
    func press(_ id: Int) -> Bool {
        guard let element = registry[id], element.pressable else { return false }
        return AXUIElementPerformAction(element.handle, kAXPressAction as CFString) == .success
    }

    /// Give a text element keyboard focus through accessibility.
    func focus(_ id: Int) -> Bool {
        guard let element = registry[id], Self.textRoles.contains(element.role) else { return false }
        guard AXUIElementSetAttributeValue(element.handle, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            return false
        }
        return AX.bool(element.handle, kAXFocusedAttribute) == true
    }

    /// Choose an option in a pop-up menu: open it, then press the matching item.
    func select(_ id: Int, option: String) async -> String? {
        guard let element = registry[id] else { return nil }
        AXUIElementPerformAction(element.handle, kAXPressAction as CFString)
        try? await Task.sleep(nanoseconds: 350_000_000)
        var menus = (AX.elements(element.handle, kAXChildrenAttribute) ?? []).filter { AX.string($0, kAXRoleAttribute) == "AXMenu" }
        if menus.isEmpty, let app = target.application {
            menus = openMenus(AXUIElementCreateApplication(app.processIdentifier))
        }
        let wanted = option.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var best: (AXUIElement, String, Int)?
        for menu in menus {
            for item in AX.elements(menu, kAXChildrenAttribute) ?? [] {
                let title = (AX.string(item, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = title.lowercased()
                let score = lower == wanted ? 3 : lower.hasPrefix(wanted) ? 2 : lower.contains(wanted) && !wanted.isEmpty ? 1 : 0
                if score > (best?.2 ?? 0) { best = (item, title, score) }
            }
        }
        guard let (item, title, _) = best else {
            // Close the menu again so the screen isn't left in a modal state.
            if !menus.isEmpty { try? Input().press(combo: "escape") }
            return nil
        }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        return title
    }

    /// Option titles of a pop-up, for error messages.
    func options(of id: Int) -> [String] {
        guard let element = registry[id] else { return [] }
        let menus = (AX.elements(element.handle, kAXChildrenAttribute) ?? []).filter { AX.string($0, kAXRoleAttribute) == "AXMenu" }
        return menus.flatMap { AX.elements($0, kAXChildrenAttribute) ?? [] }.compactMap { AX.string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
    }

    /// Wait for a web page in the target window to stop loading.
    func waitForPageLoad(timeout: TimeInterval) async {
        guard let webArea = findWebArea() else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let busy = AX.bool(webArea, "AXElementBusy") ?? false
            let loaded = AX.bool(webArea, "AXLoaded") ?? true
            if !busy && loaded { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func findWebArea() -> AXUIElement? {
        guard let window = target.focusedWindow() else { return nil }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if AX.string(node, kAXRoleAttribute) == "AXWebArea" { return node }
            guard depth < 14 else { continue }
            for child in AX.elements(node, kAXChildrenAttribute) ?? [] { queue.append((child, depth + 1)) }
        }
        return nil
    }

    // MARK: Debugging

    func dumpTree(maxDepth: Int, maxNodes: Int) -> String {
        guard let window = target.focusedWindow() else { return "(no window)" }
        var lines: [String] = []
        func walk(_ node: AXUIElement, _ depth: Int) {
            guard depth <= maxDepth, lines.count < maxNodes else { return }
            let role = AX.string(node, kAXRoleAttribute) ?? "?"
            let subrole = AX.string(node, kAXSubroleAttribute).map { "/" + $0 } ?? ""
            let title = AX.string(node, kAXTitleAttribute) ?? ""
            let description = AX.string(node, kAXDescriptionAttribute) ?? ""
            let value = AX.string(node, kAXValueAttribute).map { String($0.prefix(40)) } ?? ""
            let frame = AX.frame(node).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
            let actions = AX.actions(node).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }.joined(separator: ",")
            lines.append(String(repeating: "  ", count: depth) + "\(role)\(subrole) t=\"\(title)\" d=\"\(description)\" v=\"\(value)\" [\(frame)] \(actions)")
            for child in AX.elements(node, kAXChildrenAttribute) ?? [] { walk(child, depth + 1) }
        }
        walk(window, 0)
        return lines.joined(separator: "\n")
    }
}
