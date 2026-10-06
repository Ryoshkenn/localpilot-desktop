import AppKit

/// Clicking anywhere that isn't a text input ends editing, like a browser.
/// SwiftUI on macOS otherwise keeps the caret in a field until another field
/// takes it.
@MainActor
enum FocusReleaser {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            releaseFocusIfNeeded(for: event)
            return event
        }
    }

    private static func releaseFocusIfNeeded(for event: NSEvent) {
        guard let window = event.window,
              window.firstResponder is NSText || window.firstResponder is NSTextField,
              let frameView = window.contentView?.superview else { return }
        let hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
        guard !isTextInput(hit) else { return }
        window.makeFirstResponder(nil)
    }

    private static func isTextInput(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is NSText || candidate is NSTextField { return true }
            current = candidate.superview
        }
        return false
    }
}
