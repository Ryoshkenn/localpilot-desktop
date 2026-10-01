import AppKit

/// A small click-through overlay that shows where the agent is about to act
/// and what it is doing, so the user can see the agent working (and know when
/// to press Esc in pi to stop it).
@MainActor
final class Indicator {
    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?
    private let ringSize: CGFloat = 34

    func update(visible: Bool, label: String?, point: CGPoint?) {
        hideTask?.cancel()
        guard visible else {
            window?.orderOut(nil)
            return
        }
        let window = self.window ?? makeWindow()
        self.window = window
        guard let content = window.contentView as? IndicatorView else { return }
        content.label = label ?? ""

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let size = CGSize(width: 320, height: ringSize + 26)
        let anchor = point ?? CGPoint(x: (NSScreen.main?.frame.midX ?? 400), y: 60)
        // Global top-left points to AppKit bottom-left coordinates.
        let origin = CGPoint(x: anchor.x - ringSize / 2, y: primaryHeight - anchor.y - ringSize / 2 - 26)
        window.setFrame(CGRect(origin: origin, size: size), display: true)
        content.needsDisplay = true
        window.orderFrontRegardless()

        hideTask = Task { [weak window] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            window?.orderOut(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = IndicatorView(ringSize: ringSize)
        return window
    }
}

private final class IndicatorView: NSView {
    var label = ""
    let ringSize: CGFloat

    init(ringSize: CGFloat) {
        self.ringSize = ringSize
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSRect(x: 2, y: bounds.height - ringSize + 2, width: ringSize - 4, height: ringSize - 4)
        NSColor.systemPurple.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: ring).fill()
        NSColor.systemPurple.setStroke()
        let path = NSBezierPath(ovalIn: ring)
        path.lineWidth = 3
        path.stroke()

        guard !label.isEmpty else { return }
        let text = ("LocalPilot: " + label) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let pill = NSRect(x: 0, y: 0, width: min(bounds.width, size.width + 14), height: 20)
        NSColor.systemPurple.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        text.draw(in: pill.insetBy(dx: 7, dy: 3), withAttributes: attributes)
    }
}
