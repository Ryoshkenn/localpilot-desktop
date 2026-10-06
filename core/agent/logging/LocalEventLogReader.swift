import Foundation

/// Reads back the JSONL log written by `LocalEventLogger`.
public struct LocalEventLogReader: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The newest `limit` events, oldest first. Only the tail of the file is
    /// read, so a long-lived log never loads fully into memory. Malformed
    /// lines are skipped.
    public func recentEvents(limit: Int = 500, maxBytes: Int = 2 * 1024 * 1024) -> [LocalEvent] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else {
            return []
        }

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // A tail read usually starts mid-line; drop the partial first line.
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lines.suffix(limit).compactMap { try? decoder.decode(LocalEvent.self, from: Data($0)) }
    }

    /// Events belonging to any of `taskIDs` (one chat's runs), oldest first.
    public func events(forTasks taskIDs: Set<UUID>, limit: Int = 5_000) -> [LocalEvent] {
        guard !taskIDs.isEmpty else { return [] }
        return recentEvents(limit: limit, maxBytes: 16 * 1024 * 1024).filter { event in
            event.taskID.map(taskIDs.contains) ?? false
        }
    }

    /// Past runs reconstructed from task lifecycle events, newest first.
    public func taskSummaries(limit: Int = 5_000) -> [TaskSummary] {
        Self.summarize(recentEvents(limit: limit))
    }

    static func summarize(_ events: [LocalEvent]) -> [TaskSummary] {
        var byID: [UUID: TaskSummary] = [:]
        for event in events {
            guard let id = event.taskID else { continue }
            if event.event == "task_started" {
                byID[id] = TaskSummary(id: id, task: event.detail, startedAt: event.timestamp)
                continue
            }
            guard var summary = byID[id] else { continue }
            summary.lastEventAt = event.timestamp
            switch event.event {
            case "executor_result":
                summary.stepCount += 1
            case "task_done":
                summary.outcome = .done
                summary.detail = event.detail
            case "task_blocked":
                summary.outcome = .blocked
                summary.detail = event.detail
            case "approval_denied":
                summary.outcome = .blocked
                summary.detail = "You denied a step."
            case "task_stopped":
                summary.outcome = .stopped
                summary.detail = "Stopped by you."
            default:
                break
            }
            byID[id] = summary
        }
        return byID.values.sorted { $0.startedAt > $1.startedAt }
    }
}

public struct TaskSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let task: String
    public let startedAt: Date
    public var lastEventAt: Date
    public var stepCount = 0
    /// `nil` when the log has no terminal event (e.g. the app quit mid-run).
    public var outcome: AgentRunStatus?
    public var detail = ""

    public init(id: UUID, task: String, startedAt: Date) {
        self.id = id
        self.task = task
        self.startedAt = startedAt
        self.lastEventAt = startedAt
    }
}
