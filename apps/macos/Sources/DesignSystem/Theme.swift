import SwiftUI

/// LocalPilot's visual language: black and white. Surfaces are neutral
/// grays, the accent is white, and status "tints" are shades of gray, so
/// state is carried by symbols and labels rather than color. Every custom view
/// pulls colors from here so the app reads as one system.
enum Theme {
    static let canvas = Color(hex: 0x0A0A0A)
    static let sidebar = Color(hex: 0x0F0F0F)
    static let surface = Color(hex: 0x161616)
    static let surfaceRaised = Color(hex: 0x1F1F1F)
    static let surfaceSunken = Color(hex: 0x0D0D0D)
    static let stroke = Color.white.opacity(0.08)
    static let strokeStrong = Color.white.opacity(0.14)

    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.40)

    static let accent = Color(hex: 0xF2F2F2)
    static let accentAlt = Color(hex: 0xC8C8C8)
    /// Text and symbols drawn on an accent fill.
    static let onAccent = Color(hex: 0x0A0A0A)
    static let mint = Color(hex: 0xE0E0E0)
    static let amber = Color(hex: 0xB8B8B8)
    static let coral = Color(hex: 0x9A9A9A)
    static let sky = Color(hex: 0xD0D0D0)

    static let accentGradient = LinearGradient(
        colors: [accent, accentAlt],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cornerRadius: CGFloat = 14
    static let smallCornerRadius: CGFloat = 9
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension AgentRunStatus {
    var tint: Color {
        switch self {
        case .idle: Theme.textTertiary
        case .running: Theme.mint
        case .paused: Theme.amber
        case .stopping, .stopped: Theme.textSecondary
        case .done: Theme.sky
        case .blocked: Theme.coral
        }
    }

    var label: String {
        switch self {
        case .idle: "Ready"
        case .running: "Working"
        case .paused: "Paused"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .done: "Done"
        case .blocked: "Blocked"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "circle.dotted"
        case .running: "bolt.fill"
        case .paused: "pause.fill"
        case .stopping, .stopped: "stop.fill"
        case .done: "checkmark"
        case .blocked: "exclamationmark.octagon.fill"
        }
    }
}

extension ActionType {
    var symbol: String {
        switch self {
        case .observe: "eye"
        case .screenshot: "camera"
        case .browserNewTab, .browserNavigate, .browserSwitchTab, .browserCloseTab: "globe"
        case .click: "cursorarrow.click"
        case .doubleClick: "cursorarrow.click.2"
        case .typeTextSafe, .typeTextSensitive: "keyboard"
        case .pressKey: "command"
        case .scroll: "arrow.up.and.down"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .openURL: "safari"
        case .runTerminalCommand: "terminal"
        case .switchApp: "macwindow.on.rectangle"
        case .wait: "hourglass"
        case .finish: "flag.checkered"
        case .askUser: "questionmark.bubble"
        case .webSearch: "magnifyingglass"
        case .readWebpage: "doc.text"
        }
    }

    /// Tint grouping: reading the screen, acting on it, or reaching outside it.
    var tint: Color {
        switch self {
        case .observe, .screenshot, .wait, .finish, .askUser, .webSearch, .readWebpage: Theme.sky
        case .click, .doubleClick, .scroll, .pressKey, .switchApp: Theme.accent
        case .typeTextSafe, .copy, .paste: Theme.accentAlt
        case .browserNewTab, .browserNavigate, .browserSwitchTab, .browserCloseTab, .openURL, .runTerminalCommand, .typeTextSensitive: Theme.amber
        }
    }
}
