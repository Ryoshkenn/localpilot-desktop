import AppKit
import ApplicationServices
import Darwin

/// Tracks which app the agent is working in.
///
/// The helper runs under a terminal, so "the frontmost app" is usually the
/// terminal the user typed into. The target is the app the agent last opened
/// or focused; until then it is the frontmost app that isn't one of the
/// helper's ancestor processes.
@MainActor
final class TargetApp {
    private var pinned: NSRunningApplication?
    private let excludedPIDs: Set<pid_t>

    init() {
        excludedPIDs = Self.ancestorPIDs()
    }

    var application: NSRunningApplication? {
        if let pinned, !pinned.isTerminated { return pinned }
        return Self.frontmostCandidate(excluding: excludedPIDs)
    }

    func set(_ app: NSRunningApplication) {
        pinned = app
    }

    func release() {
        pinned = nil
    }

    func isExcluded(_ app: NSRunningApplication) -> Bool {
        excludedPIDs.contains(app.processIdentifier)
    }

    /// Bring the target app and its main window to the front. Returns false
    /// when there is no target.
    @discardableResult
    func activate() -> Bool {
        guard let app = application else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = AX.element(element, kAXFocusedWindowAttribute) ?? AX.element(element, kAXMainWindowAttribute) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        app.activate()
        // Activation is asynchronous; give it a moment to land.
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return true
    }

    func focusedWindow() -> AXUIElement? {
        guard let app = application else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        return AX.element(element, kAXFocusedWindowAttribute) ?? AX.element(element, kAXMainWindowAttribute)
            ?? AX.elements(element, kAXWindowsAttribute)?.first
    }

    func focusedWindowFrame() -> CGRect? {
        focusedWindow().flatMap(AX.frame)
    }

    /// Wait until the target app has at least one window (after a launch).
    func waitForWindow(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if focusedWindow() != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Discovery

    /// The frontmost regular app that isn't excluded, using on-screen window
    /// order to look past the terminal.
    private static func frontmostCandidate(excluding excluded: Set<pid_t>) -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           !excluded.contains(front.processIdentifier), front.activationPolicy == .regular {
            return front
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID, !excluded.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            return app
        }
        return nil
    }

    /// The helper's parent chain (shell, pi, terminal app...). These are never
    /// targets: the agent must not type into its own terminal.
    private static func ancestorPIDs() -> Set<pid_t> {
        var result: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]
        var pid = getppid()
        var guardCount = 0
        while pid > 1, guardCount < 64 {
            result.insert(pid)
            // Include the app that owns this process (e.g. an Electron
            // terminal's helper processes belong to the main app bundle).
            if let app = NSRunningApplication(processIdentifier: pid) { result.insert(app.processIdentifier) }
            pid = parentPID(of: pid)
            guardCount += 1
        }
        return result
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}

/// Thin wrappers over the AX C API.
enum AX {
    static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &ref) == .success else { return nil }
        if let string = ref as? String { return string }
        if let attributed = ref as? NSAttributedString { return attributed.string }
        return nil
    }

    static func bool(_ node: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    static func number(_ node: AXUIElement, _ attribute: String) -> Double? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.doubleValue
    }

    static func url(_ node: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &ref) == .success, let ref else { return nil }
        if let url = ref as? URL { return url.absoluteString }
        if CFGetTypeID(ref) == CFURLGetTypeID() { return (ref as! CFURL as URL).absoluteString }
        return ref as? String
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

    static func actions(_ node: AXUIElement) -> [String] {
        var ref: CFArray?
        guard AXUIElementCopyActionNames(node, &ref) == .success, let ref else { return [] }
        return (ref as? [String]) ?? []
    }

    static func frame(_ node: AXUIElement) -> CGRect? {
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
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
