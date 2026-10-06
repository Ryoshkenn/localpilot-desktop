import SwiftUI

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Theme.surfaceRaised.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TintedButtonStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                tint.opacity(configuration.isPressed ? 0.24 : 0.14),
                in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
            .frame(width: size, height: size)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.12 : (isHovering ? 0.07 : 0)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == TintedButtonStyle {
    static func tinted(_ tint: Color) -> TintedButtonStyle { TintedButtonStyle(tint: tint) }
    static var danger: TintedButtonStyle { TintedButtonStyle(tint: Theme.coral) }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

// MARK: - Surfaces

struct CardModifier: ViewModifier {
    var padding: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.surface)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.06))
                        }
                    }
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(tint?.opacity(0.35) ?? Theme.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(CardModifier(padding: padding, tint: tint))
    }

    /// Plain text-field chrome that matches the dark surfaces.
    func fieldChrome() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1)
            )
    }
}

/// Single-line text field in the app's field chrome. The placeholder is drawn
/// by hand: macOS ignores a prompt's color under the field's foreground style,
/// so stock placeholders read like real values on the dark surfaces.
struct ThemedTextField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .allowsHitTesting(false)
            }
            TextField("", text: $text)
        }
        .fieldChrome()
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Rounded square holding an SF Symbol, used for action and nav icons.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            )
    }
}

// MARK: - Status

struct PulsingDot: View {
    var color: Color
    var isAnimating: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1 : 0.4)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear { updatePulse() }
        .onChange(of: isAnimating) { _, _ in updatePulse() }
    }

    private func updatePulse() {
        guard isAnimating else {
            pulse = false
            return
        }
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}

struct StatusBadge: View {
    let status: AgentRunStatus

    var body: some View {
        HStack(spacing: 6) {
            PulsingDot(color: status.tint, isAnimating: status == .running)
            Text(status.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.tint)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(status.tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(status.tint.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.label)")
    }
}

/// Small capsule chip for modes and metadata.
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
    }
}

/// The LocalPilot "presence": a glowing orb whose ring spins while working.
struct AgentOrb: View {
    let status: AgentRunStatus
    var size: CGFloat = 36
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [status == .idle ? Theme.accent : status.tint, Theme.accentAlt.opacity(0.6), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.75
                    )
                )
                .blur(radius: size * 0.12)
                .opacity(status == .running ? 0.9 : 0.55)
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [Theme.accent, Theme.accentAlt, Theme.mint, Theme.accent],
                        center: .center
                    ),
                    lineWidth: max(1.5, size * 0.06)
                )
                .rotationEffect(.degrees(spin ? 360 : 0))
                .opacity(status == .running ? 1 : 0.5)
            Circle()
                .fill(Theme.canvas)
                .padding(size * 0.14)
            Image(systemName: "location.north.fill")
                .font(.system(size: size * 0.34, weight: .bold))
                .rotationEffect(.degrees(-35))
                .foregroundStyle(Theme.accentGradient)
        }
        .frame(width: size, height: size)
        .onAppear { updateSpin() }
        .onChange(of: status) { _, _ in updateSpin() }
        .accessibilityHidden(true)
    }

    private func updateSpin() {
        if status == .running {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                spin = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.4)) {
                spin = false
            }
        }
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
    }
}

/// Switch row with a title and explanatory subtitle.
struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var tint: Color = Theme.accent

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(tint)
        }
    }
}

/// Labeled form field used throughout Settings.
struct LabeledField<Content: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            content
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Page header shared by the non-chat screens.
struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            accessory
        }
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
