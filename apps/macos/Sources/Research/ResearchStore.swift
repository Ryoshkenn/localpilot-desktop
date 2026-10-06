import Foundation
import Observation

@MainActor
@Observable
final class ResearchStore {
    private(set) var entries: [ResearchEntry]
    private(set) var experiments: [ResearchExperiment]
    private(set) var capturedRunIDs: Set<UUID>
    private(set) var lastSavedAt: Date?

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()

        if let data = try? Data(contentsOf: self.fileURL),
           let snapshot = try? JSONDecoder.research.decode(ResearchWorkspaceSnapshot.self, from: data) {
            entries = snapshot.entries
            experiments = snapshot.experiments
            capturedRunIDs = snapshot.capturedRunIDs
            lastSavedAt = .now
        } else {
            entries = Self.seedEntries()
            experiments = []
            capturedRunIDs = []
            lastSavedAt = nil
        }
    }

    var draftProgress: Double {
        guard let draft = entries.first(where: { $0.kind == .paper }) else { return 0 }
        return min(1, Double(draft.wordCount) / 3_000)
    }

    var totalWordCount: Int {
        entries.reduce(0) { $0 + $1.wordCount }
    }

    var benchmarkComparisons: [BenchmarkComparison] {
        var rows = localComparisons + citedComparisons
        let existingMethods = Set(rows.map { $0.method.lowercased() })

        let references = ["OSWorld baseline", "WebArena baseline", "Computer-use API"]
        for reference in references where !existingMethods.contains(reference.lowercased()) {
            rows.append(
                BenchmarkComparison(
                    id: "placeholder-\(reference)",
                    method: reference,
                    success: "—",
                    latency: "—",
                    tokens: "—",
                    source: "Add a cited result",
                    isLocal: false,
                    isPlaceholder: true
                )
            )
        }
        return rows
    }

    func entry(id: UUID?) -> ResearchEntry? {
        guard let id else { return nil }
        return entries.first(where: { $0.id == id })
    }

    func entries(matching query: String) -> [ResearchEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries.sorted { $0.updatedAt > $1.updatedAt } }
        return entries
            .filter {
                $0.title.localizedCaseInsensitiveContains(trimmed)
                    || $0.content.localizedCaseInsensitiveContains(trimmed)
                    || $0.kind.label.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func createEntry(kind: ResearchEntryKind) -> UUID {
        let now = Date.now
        let entry = ResearchEntry(
            id: UUID(),
            title: Self.defaultTitle(for: kind),
            kind: kind,
            content: Self.template(for: kind),
            createdAt: now,
            updatedAt: now
        )
        entries.insert(entry, at: 0)
        persist()
        return entry.id
    }

    func firstEntryID(for tab: ResearchTab) -> UUID {
        if let existing = entries
            .filter({ $0.kind.tab == tab })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            return existing.id
        }

        switch tab {
        case .notes: return createEntry(kind: .note)
        case .paper: return createEntry(kind: .paper)
        case .results: return createEntry(kind: .results)
        }
    }

    func updateTitle(_ title: String, for id: UUID) {
        mutateEntry(id: id) { $0.title = title }
    }

    func updateContent(_ content: String, for id: UUID) {
        mutateEntry(id: id) { $0.content = content }
    }

    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func addExperiment(_ experiment: ResearchExperiment) {
        experiments.insert(experiment, at: 0)
        persist()
    }

    @discardableResult
    func captureLatestRun(from logFileURL: URL) -> UUID? {
        let summaries = LocalEventLogReader(fileURL: logFileURL).taskSummaries()
        guard let summary = summaries.first(where: { !capturedRunIDs.contains($0.id) }) else { return nil }

        let logID: UUID
        if let existing = entries.first(where: { $0.kind == .workLog }) {
            logID = existing.id
        } else {
            logID = createEntry(kind: .workLog)
        }

        let outcome = summary.outcome?.label ?? "Interrupted"
        let detail = summary.detail.isEmpty ? "No terminal detail was recorded." : summary.detail
        let update = """

        ## \(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
        - **Task:** \(summary.task)
        - **Outcome:** \(outcome)
        - **Steps:** \(summary.stepCount)
        - **Result:** \(detail)
        """

        mutateEntry(id: logID) { entry in
            entry.content += update
        }
        capturedRunIDs.insert(summary.id)
        persist()
        return logID
    }

    func exportMarkdown() -> String {
        let entryText = entries
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { entry in
                """
                # \(entry.title)

                _\(entry.kind.label) · Updated \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))_

                \(entry.content)
                """
            }
            .joined(separator: "\n\n---\n\n")

        let experimentText = experiments.map { experiment in
            let success = experiment.successRate.map { String(format: "%.1f%%", $0) }
                ?? experiment.outcome?.rawValue
                ?? "—"
            return "| \(experiment.method.markdownCell) | \(experiment.task.markdownCell) | \(success) | \(experiment.latencySeconds.displaySeconds) | \(experiment.tokenCount.displayCount) | \(experiment.source.markdownCell) |"
        }.joined(separator: "\n")

        return """
        # LocalPilot research workspace

        Exported \(Date.now.formatted(date: .long, time: .shortened)).

        \(entryText)

        ---

        # Experiment ledger

        | Method | Task | Result | Latency | Tokens | Source |
        | --- | --- | ---: | ---: | ---: | --- |
        \(experimentText.isEmpty ? "| No runs recorded | — | — | — | — | — |" : experimentText)
        """
    }

    private func mutateEntry(id: UUID, change: (inout ResearchEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        entries[index].updatedAt = .now
        persist()
    }

    private func persist() {
        let snapshot = ResearchWorkspaceSnapshot(
            entries: entries,
            experiments: experiments,
            capturedRunIDs: capturedRunIDs
        )
        guard let data = try? JSONEncoder.research.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: fileURL, options: .atomic)
            lastSavedAt = .now
        } catch {
            // The editor remains usable if persistence is temporarily unavailable.
        }
    }

    private var localComparisons: [BenchmarkComparison] {
        let local = Dictionary(grouping: experiments.filter { $0.kind == .local }, by: \.method)
        return local.keys.sorted().compactMap { method in
            guard let runs = local[method], !runs.isEmpty else { return nil }
            let successes = runs.filter { $0.outcome == .success }.count
            let partials = runs.filter { $0.outcome == .partial }.count
            let successRate = (Double(successes) + Double(partials) * 0.5) / Double(runs.count) * 100
            let latencies = runs.compactMap(\.latencySeconds)
            let tokens = runs.compactMap(\.tokenCount)
            return BenchmarkComparison(
                id: "local-\(method)",
                method: "LocalPilot / \(method)",
                success: String(format: "%.0f%%", successRate),
                latency: latencies.isEmpty ? "—" : String(format: "%.1fs", latencies.reduce(0, +) / Double(latencies.count)),
                tokens: tokens.isEmpty ? "—" : Self.compactCount(tokens.reduce(0, +) / tokens.count),
                source: "Local · \(runs.count) run\(runs.count == 1 ? "" : "s")",
                isLocal: true,
                isPlaceholder: false
            )
        }
    }

    private var citedComparisons: [BenchmarkComparison] {
        experiments.filter { $0.kind == .cited }.map { experiment in
            BenchmarkComparison(
                id: experiment.id.uuidString,
                method: experiment.method,
                success: experiment.successRate.map { String(format: "%.1f%%", $0) } ?? "—",
                latency: experiment.latencySeconds.displaySeconds,
                tokens: experiment.tokenCount.map(Self.compactCount) ?? "—",
                source: experiment.source.isEmpty ? "Source needed" : experiment.source,
                isLocal: false,
                isPlaceholder: false
            )
        }
    }

    private static func compactCount(_ value: Int) -> String {
        value >= 1_000 ? String(format: "%.1fK", Double(value) / 1_000) : "\(value)"
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appending(path: "LocalPilot Desktop", directoryHint: .isDirectory)
            .appending(path: "research-workspace.json")
    }

    private static func seedEntries() -> [ResearchEntry] {
        let now = Date.now
        return [
            ResearchEntry(
                id: UUID(),
                title: "Small models, capable computers",
                kind: .paper,
                content: """
                # Working thesis

                Small edge-device models may become more useful computer operators when the surrounding product supplies structured perception, bounded actions, persistent context, and clear recovery paths.

                ## Questions to answer

                - Which tasks become reliable with tool constraints and iterative verification?
                - Where does model size still create a hard ceiling?
                - How do latency, token use, memory, and intervention rate compare with hosted systems?

                ## Evidence standard

                Separate locally measured results from cited benchmark figures. Record the task definition, hardware, model, prompt, outcome, and failure mode for every run. Comparisons should explain differences in environment and evaluation protocol rather than treating unlike scores as interchangeable.

                ## Draft outline

                1. Motivation and research question
                2. LocalPilot system design
                3. Evaluation protocol
                4. Results and benchmark context
                5. Failure analysis
                6. Limitations and next work
                """,
                createdAt: now,
                updatedAt: now
            ),
            ResearchEntry(
                id: UUID(),
                title: "Engineering work log",
                kind: .workLog,
                content: """
                # Engineering work log

                Use **Capture latest run** to append completed LocalPilot tasks here, or add manual updates with this structure:

                ## Update
                - **Changed:**
                - **Reason:**
                - **Evidence:**
                - **Next:**
                """,
                createdAt: now.addingTimeInterval(-60),
                updatedAt: now.addingTimeInterval(-60)
            ),
            ResearchEntry(
                id: UUID(),
                title: "Benchmark protocol",
                kind: .results,
                content: """
                # Benchmark protocol

                ## Local run checklist

                - Freeze the model, quantization, context limit, and sampling settings.
                - Record device, memory pressure, task definition, and starting state.
                - Define success before the run begins.
                - Keep retries, human interventions, and partial completions visible.
                - Repeat enough times to show variance, not only a best case.

                ## Comparison rules

                External results require a source and should only share a table with local results when the task, environment, and scoring method are comparable. Otherwise, use them as context and state the limitation directly.
                """,
                createdAt: now.addingTimeInterval(-120),
                updatedAt: now.addingTimeInterval(-120)
            ),
        ]
    }

    private static func defaultTitle(for kind: ResearchEntryKind) -> String {
        switch kind {
        case .note: "Untitled research note"
        case .workLog: "Engineering work log"
        case .paper: "Untitled paper draft"
        case .results: "Untitled results log"
        }
    }

    private static func template(for kind: ResearchEntryKind) -> String {
        switch kind {
        case .note:
            "# Research note\n\n## Observation\n\n## Why it matters\n\n## Follow-up"
        case .workLog:
            "# Engineering work log\n\n## Update\n- **Changed:**\n- **Reason:**\n- **Evidence:**\n- **Next:**"
        case .paper:
            "# Working thesis\n\n## Introduction\n\n## Method\n\n## Results\n\n## Limitations"
        case .results:
            "# Results log\n\n## Setup\n\n## Observations\n\n## Interpretation\n\n## Limitations"
        }
    }
}

private extension JSONDecoder {
    static var research: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var research: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension String {
    var markdownCell: String {
        replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

private extension Optional where Wrapped == Double {
    var displaySeconds: String {
        map { String(format: "%.1fs", $0) } ?? "—"
    }
}

private extension Optional where Wrapped == Int {
    var displayCount: String {
        map(String.init) ?? "—"
    }
}
