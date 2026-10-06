import SwiftUI

// MARK: - Haze

/// Full-screen, click-through Agent Mode backdrop: a soft vignette, a glowing
/// edge that circulates while the agent works, and the AI cursor showing where
/// the next action will land.
struct HazeView: View {
    let controller: AgentController
    private let pointer = PointerIndicator.shared

    private var isWorking: Bool { controller.overlayState == .running }

    private var tint: Color {
        switch controller.overlayState {
        case .paused, .approvalRequired: Theme.amber
        default: Theme.accent
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(
                        RadialGradient(
                            colors: [.clear, tint.opacity(isWorking ? 0.10 : 0.16)],
                            center: .center,
                            startRadius: min(proxy.size.width, proxy.size.height) * 0.35,
                            endRadius: max(proxy.size.width, proxy.size.height) * 0.75
                        )
                    )
                    .animation(.easeInOut(duration: 0.4), value: controller.overlayState)

                GlowBorder(size: proxy.size, tint: tint, isAnimating: isWorking)

                if let target = pointer.location {
                    AICursor(gesture: pointer.gesture, pressCount: pointer.pressCount)
                        .position(x: target.x + AICursor.tipOffset.width, y: target.y + AICursor.tipOffset.height)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.spring(response: PointerIndicator.glideSeconds, dampingFraction: 0.85), value: pointer.location)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}

private struct GlowBorder: View {
    let size: CGSize
    let tint: Color
    let isAnimating: Bool
    @State private var spin = false

    var body: some View {
        let diagonal = (size.width * size.width + size.height * size.height).squareRoot()
        let gradient = AngularGradient(
            colors: isAnimating
                ? [Theme.accent, Theme.accentAlt, Theme.mint, Theme.accent]
                : [tint, tint.opacity(0.6), tint],
            center: .center
        )
        ZStack {
            gradient
                .frame(width: diagonal, height: diagonal)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .frame(width: size.width, height: size.height)
                .mask(Rectangle().strokeBorder(lineWidth: 10).blur(radius: 8))
                .opacity(0.8)
            gradient
                .frame(width: diagonal, height: diagonal)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .frame(width: size.width, height: size.height)
                .mask(Rectangle().strokeBorder(lineWidth: 2.5))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .onAppear { updateSpin() }
        .onChange(of: isAnimating) { _, _ in updateSpin() }
    }

    private func updateSpin() {
        if isAnimating {
            spin = false
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                spin = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { spin = false }
        }
    }
}

/// The AI cursor. Its arrow tip sits exactly on the target point.
/// LocalPilot's own pointer, shown wherever it moves the real mouse.
private struct AICursor: View {
    let gesture: PointerIndicator.Gesture?
    let pressCount: Int
    @State private var ripple = false

    static let size = CGSize(width: 180, height: 90)
    /// Arrow tip in local coordinates (the view is centered on `position`).
    static let tip = CGPoint(x: 30, y: 30)
    static var tipOffset: CGSize {
        CGSize(width: size.width / 2 - tip.x, height: size.height / 2 - tip.y)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .strokeBorder(Theme.accent, lineWidth: 2.5)
                .frame(width: 44, height: 44)
                .scaleEffect(ripple ? 1.5 : 0.3)
                .opacity(ripple ? 0 : 0.95)
                .offset(x: Self.tip.x - 22, y: Self.tip.y - 22)

            PointerArrow()
                .fill(Theme.accentGradient)
                .overlay(PointerArrow().stroke(Theme.onAccent, style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
                .frame(width: 22, height: 32)
                .shadow(color: Theme.accent.opacity(0.7), radius: 10)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                .offset(x: Self.tip.x, y: Self.tip.y)

            if let gesture {
                Text(gesture.rawValue)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    .offset(x: Self.tip.x + 20, y: Self.tip.y + 30)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .onChange(of: pressCount) { _, _ in pulse() }
    }

    private func pulse() {
        ripple = false
        withAnimation(.easeOut(duration: 0.6)) { ripple = true }
    }
}

/// Classic arrow pointer with its tip at the top-left corner of the rect.
private struct PointerArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.87), (0.33, 0.66), (0.57, 1), (0.81, 0.93), (0.57, 0.6), (1, 0.6)]
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for (x, y) in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - HUD

/// Floating Agent Mode panel, pinned to the top-right corner: the same live
/// transcript as the chat (expandable steps, streaming output), a token count
/// and timer, and Pause/Stop. When the run ends it offers a way back to chat.
/// Approvals appear inline so the user never has to switch windows.
struct AgentHUDView: View {
    @Bindable var controller: AgentController
    let backToChat: () -> Void
    let onSizeChange: (CGSize) -> Void
    @State private var instruction = ""
    @State private var openGroups: Set<UUID> = []

    static let width: CGFloat = 340
    static let height: CGFloat = 480

    private var isActive: Bool { controller.runStatus.isActive }
    private var isAwaitingApproval: Bool { controller.pendingApproval != nil }

    /// The request that started this run.
    private var runAnchor: ChatMessage? {
        controller.messages.last(where: { $0.role == .user })
    }

    /// The request and everything after it: this run's steps and replies.
    private var runMessages: [ChatMessage] {
        guard let anchor = runAnchor, let index = controller.messages.lastIndex(of: anchor) else { return controller.messages }
        return Array(controller.messages[index...])
    }

    var body: some View {
        VStack(spacing: 0) {
            stats
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TranscriptView(controller: controller, messages: runMessages, openGroups: $openGroups, compact: true)
                    inlinePrompt
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transcriptScrolling()
            // Text fades out at the edges instead of hard divider lines.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.94),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            controls
                .padding(12)
        }
        .frame(width: Self.width, height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.canvas.opacity(0.82))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        // Room for the shadow inside the transparent panel.
        .padding(24)
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: HUDSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(HUDSizeKey.self) { size in
            onSizeChange(size)
        }
        .onChange(of: runAnchor?.id) { _, _ in openGroups = [] }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: controller.pendingApproval)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: controller.runStatus)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent Mode")
    }

    /// Tokens generated this run and the time it has taken.
    private var stats: some View {
        HStack(spacing: 10) {
            Text("\(controller.runGeneratedTokens) tokens")
                .contentTransition(.numericText())
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.duration(from: controller.runStartedAt, to: controller.runEndedAt ?? context.date))
            }
            Spacer(minLength: 4)
            if controller.runIsDryRun {
                Chip(text: "Dry run", symbol: "shield.lefthalf.filled", tint: Theme.mint)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.textSecondary)
        .monospacedDigit()
        .animation(.default, value: controller.runGeneratedTokens)
    }

    @ViewBuilder
    private var inlinePrompt: some View {
        if let approval = controller.pendingApproval {
            ApprovalCard(
                approval: approval,
                compact: true,
                allow: controller.approvePendingAction,
                deny: controller.denyPendingAction
            )
        } else if controller.runStatus == .paused {
            VStack(alignment: .leading, spacing: 8) {
                if let question = controller.pendingQuestion {
                    Text(question)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField(controller.pendingQuestion == nil ? "Add an instruction (optional)" : "Your answer", text: $instruction, axis: .vertical)
                    .lineLimit(1...4)
                    .fieldChrome()
                    .onSubmit(resume)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if isActive {
            HStack(spacing: 8) {
                if controller.runStatus == .paused && !isAwaitingApproval {
                    Button(action: resume) {
                        Label("Continue", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primary)
                    .help("Look at the screen again and carry on")
                } else {
                    Button {
                        controller.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondary)
                    .disabled(controller.runStatus != .running)
                    .help("Pause at the next safe point")
                }
                Button(role: .destructive) {
                    controller.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.danger)
                .keyboardShortcut(.cancelAction)
                .help("Hard stop (⌥⌘. from any app)")
            }
        } else {
            Button(action: backToChat) {
                Label("Back to chat", systemImage: "bubble.left.and.text.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func resume() {
        controller.continueTask(instruction: instruction)
        instruction = ""
    }

    static func duration(from start: Date?, to end: Date) -> String {
        guard let start else { return "0:00" }
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct HUDSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
