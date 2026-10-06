import CoreGraphics
import Foundation
import Observation

/// The on-screen LocalPilot pointer. Only the Quartz controller moves it,
/// right before it posts real mouse events, so it appears for coordinate
/// clicks and scrolls but never for accessibility presses or browser actions,
/// which don't touch the mouse.
@MainActor
@Observable
public final class PointerIndicator {
    public enum Gesture: String, Sendable {
        case click = "Click"
        case doubleClick = "Double-click"
        case scroll = "Scroll"
    }

    public static let shared = PointerIndicator()

    /// Global display point (top-left origin), or nil when hidden.
    public private(set) var location: CGPoint?
    public private(set) var gesture: Gesture?
    /// Bumped on every press so the view can replay its ripple.
    public private(set) var pressCount = 0

    /// How long the pointer takes to glide to a new spot. The controller waits
    /// this long before pressing so the user sees where it's about to click.
    public static let glideSeconds = 0.35

    private init() {}

    public func move(to point: CGPoint, gesture: Gesture) {
        location = point
        self.gesture = gesture
    }

    public func press() {
        pressCount += 1
    }

    public func hide() {
        location = nil
        gesture = nil
    }
}
