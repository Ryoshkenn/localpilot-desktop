import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A single actionable accessibility element captured during one observation.
///
/// `id` is a traversal-order index that is stable *within one observation*: it
/// lets the planner say "click element 3". The live element handle behind each
/// id is kept in `AXElementRegistry`, so the executor can press or fill that
/// exact element. Coordinates are global display points (top-left origin).
public struct AXElementSnapshot: Codable, Equatable, Sendable {
    public let id: Int
    public let role: String     // e.g. Button, TextField (AX prefix stripped)
    public let label: String    // best of title/description/placeholder, trimmed
    public let centerX: Double
    public let centerY: Double
    public let width: Double
    public let height: Double
    /// Current contents of an editable field, or on/off state of a toggle.
    public let value: String?

    public init(
        id: Int,
        role: String,
        label: String,
        centerX: Double,
        centerY: Double,
        width: Double,
        height: Double,
        value: String? = nil
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.value = value
    }
}

/// One tab of a browser window.
public struct BrowserTab: Codable, Equatable, Sendable {
    public let index: Int
    public let title: String
    public let url: String
    public let isActive: Bool

    public init(index: Int, title: String, url: String, isActive: Bool) {
        self.index = index
        self.title = title
        self.url = url
        self.isActive = isActive
    }
}

/// What a screenshot shows: the target app's front window, or the whole
/// main display.
public enum ScreenshotArea: String, Codable, Sendable {
    case window
    case screen
}

/// A downscaled picture of the screen or one window, for vision-capable models.
public struct ScreenshotAttachment: Codable, Equatable, Sendable {
    public let jpegBase64: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Size of the captured area in points, for mapping model coordinates back.
    public let pointWidth: Double
    public let pointHeight: Double
    /// Global position (top-left origin, points) of the captured area's
    /// top-left corner; zero for a full-display capture.
    public let originX: Double
    public let originY: Double
    public let area: ScreenshotArea

    public init(jpegBase64: String, pixelWidth: Int, pixelHeight: Int, pointWidth: Double, pointHeight: Double, originX: Double = 0, originY: Double = 0, area: ScreenshotArea = .screen) {
        self.jpegBase64 = jpegBase64
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.originX = originX
        self.originY = originY
        self.area = area
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jpegBase64 = try container.decode(String.self, forKey: .jpegBase64)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        pointWidth = try container.decode(Double.self, forKey: .pointWidth)
        pointHeight = try container.decode(Double.self, forKey: .pointHeight)
        originX = try container.decodeIfPresent(Double.self, forKey: .originX) ?? 0
        originY = try container.decodeIfPresent(Double.self, forKey: .originY) ?? 0
        area = try container.decodeIfPresent(ScreenshotArea.self, forKey: .area) ?? .screen
    }

    /// Models give screenshot positions on a 0–1000 scale in each direction,
    /// whatever the image's pixel size: (0,0) is the top-left corner and
    /// (1000,1000) the bottom-right. Qwen-VL-family models locate things
    /// this way natively, so it is also what they're most accurate at.
    public static let coordinateScale = 1000.0

    /// Whether a model coordinate pair is on the 0–1000 scale.
    public static func isOnScale(_ point: [Double]) -> Bool {
        point.count >= 2 && point.prefix(2).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= coordinateScale }
    }

    /// Convert a 0–1000 screenshot position to global display points.
    public func toScreenPoints(_ position: [Double]) -> [Double] {
        guard position.count >= 2 else { return position }
        return [
            originX + position[0] / Self.coordinateScale * pointWidth,
            originY + position[1] / Self.coordinateScale * pointHeight,
        ]
    }
}

public struct ScreenObservation: Codable, Equatable, Sendable {
    public let activeApp: String?
    public let activeWindow: String?
    public let screenshotWidth: Int?
    public let screenshotHeight: Int?
    public let screenshotPNGBase64: String?
    public let accessibilitySummary: String?
    public let elements: [AXElementSnapshot]
    public let browserTabs: [BrowserTab]

    public init(
        activeApp: String?,
        activeWindow: String?,
        screenshotWidth: Int?,
        screenshotHeight: Int?,
        screenshotPNGBase64: String?,
        accessibilitySummary: String?,
        elements: [AXElementSnapshot] = [],
        browserTabs: [BrowserTab] = []
    ) {
        self.activeApp = activeApp
        self.activeWindow = activeWindow
        self.screenshotWidth = screenshotWidth
        self.screenshotHeight = screenshotHeight
        self.screenshotPNGBase64 = screenshotPNGBase64
        self.accessibilitySummary = accessibilitySummary
        self.elements = elements
        self.browserTabs = browserTabs
    }

    public var summary: String {
        var parts: [String] = []
        parts.append("active_app=\(activeApp ?? "unknown")")
        parts.append("active_window=\(activeWindow ?? "unknown")")

        if let screenshotWidth, let screenshotHeight {
            let screenshotState = screenshotPNGBase64 == nil ? "screenshot unavailable" : "screenshot captured"
            parts.append("screen=\(screenshotWidth)x\(screenshotHeight) \(screenshotState)")
        } else {
            parts.append("screen=unknown screenshot unavailable")
        }

        if let accessibilitySummary, !accessibilitySummary.isEmpty {
            parts.append(accessibilitySummary)
        }

        if !browserTabs.isEmpty {
            parts.append(Self.tabsSummary(browserTabs))
        }

        if !elements.isEmpty {
            parts.append(Self.elementsSummary(elements))
        }

        return parts.joined(separator: "; ")
    }

    /// Just where the agent is: app, window and Chrome tabs, without the
    /// element list. Sent alongside a screenshot, which shows the rest.
    public var briefSummary: String {
        var parts = ["active_app=\(activeApp ?? "unknown")", "active_window=\(activeWindow ?? "unknown")"]
        if !browserTabs.isEmpty { parts.append(Self.tabsSummary(browserTabs)) }
        return parts.joined(separator: "; ")
    }

    /// Capped rendering of the elements, e.g.
    /// `elements: [0] button "Save", [1] textfield "Email" = "a@b.c"`.
    static let maxSummarizedElements = 60
    private static let maxLabel = 50

    private static func elementsSummary(_ elements: [AXElementSnapshot]) -> String {
        let rendered = elements.prefix(maxSummarizedElements).map { element -> String in
            var line = "[\(element.id)] \(element.role.lowercased()) \"\(truncate(element.label, maxLabel))\""
            if let value = element.value {
                line += " = \"\(truncate(value, 40))\""
            }
            return line
        }
        var summary = "elements: " + rendered.joined(separator: ", ")
        if elements.count > maxSummarizedElements {
            summary += " (+\(elements.count - maxSummarizedElements) more)"
        }
        return summary
    }

    private static func tabsSummary(_ tabs: [BrowserTab]) -> String {
        "browser tabs: " + tabs.map { tab in
            "[\(tab.index)]\(tab.isActive ? " (active)" : "") \"\(truncate(tab.title, 40))\" \(truncate(tab.url, 60))"
        }.joined(separator: ", ")
    }

    private static func truncate(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private enum CodingKeys: String, CodingKey {
        case activeApp
        case activeWindow
        case screenshotWidth
        case screenshotHeight
        case screenshotPNGBase64
        case accessibilitySummary
        case elements
        case browserTabs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.activeApp = try container.decodeIfPresent(String.self, forKey: .activeApp)
        self.activeWindow = try container.decodeIfPresent(String.self, forKey: .activeWindow)
        self.screenshotWidth = try container.decodeIfPresent(Int.self, forKey: .screenshotWidth)
        self.screenshotHeight = try container.decodeIfPresent(Int.self, forKey: .screenshotHeight)
        self.screenshotPNGBase64 = try container.decodeIfPresent(String.self, forKey: .screenshotPNGBase64)
        self.accessibilitySummary = try container.decodeIfPresent(String.self, forKey: .accessibilitySummary)
        self.elements = try container.decodeIfPresent([AXElementSnapshot].self, forKey: .elements) ?? []
        self.browserTabs = try container.decodeIfPresent([BrowserTab].self, forKey: .browserTabs) ?? []
    }
}

public enum ElementInteraction: Sendable {
    case performed
    case fallback(CGPoint)
    case unavailable
}

public protocol ScreenObserving: Sendable {
    @MainActor func interact(id: Int, text: String?, doubleClick: Bool) async -> ElementInteraction
    @MainActor func capture() async -> ScreenObservation
    /// A downscaled picture of the main display, or nil when unavailable.
    @MainActor func captureScreenshot(maxWidth: Int) async -> ScreenshotAttachment?
    /// A picture of the target app's front window or the whole display.
    @MainActor func captureScreenshot(maxWidth: Int, area: ScreenshotArea) async -> ScreenshotAttachment?
}

public extension ScreenObserving {
    @MainActor func interact(id: Int, text: String?, doubleClick: Bool) async -> ElementInteraction {
        let observation = await capture()
        guard let element = observation.elements.first(where: { $0.id == id }) else { return .unavailable }
        return .fallback(CGPoint(x: element.centerX, y: element.centerY))
    }
    @MainActor func captureScreenshot(maxWidth: Int) async -> ScreenshotAttachment? { nil }
    @MainActor func captureScreenshot(maxWidth: Int, area: ScreenshotArea) async -> ScreenshotAttachment? {
        await captureScreenshot(maxWidth: maxWidth)
    }
}

// MARK: - Target app

/// The app the agent works in. When LocalPilot itself is frontmost (the user
/// just typed a request into it) this is the app the user was in before.
@MainActor
public final class TargetAppTracker {
    public static let shared = TargetAppTracker()

    private var lastExternalPID: pid_t?
    private var observer: NSObjectProtocol?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private init() {
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ownPID {
            lastExternalPID = frontmost.processIdentifier
        }
        let ownPID = ownPID
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier, pid != ownPID else { return }
            MainActor.assumeIsolated { self?.lastExternalPID = pid }
        }
    }

    public var targetApplication: NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ownPID {
            return frontmost
        }
        guard let pid = lastExternalPID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return nil
        }
        return app
    }

    /// Bring the target app forward so input lands there, not in LocalPilot.
    @discardableResult
    public func activateTarget() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID,
              let target = targetApplication else {
            return false
        }
        return target.activate()
    }
}

// MARK: - Element registry

/// Live AX handles for the elements in the latest planning observation, keyed
/// by the ids the planner saw. Handles stay valid while the element exists, so
/// an id resolves to the right element even if the tree reorders.
@MainActor
public final class AXElementRegistry {
    public static let shared = AXElementRegistry()

    private var handles: [Int: AXUIElement] = [:]
    private var frames: [Int: CGRect] = [:]

    func replace(handles: [Int: AXUIElement], frames: [Int: CGRect]) {
        self.handles = handles
        self.frames = frames
    }

    func handle(for id: Int) -> AXUIElement? { handles[id] }
    func frame(for id: Int) -> CGRect? { frames[id] }
}

// MARK: - Scroll targeting

/// Where a scroll should land: inside an observed element, or the middle of
/// the target app's focused window.
@MainActor
public enum ScrollTargeting {
    public struct Target: Sendable {
        public let point: CGPoint
        public let name: String
    }

    public static func target(elementID: Int?) -> Target? {
        let app = TargetAppTracker.shared.targetApplication
        TargetAppTracker.shared.activateTarget()
        if let elementID, let frame = AXElementRegistry.shared.frame(for: elementID) {
            return Target(point: CGPoint(x: frame.midX, y: frame.midY), name: "element \(elementID)")
        }
        guard let app, AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = LiveScreenObserver.element(appElement, kAXFocusedWindowAttribute),
              let frame = LiveScreenObserver.frame(of: window) else { return nil }
        // Aim below the title bar and toolbars, where page content usually is.
        let point = CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.6)
        return Target(point: point, name: app.localizedName ?? "the front window")
    }
}

// MARK: - Live observer

public struct LiveScreenObserver: ScreenObserving {
    public init(includeScreenshot: Bool = false) {}

    @MainActor
    public func interact(id: Int, text: String?, doubleClick: Bool) async -> ElementInteraction {
        guard AXIsProcessTrusted(), let handle = AXElementRegistry.shared.handle(for: id),
              let frame = Self.frame(of: handle), Self.bool(handle, kAXEnabledAttribute) != false else { return .unavailable }
        var pid: pid_t = 0
        guard AXUIElementGetPid(handle, &pid) == .success,
              TargetAppTracker.shared.targetApplication?.processIdentifier == pid else { return .unavailable }
        TargetAppTracker.shared.activateTarget()
        if let text {
            AXUIElementSetAttributeValue(handle, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if AXUIElementSetAttributeValue(handle, kAXValueAttribute as CFString, text as CFString) == .success { return .performed }
        } else if !doubleClick, AXUIElementPerformAction(handle, kAXPressAction as CFString) == .success {
            return .performed
        }
        return .fallback(CGPoint(x: frame.midX, y: frame.midY))
    }

    @MainActor
    public func capture() async -> ScreenObservation {
        let target = TargetAppTracker.shared.targetApplication
        let activeApp = target?.localizedName
        let display = CGMainDisplayID()

        AXElementRegistry.shared.replace(handles: [:], frames: [:])
        var summary: String?
        var elements: [AXElementSnapshot] = []
        if !AXIsProcessTrusted() {
            summary = "AX: accessibility permission not granted"
        } else if let target {
            let appElement = AXUIElementCreateApplication(target.processIdentifier)
            if Self.isChromium(target) {
                // Chromium only builds its web accessibility tree for clients
                // that ask; without this, page content is invisible to AX.
                AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            let collected = Self.collectElements(appElement: appElement)
            elements = collected.snapshots
            AXElementRegistry.shared.replace(handles: collected.handles, frames: collected.frames)
            summary = collected.visibleText.isEmpty ? nil : "Visible text: " + collected.visibleText.joined(separator: " | ")
            if elements.isEmpty { summary = (summary ?? "") + " AX: no actionable elements found" }
        }

        let tabs = target?.bundleIdentifier == "com.google.Chrome" ? await BrowserController.chromeTabs() : []

        return ScreenObservation(
            activeApp: activeApp,
            activeWindow: target.flatMap(Self.focusedWindowTitle),
            screenshotWidth: CGDisplayPixelsWide(display),
            screenshotHeight: CGDisplayPixelsHigh(display),
            screenshotPNGBase64: nil,
            accessibilitySummary: summary,
            elements: elements,
            browserTabs: tabs
        )
    }

    @MainActor
    public func captureScreenshot(maxWidth: Int) async -> ScreenshotAttachment? {
        await ScreenshotCapturer.capture(maxWidth: maxWidth)
    }

    @MainActor
    public func captureScreenshot(maxWidth: Int, area: ScreenshotArea) async -> ScreenshotAttachment? {
        switch area {
        case .screen:
            return await ScreenshotCapturer.capture(maxWidth: maxWidth)
        case .window:
            // Fall back to the whole display when there's no window to capture.
            if let window = await ScreenshotCapturer.captureFrontWindow(maxWidth: maxWidth) { return window }
            return await ScreenshotCapturer.capture(maxWidth: maxWidth)
        }
    }

    static func isChromium(_ app: NSRunningApplication) -> Bool {
        let chromiumIDs: Set<String> = [
            "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
            "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        ]
        return app.bundleIdentifier.map(chromiumIDs.contains) ?? false
    }

    private static func focusedWindowTitle(for app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(appElement, kAXFocusedWindowAttribute) else { return nil }
        return string(window, kAXTitleAttribute)
    }

    /// Roles worth offering to the planner as click or type targets.
    private static let actionableRoles: Set<String> = [
        kAXButtonRole as String, "AXLink", kAXTextFieldRole as String, kAXTextAreaRole as String,
        kAXMenuItemRole as String, kAXCheckBoxRole as String, kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String, kAXComboBoxRole as String, "AXMenuButton", kAXSliderRole as String,
        kAXDisclosureTriangleRole as String, "AXTab", "AXSearchField", kAXMenuBarItemRole as String,
    ]

    private static let maxElements = 160
    private static let maxDepth = 40
    /// Bounds the walk on huge trees (long web pages) so observation stays fast.
    private static let maxVisitedNodes = 4_000

    private struct Collected {
        var snapshots: [AXElementSnapshot] = []
        var handles: [Int: AXUIElement] = [:]
        var frames: [Int: CGRect] = [:]
        var visited = 0
        var visibleText: [String] = []
        var textCount = 0
    }

    private static func collectElements(appElement: AXUIElement) -> Collected {
        var collected = Collected()
        let window = element(appElement, kAXFocusedWindowAttribute)
        let root = window ?? appElement
        // Screen bounds in global top-left coordinates; off-screen elements are skipped.
        var screenBounds = NSScreen.screens.reduce(CGRect.null) { bounds, screen in
            let frame = screen.frame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
            return bounds.union(CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height))
        }
        // Web pages report frames for content scrolled out of view. Keep only
        // what is inside the window, so every listed element is really
        // clickable and the model knows to scroll for the rest.
        if let window, let windowFrame = frame(of: window) {
            let visible = screenBounds.isNull ? windowFrame : screenBounds.intersection(windowFrame)
            if !visible.isNull, visible.width > 0 { screenBounds = visible }
        }
        walk(root, depth: 0, screenBounds: screenBounds, into: &collected)
        return collected
    }

    private static func walk(_ node: AXUIElement, depth: Int, screenBounds: CGRect, into collected: inout Collected) {
        guard depth <= maxDepth, collected.snapshots.count < maxElements, collected.visited < maxVisitedNodes else { return }
        collected.visited += 1

        let rawRole = string(node, kAXRoleAttribute) ?? ""
        if rawRole == "AXStaticText", collected.textCount < 6000,
           let frame = frame(of: node), screenBounds.intersects(frame),
           let text = string(node, kAXValueAttribute), !text.isEmpty {
            let bounded = String(text.prefix(6000 - collected.textCount))
            collected.visibleText.append(bounded)
            collected.textCount += bounded.count
        }
        let subrole = string(node, kAXSubroleAttribute)
        let role = subrole == "AXSearchField" ? "AXSearchField" : rawRole
        if actionableRoles.contains(role), let frame = frame(of: node), frame.width > 1, frame.height > 1,
           screenBounds.isNull || screenBounds.intersects(frame),
           bool(node, kAXEnabledAttribute) != false {
            let id = collected.snapshots.count
            collected.snapshots.append(AXElementSnapshot(
                id: id,
                role: role.hasPrefix("AX") ? String(role.dropFirst(2)) : role,
                label: label(of: node),
                centerX: Double(frame.midX),
                centerY: Double(frame.midY),
                width: Double(frame.width),
                height: Double(frame.height),
                value: value(of: node, role: role)
            ))
            collected.handles[id] = node
            collected.frames[id] = frame
        }

        guard let children = elements(node, kAXChildrenAttribute) else { return }
        for child in children {
            if collected.snapshots.count >= maxElements || collected.visited >= maxVisitedNodes { return }
            walk(child, depth: depth + 1, screenBounds: screenBounds, into: &collected)
        }
    }

    private static func label(of node: AXUIElement) -> String {
        let candidates = [
            string(node, kAXTitleAttribute),
            string(node, kAXDescriptionAttribute),
            string(node, kAXPlaceholderValueAttribute),
            element(node, kAXTitleUIElementAttribute).flatMap { string($0, kAXValueAttribute) },
            string(node, kAXHelpAttribute),
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        // Buttons without a title often expose their text as the value.
        return string(node, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func value(of node: AXUIElement, role: String) -> String? {
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            return string(node, kAXValueAttribute) ?? ""
        case "AXCheckBox", "AXRadioButton":
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &ref) == .success,
                  let number = ref as? NSNumber else { return nil }
            return number.intValue == 0 ? "off" : "on"
        default:
            return nil
        }
    }

    // MARK: AX helpers

    static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    static func bool(_ node: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    static func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    static func elements(_ node: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }

    static func frame(of node: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(node, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }
}

// MARK: - Screenshots

enum ScreenshotCapturer {
    /// Capture the main display with ScreenCaptureKit, leaving out LocalPilot's
    /// own windows (the Agent Mode haze and HUD), downscaled to `maxWidth`.
    @MainActor
    static func capture(maxWidth: Int) async -> ScreenshotAttachment? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                return nil
            }
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let scale = min(1, Double(maxWidth) / Double(display.width))
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(Double(display.width) * scale))
            configuration.height = max(1, Int(Double(display.height) * scale))
            configuration.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
            return ScreenshotAttachment(
                jpegBase64: jpeg.base64EncodedString(),
                pixelWidth: image.width,
                pixelHeight: image.height,
                pointWidth: Double(CGDisplayBounds(display.displayID).width),
                pointHeight: Double(CGDisplayBounds(display.displayID).height)
            )
        } catch {
            return nil
        }
    }

    /// Capture just the target app's frontmost window, at up to 2x its point
    /// size and no wider than `maxWidth`. Coordinates in the image map back
    /// through the window's global origin.
    @MainActor
    static func captureFrontWindow(maxWidth: Int) async -> ScreenshotAttachment? {
        guard CGPreflightScreenCaptureAccess(),
              let app = TargetAppTracker.shared.targetApplication,
              let windowID = frontWindowID(of: app.processIdentifier) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let frame = window.frame
            guard frame.width >= 1, frame.height >= 1 else { return nil }
            let pixelWidth = min(Double(maxWidth), frame.width * 2)
            let scale = pixelWidth / frame.width
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(frame.width * scale))
            configuration.height = max(1, Int(frame.height * scale))
            configuration.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
            return ScreenshotAttachment(
                jpegBase64: jpeg.base64EncodedString(),
                pixelWidth: image.width,
                pixelHeight: image.height,
                pointWidth: frame.width,
                pointHeight: frame.height,
                originX: frame.minX,
                originY: frame.minY,
                area: .window
            )
        } catch {
            return nil
        }
    }

    /// The app's frontmost normal window. The window list is ordered front
    /// to back.
    private static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) > 80, (bounds["Height"] ?? 0) > 80,
                  let number = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            return number
        }
        return nil
    }
}

// MARK: - Context

public struct AgentContextBuilder: Sendable {
    private let screenObserver: any ScreenObserving

    /// Upper bound on how many trailing chat messages the legacy builder keeps.
    private static let maxMessageTail = 6
    /// Screenshot width sent to vision models; enough to read UI text.
    public static let screenshotWidth = 1280

    public init(screenObserver: any ScreenObserving = LiveScreenObserver()) {
        self.screenObserver = screenObserver
    }

    /// Legacy builder kept for message-oriented call sites and tests.
    @MainActor
    public func makeContext(settings: AppSettings, messages: [ChatMessage]) async -> AgentContext {
        let observation = await screenObserver.capture()
        let tail = messages.suffix(Self.maxMessageTail).map(\.text)
        let visibleText = (tail + [observation.summary]).joined(separator: "\n")
        return context(from: observation, settings: settings, visibleText: visibleText)
    }

    /// Builds the loop's context from the task, the history, and only the latest
    /// observation. A screenshot is attached when `wantsScreenshot` is set, or
    /// when accessibility offers nothing to act on.
    @MainActor
    public func makeContext(settings: AppSettings, task: String, history: AgentHistory, wantsScreenshot: Bool = false) async -> AgentContext {
        await makeContext(settings: settings, task: task, history: history, screenshot: wantsScreenshot ? .screen : nil)
    }

    /// As above, with a choice of what the screenshot shows. When `visual`
    /// is set and the screenshot succeeds, the text part is only a brief
    /// "where am I" line; the picture replaces the element list. Without a
    /// picture (e.g. no Screen Recording permission) the full text is kept.
    @MainActor
    public func makeContext(settings: AppSettings, task: String, history: AgentHistory, screenshot area: ScreenshotArea?, visual: Bool = false) async -> AgentContext {
        let observation = await screenObserver.capture()
        if visual, let area, let shot = await screenObserver.captureScreenshot(maxWidth: Self.screenshotWidth, area: area) {
            var parts: [String] = ["Task: \(task)"]
            if !history.compactedSummary.isEmpty { parts.append(history.compactedSummary) }
            if !history.recentSteps.isEmpty { parts.append("Recent steps:\n" + history.recentSteps.joined(separator: "\n")) }
            parts.append("Where you are: \(observation.briefSummary)")
            parts.append(shot.area == .window ? "Attached: a screenshot of the front window." : "Attached: a screenshot of the whole screen.")
            var context = context(from: observation, settings: settings, visibleText: parts.joined(separator: "\n"))
            context.screenshot = shot
            return context
        }

        var parts: [String] = ["Task: \(task)"]
        if !history.compactedSummary.isEmpty {
            parts.append(history.compactedSummary)
        }
        if !history.recentSteps.isEmpty {
            parts.append("Recent steps:\n" + history.recentSteps.joined(separator: "\n"))
        }
        parts.append("Latest observation: \(observation.summary)")

        var context = context(from: observation, settings: settings, visibleText: parts.joined(separator: "\n"))
        if let area {
            context.screenshot = await screenObserver.captureScreenshot(maxWidth: Self.screenshotWidth, area: area)
        } else if observation.elements.isEmpty {
            context.screenshot = await screenObserver.captureScreenshot(maxWidth: Self.screenshotWidth)
        }
        if area != nil || observation.elements.isEmpty {
            if let shot = context.screenshot {
                context.visibleText += shot.area == .window
                    ? "\nAttached: a screenshot of the front window."
                    : "\nAttached: a screenshot of the whole screen."
            } else {
                context.visibleText += "\nScreenshot unavailable; check Screen Recording permission. Do not invent screen targets."
            }
        }
        return context
    }

    /// A screenshot on demand, for observe's screenshot mode.
    @MainActor
    public func captureScreenshot(area: ScreenshotArea) async -> ScreenshotAttachment? {
        await screenObserver.captureScreenshot(maxWidth: Self.screenshotWidth, area: area)
    }

    private func context(from observation: ScreenObservation, settings: AppSettings, visibleText: String) -> AgentContext {
        AgentContext(
            activeApp: observation.activeApp,
            activeWindow: observation.activeWindow,
            currentDomain: observation.browserTabs.first(where: \.isActive).flatMap { URL(string: $0.url)?.host() },
            // The "allowed without asking" lists were removed from Settings;
            // stale saved values must not silently widen policy.
            allowedDomains: [],
            allowedApps: [],
            allowedFolders: [],
            visibleText: visibleText,
            activeFieldKind: nil,
            elements: observation.elements
        )
    }
}
