import AppKit
import SwiftUI

/// Log events for one chat's runs. Opened from History.
struct ActivityLogView: View {
    let logFileURL: URL
    let title: String
    let taskIDs: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var events: [LocalEvent] = []
    @State private var query = ""

    private var filtered: [LocalEvent] {
        let newestFirst = events.reversed()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(newestFirst) }
        return newestFirst.filter {
            $0.event.localizedCaseInsensitiveContains(trimmed) || $0.detail.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Activity Log", subtitle: title) {
                HStack(spacing: 8) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.primary)
                        .keyboardShortcut(.defaultAction)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .buttonStyle(.secondary)
                    Button {
                        reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                TextField("Filter events", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(filtered.count) events")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

            if events.isEmpty {
                EmptyPlaceholder(symbol: "list.bullet.rectangle", title: "No activity", message: "This chat has no logged events.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { index, event in
                            EventRow(event: event)
                                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.018))
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }

            Text(logFileURL.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 640)
        .background(Theme.canvas)
        .task { reload() }
    }

    private func reload() {
        let reader = LocalEventLogReader(fileURL: logFileURL)
        let taskIDs = taskIDs
        Task.detached(priority: .userInitiated) {
            let loaded = reader.events(forTasks: taskIDs)
            await MainActor.run { events = loaded }
        }
    }
}

private struct EventRow: View {
    let event: LocalEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(event.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 74, alignment: .leading)
            Text(event.event.replacingOccurrences(of: "_", with: " "))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
                .frame(width: 150, alignment: .leading)
            Text(event.detail)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var tint: Color {
        switch event.event {
        case "task_done": Theme.sky
        case "task_blocked", "approval_denied", "task_stopped": Theme.coral
        case "approval_required", "task_paused", "planner_invalid_json", "plan_aborted": Theme.amber
        case "executor_result", "approval_allowed", "task_started", "task_continued": Theme.mint
        case "policy_decision", "guard_decision", "guard_audit": Theme.accentAlt
        default: Theme.textSecondary
        }
    }
}

struct EmptyPlaceholder: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            IconTile(symbol: symbol, tint: Theme.textTertiary, size: 44)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
