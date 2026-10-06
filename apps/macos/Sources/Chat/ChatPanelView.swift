import AppKit
import SwiftUI

struct ChatPanelView: View {
    @Bindable var controller: AgentController
    @Binding var taskText: String
    let openSettings: () -> Void
    @State private var continueInstruction = ""
    /// Activity groups the user opened, keyed by the message the group follows.
    @State private var openGroups: Set<UUID> = []
    @FocusState private var composerFocused: Bool

    private var isActive: Bool { controller.runStatus.isActive }

    /// The transcript is "empty" until the first task is sent.
    private var showsEmptyState: Bool {
        controller.messages.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            ComposerView(
                controller: controller,
                text: $taskText,
                isFocused: $composerFocused,
                openSettings: openSettings,
                send: send
            )
        }
        .background(Theme.canvas)
        .onAppear { composerFocused = true }
        .onChange(of: controller.conversationID) { _, _ in openGroups = [] }
    }

    /// Shown above the transcript when the selected model can't be reached.
    @ViewBuilder
    private var modelProblem: some View {
        if case let .unavailable(reason) = controller.modelStatus, !controller.runStatus.isActive {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(controller.settings.activeModelLabel) isn't available")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Retry") { controller.checkModelConnection() }
                    .buttonStyle(.secondary)
                Button("Settings", action: openSettings)
                    .buttonStyle(.secondary)
            }
            .card(padding: 12, tint: Theme.coral)
            .padding(.bottom, 14)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    modelProblem
                    if showsEmptyState {
                        EmptyStateView { suggestion in
                            taskText = suggestion
                            composerFocused = true
                        }
                        .padding(.top, 72)
                    } else {
                        TranscriptView(controller: controller, messages: controller.messages, openGroups: $openGroups)
                        Color.clear.frame(height: 1).id("bottom")
                    }

                    if !controller.todo.isEmpty, isActive {
                        ChecklistCard(items: controller.todo)
                            .padding(.top, 16)
                    }
                    if let approval = controller.pendingApproval {
                        ApprovalCard(
                            approval: approval,
                            allow: controller.approvePendingAction,
                            deny: controller.denyPendingAction
                        )
                        .padding(.top, 16)
                        .id("approval")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if controller.runStatus == .paused {
                        pausedCard
                            .padding(.top, 16)
                            .id("paused")
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .transcriptScrolling()
            // Sending a message always jumps to it, even if scrolled up.
            .onChange(of: controller.messages.last?.id) { _, _ in
                if controller.messages.last?.role == .user { scrollToBottom(proxy) }
            }
            .onChange(of: controller.conversationID) { _, _ in
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: controller.pendingApproval) { _, approval in
                if approval != nil {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("approval", anchor: .bottom) }
                }
            }
            .animation(.easeOut(duration: 0.2), value: controller.pendingApproval)
            .animation(.easeOut(duration: 0.2), value: controller.runStatus)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !controller.messages.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var pausedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: controller.pendingQuestion == nil ? "pause.fill" : "questionmark.bubble", tint: Theme.amber, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.pendingQuestion == nil ? "Paused" : "LocalPilot needs your input")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(controller.pendingQuestion ?? "Do anything you need to on screen. LocalPilot will look again before its next step.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField(controller.pendingQuestion == nil ? "Add an instruction (optional)" : "Your answer", text: $continueInstruction, axis: .vertical)
                .lineLimit(1...4)
                .fieldChrome()
                .onSubmit(resume)
            HStack {
                Button(role: .destructive) {
                    controller.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.danger)
                Spacer()
                Button(action: resume) {
                    Label("Continue", systemImage: "play.fill")
                }
                .buttonStyle(.primary)
            }
        }
        .card(tint: Theme.amber)
    }

    private func resume() {
        controller.continueTask(instruction: continueInstruction)
        continueInstruction = ""
    }

    // MARK: Composer

    private var canSend: Bool {
        !isActive && !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        controller.start(task: taskText)
        taskText = ""
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let pick: (String) -> Void

    private let suggestions: [(symbol: String, title: String, prompt: String)] = [
        ("safari", "Open a page", "Open https://developer.apple.com"),
        ("macwindow.on.rectangle", "Switch apps", "Switch to Finder"),
        ("magnifyingglass", "Search the web", "Search for the latest Swift release"),
        ("camera.viewfinder", "Look at the screen", "What do you see in the front window?"),
        ("keyboard", "Type into a field", "Type \"Hello from LocalPilot\""),
        ("command", "Press a key", "Press escape"),
    ]

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 14) {
                AgentOrb(status: .idle, size: 64)
                Text("What should LocalPilot do?")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(suggestions, id: \.title) { suggestion in
                    SuggestionCard(symbol: suggestion.symbol, title: suggestion.title, prompt: suggestion.prompt) {
                        pick(suggestion.prompt)
                    }
                }
            }
        }
    }
}

private struct SuggestionCard: View {
    let symbol: String
    let title: String
    let prompt: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                IconTile(symbol: symbol, tint: Theme.accent, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(prompt)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(isHovering ? Theme.surfaceRaised : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(isHovering ? Theme.accent.opacity(0.4) : Theme.stroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

