import Foundation
import XCTest
@testable import LocalPilotDesktop

@MainActor
final class ResearchStoreTests: XCTestCase {
    func testEntriesAndExperimentsPersistLocally() throws {
        let fileURL = temporaryFileURL()
        let store = ResearchStore(fileURL: fileURL)
        let entryID = store.createEntry(kind: .note)
        store.updateTitle("Edge model observation", for: entryID)
        store.updateContent("Structured actions reduced retries.", for: entryID)
        store.addExperiment(
            ResearchExperiment(
                id: UUID(),
                kind: .local,
                method: "Qwen 3B",
                device: "Test Mac",
                task: "Organize a folder",
                outcome: .success,
                successRate: nil,
                latencySeconds: 12.4,
                tokenCount: 820,
                notes: "No intervention",
                source: "Local measurement",
                createdAt: .now
            )
        )

        let reloaded = ResearchStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.entry(id: entryID)?.title, "Edge model observation")
        XCTAssertEqual(reloaded.entry(id: entryID)?.content, "Structured actions reduced retries.")
        XCTAssertEqual(reloaded.experiments.count, 1)
        XCTAssertEqual(reloaded.benchmarkComparisons.first?.method, "LocalPilot / Qwen 3B")
        XCTAssertEqual(reloaded.benchmarkComparisons.first?.success, "100%")
    }

    func testMarkdownExportSeparatesEntriesAndExperimentLedger() {
        let store = ResearchStore(fileURL: temporaryFileURL())
        store.addExperiment(
            ResearchExperiment(
                id: UUID(),
                kind: .cited,
                method: "OSWorld baseline",
                device: "Reported setup",
                task: "Published benchmark",
                outcome: nil,
                successRate: 42.5,
                latencySeconds: nil,
                tokenCount: nil,
                notes: "",
                source: "https://example.com/paper",
                createdAt: .now
            )
        )

        let markdown = store.exportMarkdown()

        XCTAssertTrue(markdown.contains("# LocalPilot research workspace"))
        XCTAssertTrue(markdown.contains("# Experiment ledger"))
        XCTAssertTrue(markdown.contains("OSWorld baseline"))
        XCTAssertTrue(markdown.contains("42.5%"))
        XCTAssertTrue(markdown.contains("https://example.com/paper"))
    }

    func testLatestRunCanOnlyBeCapturedOnce() throws {
        let store = ResearchStore(fileURL: temporaryFileURL())
        let logURL = temporaryFileURL(extension: "jsonl")
        let taskID = UUID()
        let events = [
            LocalEvent(
                timestamp: Date(timeIntervalSince1970: 100),
                taskID: taskID,
                event: "task_started",
                status: .running,
                detail: "Open the downloads folder",
                currentAction: "Starting"
            ),
            LocalEvent(
                timestamp: Date(timeIntervalSince1970: 101),
                taskID: taskID,
                event: "executor_result",
                status: .running,
                detail: "Opened Finder",
                currentAction: "Opening Finder"
            ),
            LocalEvent(
                timestamp: Date(timeIntervalSince1970: 102),
                taskID: taskID,
                event: "task_done",
                status: .done,
                detail: "Downloads is open",
                currentAction: "Done"
            ),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try events
            .map { try encoder.encode($0) + Data([0x0A]) }
            .reduce(into: Data()) { $0.append($1) }
        try data.write(to: logURL)

        let firstCapture = store.captureLatestRun(from: logURL)
        let secondCapture = store.captureLatestRun(from: logURL)

        XCTAssertNotNil(firstCapture)
        XCTAssertNil(secondCapture)
        XCTAssertTrue(store.entry(id: firstCapture)?.content.contains("Downloads is open") == true)
    }

    private func temporaryFileURL(extension pathExtension: String = "json") -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "LocalPilotResearchTests-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }
}
