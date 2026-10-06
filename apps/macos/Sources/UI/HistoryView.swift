import SwiftUI

/// Saved chats. Click one to reopen and continue it; each keeps its own
/// activity log.
struct HistoryView: View {
    let controller: AgentController
    /// Called after a chat is opened so the window can switch to it.
    let open: (UUID) -> Void
    @State private var summaries: [ConversationSummary] = []
    @State private var isLoaded = false
    @State private var logTarget: ConversationSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "History", subtitle: "Your chats with LocalPilot. Open one to pick up where you left off.")

            if isLoaded && summaries.isEmpty {
                EmptyPlaceholder(symbol: "clock.arrow.circlepath", title: "No chats yet", message: "Chats you start will be listed here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(summaries) { summary in
                            HistoryRow(
                                summary: summary,
                                isCurrent: summary.id == controller.conversationID,
                                open: { open(summary.id) },
                                showLog: { logTarget = summary },
                                delete: { controller.deleteConversation(id: summary.id) }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 52)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
        .task(id: controller.conversationsRevision) { reload() }
        .sheet(item: $logTarget) { summary in
            ActivityLogView(logFileURL: controller.logFileURL, title: summary.title, taskIDs: Set(summary.taskIDs))
        }
    }

    private func reload() {
        let store = controller.conversationStore
        Task.detached(priority: .userInitiated) {
            let loaded = store.summaries()
            await MainActor.run {
                summaries = loaded
                isLoaded = true
            }
        }
    }
}

private struct HistoryRow: View {
    let summary: ConversationSummary
    let isCurrent: Bool
    let open: () -> Void
    let showLog: () -> Void
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(summary.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if isCurrent {
                        Chip(text: "Open", tint: Theme.accent)
                    }
                }
                if !summary.preview.isEmpty {
                    Text(summary.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(summary.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    if summary.stepCount > 0 {
                        Text("·")
                        Text(summary.stepCount == 1 ? "1 tool call" : "\(summary.stepCount) tool calls")
                    }
                    if let outcome = summary.lastOutcome, outcome != .done {
                        Text("·")
                        Text(outcome.label).foregroundStyle(outcome.tint)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            Button(action: showLog) {
                Label("View activity log", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.secondary)
            .opacity(isHovering ? 1 : 0.6)
            .help("See every logged event for this chat")
        }
        .card(padding: 14)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(isHovering ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open chat", action: open)
            Button("View activity log", action: showLog)
            Divider()
            Button("Delete chat", role: .destructive, action: delete)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open chat", open)
    }
}
