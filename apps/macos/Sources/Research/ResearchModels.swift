import Foundation

enum ResearchTab: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case paper = "Paper"
    case results = "Results"

    var id: String { rawValue }
}

enum ResearchEntryKind: String, Codable, CaseIterable, Identifiable {
    case note
    case workLog
    case paper
    case results

    var id: String { rawValue }

    var label: String {
        switch self {
        case .note: "Research note"
        case .workLog: "Work log"
        case .paper: "Paper draft"
        case .results: "Results log"
        }
    }

    var symbol: String {
        switch self {
        case .note: "note.text"
        case .workLog: "checklist"
        case .paper: "doc.richtext"
        case .results: "chart.bar.doc.horizontal"
        }
    }

    var tab: ResearchTab {
        switch self {
        case .note, .workLog: .notes
        case .paper: .paper
        case .results: .results
        }
    }
}

struct ResearchEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var kind: ResearchEntryKind
    var content: String
    var createdAt: Date
    var updatedAt: Date

    var wordCount: Int {
        content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

enum ResearchRecordKind: String, Codable, CaseIterable, Identifiable {
    case local = "Local run"
    case cited = "Cited result"

    var id: String { rawValue }
}

enum ResearchOutcome: String, Codable, CaseIterable, Identifiable {
    case success = "Success"
    case partial = "Partial"
    case failure = "Failed"

    var id: String { rawValue }
}

struct ResearchExperiment: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: ResearchRecordKind
    var method: String
    var device: String
    var task: String
    var outcome: ResearchOutcome?
    var successRate: Double?
    var latencySeconds: Double?
    var tokenCount: Int?
    var notes: String
    var source: String
    var createdAt: Date
}

struct ResearchWorkspaceSnapshot: Codable {
    var entries: [ResearchEntry]
    var experiments: [ResearchExperiment]
    var capturedRunIDs: Set<UUID>
}

struct BenchmarkComparison: Identifiable {
    let id: String
    let method: String
    let success: String
    let latency: String
    let tokens: String
    let source: String
    let isLocal: Bool
    let isPlaceholder: Bool
}
