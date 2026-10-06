import ApplicationServices
import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif

public protocol ActionExecutor: Sendable {
    func execute(_ action: StructuredAction) async -> String
    /// Re-arm the executor for a new run. A hard stop is sticky until this is
    /// called, so a stopped executor can never be revived by a late
    /// `setPaused(false)`.
    func prepareForRun(dryRun: Bool) async
    func stopImmediately() async
    func setPaused(_ paused: Bool) async
}

public protocol ComputerControlling: Sendable {
    func inputReady() async -> Bool
    func click(at point: CGPoint) async
    func doubleClick(at point: CGPoint) async
    func typeText(_ text: String) async
    /// Scroll by lines at `point` (global top-left coordinates), or at the
    /// pointer's current position when nil. Negative scrolls down.
    func scroll(deltaY: Int32, at point: CGPoint?) async
    func pressKey(named key: String) async
    func copySelection() async
    func pasteText(_ text: String) async
    func openURL(_ urlString: String) async -> Bool
    func runTerminalCommand(_ command: String) async -> String
    func browserAction(_ type: ActionType, value: String) async -> String
    func switchApp(named appName: String) async -> Bool
}

public extension ComputerControlling {
    func inputReady() async -> Bool { true }
    func browserAction(_ type: ActionType, value: String) async -> String { "Browser action failed: unsupported controller." }
}

public actor QuartzComputerController: ComputerControlling {
    /// Whether to show the LocalPilot pointer before each mouse gesture.
    private let showsPointer: Bool

    public init(showsPointer: Bool = true) {
        self.showsPointer = showsPointer
    }

    /// Glides the on-screen pointer to `point` and waits for it to arrive, so
    /// the user sees the target before the real event lands.
    private func showPointer(at point: CGPoint, gesture: PointerIndicator.Gesture) async {
        guard showsPointer else { return }
        let moved = await MainActor.run { () -> Bool in
            let indicator = PointerIndicator.shared
            let moved = indicator.location != point
            indicator.move(to: point, gesture: gesture)
            return moved
        }
        if moved {
            try? await Task.sleep(nanoseconds: UInt64(PointerIndicator.glideSeconds * 1_000_000_000))
        }
        if gesture != .scroll {
            await MainActor.run { PointerIndicator.shared.press() }
        }
    }

    public func inputReady() async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        await MainActor.run { _ = TargetAppTracker.shared.activateTarget() }
        return true
    }

    public func click(at point: CGPoint) async {
        await showPointer(at: point, gesture: .click)
        postMouse(.mouseMoved, at: point)
        postMouse(.leftMouseDown, at: point)
        postMouse(.leftMouseUp, at: point)
    }

    public func doubleClick(at point: CGPoint) async {
        await showPointer(at: point, gesture: .doubleClick)
        postMouse(.mouseMoved, at: point)
        postMouse(.leftMouseDown, at: point, clickState: 1)
        postMouse(.leftMouseUp, at: point, clickState: 1)
        postMouse(.leftMouseDown, at: point, clickState: 2)
        postMouse(.leftMouseUp, at: point, clickState: 2)
    }

    public func typeText(_ text: String) {
        for character in text {
            let utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                continue
            }
            utf16.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    public func scroll(deltaY: Int32, at point: CGPoint?) async {
        // Scroll events go to the window under the pointer, so move it over
        // the target first; otherwise the scroll lands wherever the user's
        // mouse happens to be.
        if let point {
            await showPointer(at: point, gesture: .scroll)
            CGWarpMouseCursorPosition(point)
            postMouse(.mouseMoved, at: point)
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ) else {
            return
        }
        if let point { event.location = point }
        event.post(tap: .cghidEventTap)
    }

    public func pressKey(named key: String) {
        guard let chord = KeyboardKeys.chord(for: key) else { return }
        postKey(chord.0, flags: chord.1)
    }

    public func copySelection() {
        postCommandKey(8)
    }

    public func pasteText(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        postCommandKey(9)
    }

    public func openURL(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return false
        }
        #if canImport(AppKit)
        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        #else
        return false
        #endif
    }

    /// Hard ceiling on a single terminal command so a hung process can never
    /// wedge the executor (and with it Stop/Pause responsiveness).
    static let terminalCommandTimeout: TimeInterval = 30
    static let terminalOutputLimit = 1_000

    public func runTerminalCommand(_ command: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes while the process runs. Reading only after
        // `waitUntilExit()` deadlocks once output exceeds the ~64KB pipe buffer.
        let output = BoundedOutputBuffer(limit: 64 * 1024)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        for pipe in [outputPipe, errorPipe] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    output.markEndOfStream()
                } else {
                    output.append(chunk)
                }
            }
        }
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let timedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finished = OnceFlag()
            process.terminationHandler = { _ in
                if finished.set() { continuation.resume(returning: false) }
            }
            do {
                try process.run()
            } catch {
                if finished.set() { continuation.resume(returning: false) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminalCommandTimeout) {
                guard process.isRunning else { return }
                process.terminate()
                if finished.set() { continuation.resume(returning: true) }
            }
        }

        guard process.processIdentifier != 0 else {
            return "failed to start: /bin/zsh could not be launched"
        }

        // Give the pipe handlers a brief window to deliver trailing output. We
        // never block on EOF: a backgrounded grandchild could hold the pipe open.
        for _ in 0..<20 where output.endedStreams < 2 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        for pipe in [outputPipe, errorPipe] {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        let bounded = String(output.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.terminalOutputLimit))
        if timedOut {
            return "failed: timed out after \(Int(Self.terminalCommandTimeout))s. \(bounded)"
        }
        if process.terminationStatus == 0 {
            return bounded.isEmpty ? "exit 0" : bounded
        }
        return "exit \(process.terminationStatus): \(bounded)"
    }

    public func browserAction(_ type: ActionType, value: String) async -> String {
        await BrowserController.perform(type, value: value)
    }

    public func switchApp(named appName: String) async -> Bool {
        #if canImport(AppKit)
        let normalized = appName.lowercased()
        let activated = await MainActor.run { () -> Bool? in
            guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { app in
                app.localizedName?.lowercased() == normalized ||
                    app.bundleIdentifier?.lowercased() == normalized
            }) else {
                return nil
            }
            return runningApp.activate(options: [.activateAllWindows])
        }
        if let activated {
            return activated
        }

        // Launch by name without a shell: the app name is model-supplied, so it
        // must never be interpolated into a command line.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
        #else
        return false
        #endif
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, clickState: Int64 = 1) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: clickState)
        event?.post(tap: .cghidEventTap)
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func postCommandKey(_ keyCode: CGKeyCode) {
        postKey(keyCode, flags: .maskCommand)
    }
}

/// Named keys the executor can press. Unknown names are rejected up front so a
/// key press never reports success without doing anything.
public enum KeyboardKeys {
    public static func chord(for key: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = key.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let code = keyCode(for: last) else { return nil }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: return nil
            }
        }
        return (code, flags)
    }

    public static func keyCode(for key: String) -> CGKeyCode? {
        let letters: [String: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]
        if let code = letters[key.lowercased()] { return code }
        return switch key.lowercased() {
        case "return", "enter": 36
        case "tab": 48
        case "space": 49
        case "delete", "backspace": 51
        case "escape", "esc": 53
        case "forwarddelete", "forward_delete": 117
        case "home": 115
        case "end": 119
        case "pageup", "page_up": 116
        case "pagedown", "page_down": 121
        case "left": 123
        case "right": 124
        case "down": 125
        case "up": 126
        default: nil
        }
    }
}

/// Accumulates process output from pipe callbacks on arbitrary threads.
private final class BoundedOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock {
            let room = limit - data.count
            if room > 0 { data.append(chunk.prefix(room)) }
        }
    }

    private var ended = 0

    func markEndOfStream() {
        lock.withLock { ended += 1 }
    }

    var endedStreams: Int {
        lock.withLock { ended }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

/// Thread-safe one-shot flag so a continuation is resumed exactly once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns true only for the first caller.
    func set() -> Bool {
        lock.withLock {
            defer { isSet = true }
            return !isSet
        }
    }
}

public actor LocalPilotActionExecutor: ActionExecutor {
    private let screenObserver: any ScreenObserving
    private let computerController: any ComputerControlling
    private let webClient: HTTPClient
    private var dryRun: Bool
    private var enabled = true
    private var paused = false

    public init(
        screenObserver: any ScreenObserving = LiveScreenObserver(),
        computerController: any ComputerControlling = QuartzComputerController(),
        webClient: HTTPClient = URLSessionHTTPClient(),
        dryRun: Bool = true
    ) {
        self.screenObserver = screenObserver
        self.computerController = computerController
        self.webClient = webClient
        self.dryRun = dryRun
    }

    public func execute(_ action: StructuredAction) async -> String {
        guard enabled else { return "Executor disabled." }
        guard !paused else { return "Executor paused." }

        let inputActions: Set<ActionType> = [.click, .doubleClick, .typeTextSafe, .pressKey, .scroll, .copy, .paste]
        if !dryRun, inputActions.contains(action.type), !(await computerController.inputReady()) {
            return "Input blocked: grant Accessibility permission to LocalPilot in System Settings."
        }
        switch action.type {
        case .screenshot:
            let area = ScreenshotArea(rawValue: action.targetText) ?? .window
            return area == .window
                ? "A screenshot of the front window is attached to the next observation."
                : "A screenshot of the whole screen is attached to the next observation."
        case .observe:
            let observation = await screenObserver.capture()
            return "Observed current screen: \(observation.summary)"
        case .wait:
            try? await Task.sleep(nanoseconds: 500_000_000)
            return "Wait completed."
        case .finish:
            return "Task marked finished."
        case .askUser:
            return "Asked user for input."
        case .webSearch:
            // Read-only network lookups; they never touch the screen, so they
            // run even in dry run.
            return await WebResearch.search(action.text ?? action.targetText, httpClient: webClient)
        case .readWebpage:
            return await WebResearch.readPage(action.text ?? action.targetText, httpClient: webClient)
        case .click:
            guard !dryRun else { return dryRunResult(for: action) }
            let point: CGPoint
            if let elementID = action.targetElementID {
                switch await screenObserver.interact(id: elementID, text: nil, doubleClick: false) {
                case .performed: return "Clicked \(action.targetText) using accessibility."
                case .fallback(let resolved): point = resolved
                case .unavailable: return "Click blocked: element \(elementID) not found or stale. Observe again."
                }
            } else {
                guard let coordinatePoint = action.point else { return "Click blocked: coordinates are missing." }
                point = coordinatePoint
            }
            await computerController.click(at: point)
            return "Clicked \(action.targetText) at \(Int(point.x)),\(Int(point.y))."
        case .doubleClick:
            guard !dryRun else { return dryRunResult(for: action) }
            let point: CGPoint
            if let elementID = action.targetElementID {
                switch await screenObserver.interact(id: elementID, text: nil, doubleClick: true) {
                case .performed: return "Double-clicked \(action.targetText)."
                case .fallback(let resolved): point = resolved
                case .unavailable: return "Double-click blocked: element \(elementID) not found or stale. Observe again."
                }
            } else {
                guard let coordinatePoint = action.point else { return "Double-click blocked: coordinates are missing." }
                point = coordinatePoint
            }
            await computerController.doubleClick(at: point)
            return "Double-clicked \(action.targetText) at \(Int(point.x)),\(Int(point.y))."
        case .typeTextSafe:
            guard !dryRun else { return dryRunResult(for: action) }
            guard let text = action.text, !text.isEmpty else { return "Typing blocked: text is missing." }
            // If an element id is given, focus the field by clicking its center
            // before typing; otherwise type into whatever is currently focused.
            if let elementID = action.targetElementID {
                switch await screenObserver.interact(id: elementID, text: text, doubleClick: false) {
                case .performed: return "Filled \(action.targetText) using accessibility."
                case .fallback(let point):
                    await computerController.click(at: point)
                    await computerController.pressKey(named: "cmd+a")
                    await computerController.typeText(text)
                    return "Typed safe text into \(action.targetText) at \(Int(point.x)),\(Int(point.y))."
                case .unavailable:
                    return "Typing blocked: element \(elementID) not found or stale. Observe again."
                }
            }
            if let point = action.point { await computerController.click(at: point) }
            await computerController.typeText(text)
            return "Typed safe text into \(action.targetText)."
        case .scroll:
            guard !dryRun else { return dryRunResult(for: action) }
            let delta = action.scrollDeltaY
            let elementID = action.targetElementID
            // Without a known window, fall back to wherever the pointer is.
            let target = await MainActor.run(body: { ScrollTargeting.target(elementID: elementID) })
            await computerController.scroll(deltaY: delta, at: target?.point)
            let direction = delta < 0 ? "down" : "up"
            return "Scrolled \(direction) \(abs(delta)) lines in \(target?.name ?? "the view under the pointer"). Observe to see what is now visible."
        case .pressKey:
            guard !dryRun else { return dryRunResult(for: action) }
            let key = (action.text ?? action.targetText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !key.isEmpty else { return "Key press blocked: key name is missing." }
            guard KeyboardKeys.chord(for: key) != nil else { return "Key press blocked: unsupported key \(key)." }
            await computerController.pressKey(named: key)
            return "Pressed \(key)."
        case .copy:
            guard !dryRun else { return dryRunResult(for: action) }
            await computerController.copySelection()
            return "Copied \(action.targetText)."
        case .paste:
            guard !dryRun else { return dryRunResult(for: action) }
            guard let text = action.text, !text.isEmpty else { return "Paste blocked: text is missing." }
            await computerController.pasteText(text)
            return "Pasted approved text into \(action.targetText)."
        case .openURL:
            guard !dryRun else { return dryRunResult(for: action) }
            let urlString = action.text ?? action.targetText
            guard await computerController.openURL(urlString) else { return "Open URL blocked or failed: \(urlString)." }
            return "Opened URL \(urlString)."
        case .runTerminalCommand:
            guard !dryRun else { return dryRunResult(for: action) }
            guard let command = action.command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Terminal command blocked: command is missing."
            }
            let output = await computerController.runTerminalCommand(command)
            return "Terminal command completed: \(output)"
        case .switchApp:
            guard !dryRun else { return dryRunResult(for: action) }
            let appName = action.text ?? action.targetText
            guard !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Switch app blocked: app name is missing."
            }
            guard await computerController.switchApp(named: appName) else { return "Switch app failed: \(appName)." }
            return "Switched to \(appName)."
        case .browserNewTab, .browserNavigate, .browserSwitchTab, .browserCloseTab:
            guard !dryRun else { return dryRunResult(for: action) }
            return await computerController.browserAction(action.type, value: action.text ?? action.targetText)
        case .typeTextSensitive:
            return "Sensitive typing is blocked by policy and executor."
        }
    }

    public func prepareForRun(dryRun: Bool) {
        self.dryRun = dryRun
        enabled = true
        paused = false
    }

    public func stopImmediately() {
        enabled = false
        paused = false
    }

    /// Pausing never re-enables a stopped executor; only `prepareForRun` can.
    public func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    private func dryRunResult(for action: StructuredAction) -> String {
        "Dry-run only: \(action.type.rawValue) was validated but no OS control was performed."
    }


}

public actor StubActionExecutor: ActionExecutor {
    private var enabled = true
    private var paused = false

    public init() {}

    public func execute(_ action: StructuredAction) async -> String {
        guard enabled else { return "Executor disabled." }
        guard !paused else { return "Executor paused." }

        switch action.type {
        case .observe:
            return "Observed current app shell state. Real screen capture is not enabled yet."
        case .wait:
            try? await Task.sleep(nanoseconds: 500_000_000)
            return "Wait completed."
        case .finish:
            return "Task marked finished."
        case .askUser:
            return "Asked user for input."
        default:
            return "Dry-run only: \(action.type.rawValue) was validated but no OS control was performed."
        }
    }

    public func prepareForRun(dryRun: Bool) {
        enabled = true
        paused = false
    }

    public func stopImmediately() {
        enabled = false
        paused = false
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
    }
}

private extension StructuredAction {
    var point: CGPoint? {
        guard let coordinates, coordinates.count >= 2 else { return nil }
        let x = coordinates[0]
        let y = coordinates[1]
        // Reject non-finite or negative coordinates: a NaN/Infinity would crash
        // when later converted to Int, and off-screen negatives indicate a
        // malformed action rather than a real target.
        guard x.isFinite, y.isFinite, x >= 0, y >= 0 else { return nil }
        return CGPoint(x: x, y: y)
    }

    var scrollDeltaY: Int32 {
        guard let coordinates, coordinates.count >= 2, coordinates[1].isFinite else { return -5 }
        // Clamp to Int32 range so a malformed huge value cannot trap on
        // conversion; Int32(_:) crashes on out-of-range Doubles.
        let raw = coordinates[1].rounded()
        if raw >= Double(Int32.max) { return Int32.max }
        if raw <= Double(Int32.min) { return Int32.min }
        return Int32(raw)
    }
}

/// Chrome's scripting dictionary controls tabs; page interactions use the same
/// accessibility tree as native apps. No page JavaScript permission is needed.
enum BrowserController {
    static func chromeTabs() async -> [BrowserTab] {
        let result = await run(operation: "list", value: "")
        return (try? JSONDecoder().decode([BrowserTab].self, from: Data(result.utf8))) ?? []
    }

    static func perform(_ type: ActionType, value: String) async -> String {
        await run(operation: type.rawValue, value: value)
    }

    // All model data travels as argv, never interpolated into executable code.
    static let script = #"""
    function run(argv) {
        const operation = argv[0], value = argv[1];
        const chrome = Application('com.google.Chrome');
        if (operation === 'list') {
            if (!chrome.running() || !chrome.windows.length) return '[]';
            const win = chrome.windows[0], active = win.activeTabIndex();
            return JSON.stringify(win.tabs().slice(0, 50).map((tab, i) => ({index:i+1, title:tab.title(), url:tab.url(), isActive:i+1===active})));
        }
        if (!['browser_new_tab','browser_navigate','browser_switch_tab','browser_close_tab'].includes(operation)) throw Error('Unsupported browser action');
        if ((operation === 'browser_navigate' || (operation === 'browser_new_tab' && value)) && !/^https?:\/\//i.test(value)) throw Error('Expected http(s) URL');
        chrome.activate();
        if (!chrome.windows.length) {
            if (operation !== 'browser_new_tab') throw Error('No Chrome window. Open a new tab first.');
            chrome.windows.push(chrome.Window());
            if (value) chrome.windows[0].activeTab.url = value;
            return 'Opened Chrome window.';
        }
        const win = chrome.windows[0];
        switch (operation) {
        case 'browser_new_tab':
            win.tabs.push(chrome.Tab({url:value || 'about:blank'}));
            win.activeTabIndex = win.tabs.length;
            break;
        case 'browser_navigate': {
            win.activeTab.url = value;
            // Wait (bounded) for the page to load so the next observation sees it.
            for (let i = 0; i < 30 && win.activeTab.loading(); i++) delay(0.2);
            return 'Navigated to ' + win.activeTab.url() + ' (' + win.activeTab.title() + ')' + (win.activeTab.loading() ? ', still loading' : '');
        }
        default:
            const index = Number(value);
            if (!Number.isInteger(index) || index < 1 || index > win.tabs.length) throw Error('Tab number is stale. Observe again.');
            if (operation === 'browser_switch_tab') win.activeTabIndex = index;
            else win.tabs[index - 1].close();
        }
        return 'Chrome action completed: ' + operation;
    }
    """#

    private static func run(operation: String, value: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, operation, value]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        let output = BoundedOutputBuffer(limit: 128 * 1024)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; output.markEndOfStream() }
            else { output.append(data) }
        }
        process.standardOutput = pipe
        process.standardError = pipe
        let timedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finished = OnceFlag()
            process.terminationHandler = { _ in
                if finished.set() { continuation.resume(returning: false) }
            }
            do { try process.run() }
            catch { if finished.set() { continuation.resume(returning: false) }; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                guard process.isRunning else { return }
                process.terminate()
                if finished.set() { continuation.resume(returning: true) }
            }
        }
        for _ in 0..<10 where output.endedStreams == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        pipe.fileHandleForReading.readabilityHandler = nil
        if timedOut { return "Browser action failed: Chrome timed out. Check Automation permission or use accessibility controls." }
        guard process.processIdentifier != 0, process.terminationStatus == 0 else {
            return "Browser action failed: \(output.text.prefix(400)). Check Automation permission for Google Chrome; accessibility controls are also available."
        }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
