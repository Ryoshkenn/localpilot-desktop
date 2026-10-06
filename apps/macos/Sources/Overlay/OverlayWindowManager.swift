import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the two Agent Mode windows:
///
/// - a full-screen **haze** that is purely visual and ignores the mouse, so the
///   executor's synthetic clicks land on the app underneath instead of on
///   LocalPilot's own window;
/// - a tall floating **HUD** panel in the top-right corner showing the
///   current step, with Pause/Continue/Stop and inline approvals. It is non-activating, so using it never steals focus from the
///   app the agent is working in.
///
/// If the chat window is open when Agent Mode starts, it shrinks into the
/// panel's shape in the top-right corner and grows back out when the run
/// ends, so the panel reads as the same window, minimized.
///
/// It also hands keyboard focus back to the app the user was in when Agent
/// Mode starts (so observations and keystrokes target that app, not
/// LocalPilot) and brings LocalPilot back when the run ends.
@MainActor
final class OverlayWindowManager {
    static let shared = OverlayWindowManager()

    private var hazeWindow: NSWindow?
    private var hudPanel: NSPanel?
    private var isShowing = false
    /// The run ended while another app was in front; the panel stays up with
    /// the result and a Back to chat button.
    private var showsFinishedRun = false
    /// The most recently active app that is not LocalPilot.
    private var lastExternalAppPID: pid_t?
    private let stopHotKey = GlobalStopHotKey()
    /// The chat window while it's minimized into the panel, and where it was.
    private var minimizedWindow: (window: NSWindow, frame: NSRect)?
    /// Borderless window that carries a snapshot during the morph.
    private var morphWindow: NSWindow?
    private static let morphDuration = 0.34
    /// Transparent margin around the HUD card, for its shadow.
    private static let hudShadowInset: CGFloat = 24

    private init() {}

    func configure(controller: AgentController) {
        guard hazeWindow == nil else { return }
        hazeWindow = makeHazeWindow(controller: controller)
        hudPanel = makeHUDPanel(controller: controller)
        trackExternalApps()
        // Returning to LocalPilot any other way also dismisses a finished run's panel.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissFinishedRun() }
        }
        stopHotKey.register { [weak controller] in
            controller?.stop()
        }
    }

    /// Show or hide Agent Mode to match the controller's overlay state.
    func sync(with controller: AgentController) {
        configure(controller: controller)
        let shouldShow = controller.overlayState != .idle
        guard shouldShow != isShowing else { return }
        isShowing = shouldShow

        if shouldShow {
            showsFinishedRun = false
            show()
            handFocusToExternalApp()
        } else if minimizedWindow != nil {
            hazeWindow?.orderOut(nil)
            restoreChatWindow()
        } else {
            hazeWindow?.orderOut(nil)
            if NSApp.isActive {
                hudPanel?.orderOut(nil)
            } else {
                // Leave the panel up so the user can read the outcome.
                showsFinishedRun = true
            }
        }
    }

    /// "Back to chat": close the panel and bring LocalPilot forward.
    func backToChat() {
        showsFinishedRun = false
        hudPanel?.orderOut(nil)
        NSApp.unhide(nil)
        NSApp.activate()
    }

    private func dismissFinishedRun() {
        guard showsFinishedRun else { return }
        showsFinishedRun = false
        hudPanel?.orderOut(nil)
    }

    private func show() {
        let screen = Self.primaryScreen
        hazeWindow?.setFrame(screen.frame, display: true)
        hazeWindow?.orderFrontRegardless()
        guard let hudPanel else { return }
        positionHUD(hudPanel, size: hudPanel.frame.size, on: screen)
        if let chat = visibleChatWindow() {
            minimizeChatWindow(chat, into: hudPanel)
        } else {
            hudPanel.alphaValue = 1
            hudPanel.orderFrontRegardless()
        }
    }

    // MARK: Morph

    private func visibleChatWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && !window.isMiniaturized && !(window is NSPanel)
                && window !== hazeWindow && window !== morphWindow
                && window.styleMask.contains(.titled) && window.canBecomeMain
        }
    }

    private func cardFrame(of panel: NSPanel) -> NSRect {
        panel.frame.insetBy(dx: Self.hudShadowInset, dy: Self.hudShadowInset)
    }

    /// Shrinks a snapshot of the chat window into the panel's card while the
    /// panel fades in on top of it.
    private func minimizeChatWindow(_ chat: NSWindow, into panel: NSPanel) {
        minimizedWindow = (chat, chat.frame)
        let morph = makeMorphWindow(image: Self.snapshot(of: chat), frame: chat.frame)
        morph.orderFrontRegardless()
        chat.orderOut(nil)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.morphDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            morph.animator().setFrame(cardFrame(of: panel), display: true)
            morph.animator().alphaValue = 0
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.closeMorphWindow(morph) }
        }
    }

    /// Grows the panel's card back out into the chat window and brings
    /// LocalPilot forward.
    private func restoreChatWindow() {
        guard let (chat, frame) = minimizedWindow, let hudPanel else { return }
        minimizedWindow = nil
        showsFinishedRun = false
        chat.setFrame(frame, display: false)
        let morph = makeMorphWindow(image: Self.snapshot(of: chat), frame: cardFrame(of: hudPanel))
        morph.alphaValue = 0
        morph.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.morphDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            morph.animator().setFrame(frame, display: true)
            morph.animator().alphaValue = 1
            hudPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                hudPanel.orderOut(nil)
                hudPanel.alphaValue = 1
                NSApp.unhide(nil)
                chat.makeKeyAndOrderFront(nil)
                NSApp.activate()
                self?.closeMorphWindow(morph)
            }
        }
    }

    private func makeMorphWindow(image: NSImage?, frame: NSRect) -> NSWindow {
        if let morphWindow { closeMorphWindow(morphWindow) }
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 16
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor(white: 0.04, alpha: 1).cgColor
        window.contentView = imageView
        morphWindow = window
        return window
    }

    private func closeMorphWindow(_ window: NSWindow) {
        window.orderOut(nil)
        if morphWindow === window { morphWindow = nil }
    }

    /// The window's current contents, including the title bar area.
    private static func snapshot(of window: NSWindow) -> NSImage? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Windows

    /// Global CG coordinates (used by AX and CGEvent) have their origin at the
    /// top-left of the primary display, so the haze lives there and cursor
    /// targets map 1:1 into its SwiftUI coordinate space.
    private static var primaryScreen: NSScreen {
        NSScreen.screens.first ?? NSScreen.main ?? NSScreen()
    }

    private func makeHazeWindow(controller: AgentController) -> NSWindow {
        let window = NSWindow(
            contentRect: Self.primaryScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        // We keep a strong reference, so AppKit must not release it on close.
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: HazeView(controller: controller))
        return window
    }

    private func makeHUDPanel(controller: AgentController) -> NSPanel {
        let panel = HUDPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: AgentHUDView.width + 2 * Self.hudShadowInset,
                height: AgentHUDView.height + 2 * Self.hudShadowInset
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: AgentHUDView(
            controller: controller,
            backToChat: { [weak self] in self?.backToChat() },
            onSizeChange: { [weak self, weak panel] size in
                guard let self, let panel else { return }
                self.positionHUD(panel, size: size, on: Self.primaryScreen)
            }
        ))
        return panel
    }

    /// Keeps the HUD's top and right edges fixed as it grows or shrinks, so it
    /// never jumps while the user reads it. Defaults to the top-right corner of
    /// the screen, just under the menu bar. The panel includes 24pt of shadow
    /// room, so the card itself sits about 16pt from the edges.
    private func positionHUD(_ panel: NSPanel, size: CGSize, on screen: NSScreen) {
        guard size.width > 0, size.height > 0 else { return }
        let visible = screen.visibleFrame
        let current = panel.frame
        let isPlaced = panel.isVisible && visible.intersects(current)
        let right = isPlaced ? current.maxX : visible.maxX + 8
        let top = isPlaced ? current.maxY : visible.maxY + 8
        let frame = NSRect(x: right - size.width, y: top - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    // MARK: Focus

    private func trackExternalApps() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ownPID {
            lastExternalAppPID = frontmost.processIdentifier
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier, pid != ownPID else { return }
            MainActor.assumeIsolated {
                self?.lastExternalAppPID = pid
            }
        }
    }

    private func handFocusToExternalApp() {
        guard NSApp.isActive else { return }
        if let pid = lastExternalAppPID,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated,
           app.activate() {
            return
        }
        // No known previous app: hiding LocalPilot activates the next one.
        // The haze and HUD opt out of hiding, so Agent Mode stays visible.
        NSApp.hide(nil)
    }
}

/// Borderless panels refuse key status by default, which would make the HUD's
/// instruction field impossible to type into.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// ⌥⌘. stops the agent from any app. Uses a Carbon hot key, which needs no
/// Accessibility or Input Monitoring permission.
@MainActor
private final class GlobalStopHotKey {
    private static var onPress: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(_ action: @escaping @MainActor () -> Void) {
        guard hotKeyRef == nil else { return }
        Self.onPress = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated {
                GlobalStopHotKey.onPress?()
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C50_4C54), id: 1) // "LPLT"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Period),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
