import Foundation

/// A chat thread: its transcript plus the runs (task IDs) started from it, so
/// the activity log can be filtered to just this chat.
public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var taskIDs: [UUID]

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), messages: [ChatMessage] = [], taskIDs: [UUID] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.messages = messages
        self.taskIDs = taskIDs
    }

    public var summary: ConversationSummary {
        ConversationSummary(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            taskIDs: taskIDs,
            stepCount: messages.filter { $0.action != nil }.count,
            lastOutcome: messages.last(where: { $0.outcome != nil })?.outcome,
            preview: messages.last(where: { $0.role == .agent && !$0.isActivity })?.text ?? ""
        )
    }

    /// First line of the first request, shortened for lists.
    static func title(for task: String) -> String {
        let firstLine = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
        return firstLine.count > 80 ? String(firstLine.prefix(79)) + "…" : firstLine
    }
}

public struct ConversationSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let taskIDs: [UUID]
    /// Tool calls made across the whole chat.
    public let stepCount: Int
    /// How the most recent run ended, if any run reported an outcome.
    public let lastOutcome: AgentRunStatus?
    /// Latest reply from LocalPilot, for a one-line preview.
    public let preview: String
}

/// One JSON file per conversation under Application Support.
public struct ConversationStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? AppSettings.defaultSupportDirectory().appending(path: "conversations", directoryHint: .isDirectory)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    // Default (numeric) dates keep sub-second precision, so message order
    // and equality survive a save/load round trip.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public func save(_ conversation: Conversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(conversation).write(to: fileURL(for: conversation.id), options: .atomic)
    }

    public func load(id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? Self.decoder.decode(Conversation.self, from: data)
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// Every saved conversation, most recently updated first. Unreadable files are skipped.
    public func summaries() -> [ConversationSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Self.decoder.decode(Conversation.self, from: data).summary
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
