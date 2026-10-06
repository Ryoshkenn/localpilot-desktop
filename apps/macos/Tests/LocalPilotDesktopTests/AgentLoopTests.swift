import Foundation
import Testing
@testable import LocalPilotDesktop

/// Executor that parks on the first action of a given type until released,
/// so a test can interact with the controller mid-step.
actor GatedExecutor: ActionExecutor {
    private let inner: LocalPilotActionExecutor
    private let gatedType: ActionType
    private var gate: CheckedContinuation<Void, Never>?
    private var didGate = false
    private(set) var isParked = false

    init(inner: LocalPilotActionExecutor, gatedType: ActionType) {
        self.inner = inner
        self.gatedType = gatedType
    }

    func execute(_ action: StructuredAction) async -> String {
        if action.type == gatedType, !didGate {
            didGate = true
            isParked = true
            await withCheckedContinuation { gate = $0 }
            isParked = false
        }
        return await inner.execute(action)
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func prepareForRun(dryRun: Bool) async { await inner.prepareForRun(dryRun: dryRun) }
    func stopImmediately() async { await inner.stopImmediately() }
    func setPaused(_ paused: Bool) async { await inner.setPaused(paused) }
}

@MainActor
struct AgentLoopTests {
    private func makeController(
        dryRun: Bool,
        executor: (any ActionExecutor)? = nil,
        spy: SpyComputerController = SpyComputerController()
    ) throws -> AgentController {
        let store = SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "localpilot-loop-settings-\(UUID().uuidString).json"))
        var settings = AppSettings.defaultValue
        settings.dryRunExecutionOnly = dryRun
        try store.save(settings)
        let observer = StubScreenObserver(observation: ScreenObservation(
            activeApp: "Notes",
            activeWindow: "Scratch",
            screenshotWidth: 1200,
            screenshotHeight: 800,
            screenshotPNGBase64: nil,
            accessibilitySummary: nil
        ))
        return AgentController(
            logger: LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "localpilot-loop-\(UUID().uuidString).jsonl")),
            settingsStore: store,
            screenObserver: observer,
            executor: executor ?? LocalPilotActionExecutor(screenObserver: observer, computerController: spy, dryRun: true)
        )
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test
    func dryRunSettingKeepsOSControlOff() async throws {
        let spy = SpyComputerController()
        let controller = try makeController(dryRun: true, spy: spy)

        controller.start(task: "Scroll down")
        await waitUntil { controller.runStatus == .done }

        #expect(controller.runStatus == .done)
        #expect(controller.runIsDryRun)
        #expect(await spy.scrolls.isEmpty)
        #expect(controller.messages.contains { $0.action == .scroll })
        #expect(controller.messages.last?.outcome == .done)
    }

    @Test
    func disablingDryRunReachesTheExecutor() async throws {
        let spy = SpyComputerController()
        let controller = try makeController(dryRun: false, spy: spy)

        controller.start(task: "Scroll down")
        await waitUntil { controller.runStatus == .done }

        #expect(controller.runStatus == .done)
        #expect(await spy.scrolls == [-5])
    }

    @Test
    func stopDoesNotBreakTheNextRun() async throws {
        let spy = SpyComputerController()
        let controller = try makeController(dryRun: false, spy: spy)

        controller.start(task: "Scroll down")
        controller.stop()
        #expect(controller.runStatus == .stopped)

        controller.start(task: "Scroll down")
        await waitUntil { controller.runStatus == .done }

        #expect(controller.runStatus == .done)
        #expect(await spy.scrolls == [-5])
    }

    @Test
    func pausingMidStepThenContinuingFinishesTheTask() async throws {
        let spy = SpyComputerController()
        let observer = StubScreenObserver(observation: ScreenObservation(
            activeApp: "Notes", activeWindow: nil, screenshotWidth: nil, screenshotHeight: nil,
            screenshotPNGBase64: nil, accessibilitySummary: nil
        ))
        let gated = GatedExecutor(
            inner: LocalPilotActionExecutor(screenObserver: observer, computerController: spy, dryRun: true),
            gatedType: .scroll
        )
        let controller = try makeController(dryRun: false, executor: gated)

        controller.start(task: "Scroll down")
        await waitUntil { await gated.isParked }
        controller.pause()
        await gated.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.runStatus == .paused)

        controller.continueTask(instruction: "carry on")
        await waitUntil { controller.runStatus == .done }

        #expect(controller.runStatus == .done)
        #expect(controller.continueInstructions == ["carry on"])
    }

    @Test
    func websitesOpenWithoutAskingForApproval() async throws {
        let controller = try makeController(dryRun: true)

        controller.start(task: "Open https://example.com")
        await waitUntil { controller.runStatus == .done }

        #expect(controller.runStatus == .done)
        #expect(controller.pendingApproval == nil)
        #expect(controller.messages.contains { $0.action == .openURL })
    }

    @Test
    func localServerModelDrivesTheLoop() async throws {
        let client = MockHTTPClient()
        await client.route("http://127.0.0.1:1234/v1/models", HTTPResponse(data: Data(#"{"data":[{"id":"qwen3.5-4b"}]}"#.utf8), statusCode: 200))
        let finish = #"{"choices":[{"message":{"content":"<think>done already</think>{\"actions\":[{\"type\":\"finish\",\"target_kind\":\"task\",\"target_text\":\"task\",\"expected_result\":\"done\",\"risk_level\":\"low\",\"reason\":\"nothing to do\"}]}"}}]}"#
        await client.enqueue(HTTPResponse(data: Data(finish.utf8), statusCode: 200))

        let store = SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "localpilot-server-\(UUID().uuidString).json"))
        let controller = AgentController(
            logger: LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "localpilot-server-\(UUID().uuidString).jsonl")),
            settingsStore: store,
            screenObserver: StubScreenObserver(observation: ScreenObservation(
                activeApp: "Notes", activeWindow: nil, screenshotWidth: nil, screenshotHeight: nil,
                screenshotPNGBase64: nil, accessibilitySummary: nil
            )),
            httpClient: client
        )
        controller.settings.toolCallingMode = .jsonCompatibility
        controller.selectModel("qwen3.5-4b", on: LocalModelServer(name: "LM Studio", baseURL: URL(string: "http://127.0.0.1:1234/v1")!, models: ["qwen3.5-4b"]))
        #expect(try store.load().plannerModel == "qwen3.5-4b")

        controller.start(task: "Tidy up")
        await waitUntil { controller.runStatus == .done }

        #expect(controller.runStatus == .done)
        #expect(controller.modelStatus == .ready)
        let chat = try #require(await client.requests.last?.jsonBody)
        #expect(chat["model"] as? String == "qwen3.5-4b")
    }

    @Test
    func unreachableServerBlocksWithAClearReason() async throws {
        let store = SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "localpilot-server-\(UUID().uuidString).json"))
        let controller = AgentController(
            logger: LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "localpilot-server-\(UUID().uuidString).jsonl")),
            settingsStore: store,
            screenObserver: StubScreenObserver(observation: ScreenObservation(
                activeApp: nil, activeWindow: nil, screenshotWidth: nil, screenshotHeight: nil,
                screenshotPNGBase64: nil, accessibilitySummary: nil
            )),
            httpClient: MockHTTPClient()
        )
        controller.settings.toolCallingMode = .jsonCompatibility
        controller.selectModel("qwen3.5-4b", on: LocalModelServer(name: "LM Studio", baseURL: URL(string: "http://127.0.0.1:1234/v1")!, models: ["qwen3.5-4b"]))

        controller.start(task: "Tidy up")
        await waitUntil { controller.runStatus == .blocked }

        #expect(controller.runStatus == .blocked)
        guard case .unavailable = controller.modelStatus else {
            Issue.record("Expected the model to be marked unavailable, got \(controller.modelStatus)")
            return
        }
    }

    @Test
    func newConversationResetsTranscript() async throws {
        let controller = try makeController(dryRun: true)
        controller.start(task: "Scroll down")
        await waitUntil { controller.runStatus == .done }

        controller.newConversation()

        #expect(controller.runStatus == .idle)
        #expect(controller.messages.isEmpty)
        #expect(controller.stepCount == 0)
    }
}

struct ExecutorLifecycleTests {
    private let click = StructuredAction(
        type: .click, targetKind: "point", targetText: "Search",
        coordinates: [10, 20], expectedResult: "clicked", riskLevel: .low, reason: "test"
    )

    @Test
    func stopIsStickyUntilPreparedForANewRun() async {
        let spy = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: spy, dryRun: false)

        await executor.stopImmediately()
        await executor.setPaused(false)
        #expect(await executor.execute(click) == "Executor disabled.")

        await executor.prepareForRun(dryRun: false)
        #expect(await executor.execute(click) == "Clicked Search at 10,20.")
        #expect(await spy.clicks == [CGPoint(x: 10, y: 20)])
    }

    @Test
    func prepareForRunAppliesDryRun() async {
        let spy = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: spy, dryRun: false)

        await executor.prepareForRun(dryRun: true)
        let result = await executor.execute(click)

        #expect(result.hasPrefix("Dry-run only"))
        #expect(await spy.clicks.isEmpty)
    }

    @Test
    func unsupportedKeyIsBlockedInsteadOfReportedAsPressed() async {
        let spy = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: spy, dryRun: false)

        let result = await executor.execute(StructuredAction(
            type: .pressKey, targetKind: "keyboard", targetText: "f13", text: "f13",
            expectedResult: "pressed", riskLevel: .low, reason: "test"
        ))

        #expect(result == "Key press blocked: unsupported key f13.")
        #expect(await spy.keys.isEmpty)
    }
}

struct QuartzControllerProcessTests {
    @Test
    func largeTerminalOutputDoesNotDeadlock() async {
        let controller = QuartzComputerController()
        // ~200KB of output: far past the pipe buffer that used to deadlock.
        let result = await controller.runTerminalCommand("head -c 200000 /dev/zero | tr '\\0' a")
        #expect(result.count == QuartzComputerController.terminalOutputLimit)
        #expect(result.allSatisfy { $0 == "a" })
    }

    @Test
    func nonZeroExitIsReported() async {
        let controller = QuartzComputerController()
        let result = await controller.runTerminalCommand("echo nope >&2; exit 3")
        #expect(result == "exit 3: nope")
    }

    @Test
    func appNameIsNeverInterpretedByAShell() async {
        let marker = URL.temporaryDirectory.appending(path: "localpilot-injection-\(UUID().uuidString)")
        let controller = QuartzComputerController()

        let switched = await controller.switchApp(named: "$(touch \(marker.path))")

        #expect(switched == false)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

/// Records every prompt it receives and replies with a fixed action.
actor PromptRecordingProvider: LocalModelProvider {
    let configuration = ModelProviderConfiguration(
        providerName: "recording", modelName: "recording", temperature: 0, timeoutSeconds: 1
    )
    private(set) var prompts: [String] = []

    func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        prompts.append(prompt)
        return #"{"type":"finish","target_kind":"task","target_text":"task","expected_result":"done","risk_level":"low","reason":"done"}"#
    }

    func healthCheck() async throws {}
    func cancel() async {}
}

struct PlannerPromptTests {
    @Test
    func continueInstructionsReachThePlanner() async throws {
        let provider = PromptRecordingProvider()
        let planner = JSONActionPlanner(provider: provider)

        _ = try await planner.proposeActions(
            originalTask: "Tidy the desktop",
            context: .empty,
            recentMessages: [
                ChatMessage(role: .user, text: "Tidy the desktop"),
                ChatMessage(role: .agent, text: "Working on it"),
                ChatMessage(role: .user, text: "Skip the screenshots folder"),
            ]
        )

        let prompt = try #require(await provider.prompts.first)
        #expect(prompt.contains("user: Skip the screenshots folder"))
        #expect(!prompt.contains("- Tidy the desktop"))
        #expect(prompt.contains("agent: Working on it"))
    }
}

struct LocalEventLogReaderTests {
    private func event(_ name: String, _ detail: String = "", task: UUID?, at seconds: TimeInterval) -> LocalEvent {
        LocalEvent(
            timestamp: Date(timeIntervalSince1970: seconds),
            taskID: task,
            event: name,
            status: .running,
            detail: detail,
            currentAction: ""
        )
    }

    @Test
    func summariesRebuildTaskOutcomes() {
        let first = UUID()
        let second = UUID()
        let summaries = LocalEventLogReader.summarize([
            event("task_started", "Open docs", task: first, at: 1),
            event("executor_result", task: first, at: 2),
            event("executor_result", task: first, at: 3),
            event("task_done", "Finished", task: first, at: 4),
            event("task_started", "Run tests", task: second, at: 10),
            event("approval_denied", task: second, at: 11),
            event("settings_saved", task: nil, at: 12),
        ])

        #expect(summaries.map(\.task) == ["Run tests", "Open docs"])
        #expect(summaries[0].outcome == .blocked)
        #expect(summaries[1].outcome == .done)
        #expect(summaries[1].stepCount == 2)
    }

    @Test
    func tailReadSkipsPartialFirstLineAndBadLines() async throws {
        let url = URL.temporaryDirectory.appending(path: "localpilot-reader-\(UUID().uuidString).jsonl")
        let logger = LocalEventLogger(fileURL: url)
        for index in 0..<50 {
            await logger.log(event("executor_result", "step \(index)", task: nil, at: TimeInterval(index)))
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()

        let reader = LocalEventLogReader(fileURL: url)
        let all = reader.recentEvents(limit: 1_000)
        #expect(all.count == 50)
        #expect(all.last?.detail == "step 49")

        // Force a tail read that starts mid-file.
        let tail = reader.recentEvents(limit: 1_000, maxBytes: 600)
        #expect(!tail.isEmpty)
        #expect(tail.count < 50)
        #expect(tail.last?.detail == "step 49")
    }
}
