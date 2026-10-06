import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class AgentController {
    public private(set) var runStatus: AgentRunStatus = .idle
    public private(set) var overlayState: OverlayState = .idle
    public private(set) var executorEnabled = false
    public private(set) var currentActionLabel = "Idle"
    /// Screenshots the model took, keyed by step, so the transcript can show
    /// what it saw. Kept in memory only; saved chats don't store images.
    public private(set) var stepScreenshots: [UUID: ScreenshotAttachment] = [:]
    public private(set) var messages: [ChatMessage] = [] {
        didSet { persistConversation() }
    }
    /// What the model or executor is doing right now; `nil` when nothing is in flight.
    public private(set) var liveActivity: LiveActivity?
    /// Text streamed so far for the in-flight model request.
    public private(set) var liveGeneration: LiveGeneration?
    /// Tokens the model has generated in the current run (streamed chunks).
    public private(set) var runGeneratedTokens = 0
    /// The chat being shown. `nil` until the first message of a new chat.
    public private(set) var conversationID: UUID?
    /// Bumped whenever a conversation is written, so lists can refresh.
    public private(set) var conversationsRevision = 0
    /// Newest-first executor results for the current run.
    public private(set) var recentLogSnippets: [String] = []
    public private(set) var continueInstructions: [String] = []
    public private(set) var state = LocalPilotState.empty
    /// Number of actions executed in the current run.
    public private(set) var stepCount = 0
    /// Checklist the model created with the todo tool, if any.
    public private(set) var todo: [String] = []
    private var computerUseStarted = false
    public private(set) var runStartedAt: Date?
    public private(set) var runEndedAt: Date?
    /// Whether the current (or last) run was restricted to dry-run execution.
    public private(set) var runIsDryRun = true
    /// Persisted on every change, so controls take effect without a Save step.
    public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persistSettings()
            if settings.modelProviderMode != oldValue.modelProviderMode
                || settings.plannerModel != oldValue.plannerModel
                || settings.serverBaseURL != oldValue.serverBaseURL {
                modelStatus = .unknown
            }
        }
    }
    public private(set) var settingsError: String?
    public private(set) var modelStatus: ModelStatus = .unknown
    /// Local model servers found by the last discovery pass.
    public private(set) var localServers: [LocalModelServer] = []
    public private(set) var isDiscoveringModels = false
    public private(set) var pendingApproval: PendingApproval?
    /// A question the model asked; the run is paused until the user answers.
    public private(set) var pendingQuestion: String?

    @ObservationIgnored private let logger: LocalEventLogger
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let policyEngine = DeterministicPolicyEngine()
    @ObservationIgnored private let executor: any ActionExecutor
    @ObservationIgnored private let contextBuilder: AgentContextBuilder
    @ObservationIgnored private let useModelLoop: Bool
    @ObservationIgnored private let httpClient: HTTPClient
    @ObservationIgnored private var actionLoop: Task<Void, Never>?
    @ObservationIgnored private var activeTaskID: UUID?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var history = AgentHistory()
    /// Serializes executor control messages (prepare, pause, stop) so a late
    /// message from a previous run can never overtake a newer one.
    @ObservationIgnored private var executorControl: Task<Void, Never>?
    /// Serializes log writes so events land in the file in the order they happened.
    @ObservationIgnored private var logWrites: Task<Void, Never>?
    @ObservationIgnored public let conversationStore: ConversationStore
    @ObservationIgnored private var conversationTitle = ""
    @ObservationIgnored private var conversationCreatedAt = Date()
    @ObservationIgnored private var conversationTaskIDs: [UUID] = []
    /// Serializes conversation writes so an older snapshot never lands last.
    @ObservationIgnored private var conversationWrites: Task<Void, Never>?
    /// Identifies the in-flight model request; stale streaming updates are dropped.
    @ObservationIgnored private var generationSerial = 0
    /// Measured prefill speed (prompt tokens per second) per model, used to
    /// predict prefill progress for the next request.
    @ObservationIgnored private var prefillRates: [String: Double] = [:]
    static let assumedPrefillTokensPerSecond = 600.0

    public init(
        logger: LocalEventLogger = LocalEventLogger(),
        settingsStore: SettingsStore = SettingsStore(),
        screenObserver: any ScreenObserving = LiveScreenObserver(),
        executor: (any ActionExecutor)? = nil,
        httpClient: HTTPClient = URLSessionHTTPClient(),
        conversationStore: ConversationStore? = nil,
        useModelLoop: Bool = true
    ) {
        self.logger = logger
        // Chats live next to the log by default, so a test logger in a temp
        // directory also keeps its chats there.
        self.conversationStore = conversationStore ?? ConversationStore(
            directory: logger.logFileURL.deletingLastPathComponent().appending(path: "conversations", directoryHint: .isDirectory)
        )
        self.settingsStore = settingsStore
        self.contextBuilder = AgentContextBuilder(screenObserver: screenObserver)
        self.executor = executor ?? LocalPilotActionExecutor(screenObserver: screenObserver)
        self.httpClient = httpClient
        self.useModelLoop = useModelLoop
        self.settings = (try? settingsStore.load()) ?? .defaultValue
        // Built-in rules are always available; servers are checked on discovery.
        self.modelStatus = settings.modelProviderMode == .builtIn ? .ready : .unknown
    }

    public var logFileURL: URL {
        logger.logFileURL
    }

    public func start(task rawTask: String) {
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }

        stopLoopOnly()

        let taskID = UUID()
        activeTaskID = taskID
        if conversationID == nil {
            conversationID = UUID()
            conversationTitle = Conversation.title(for: task)
            conversationCreatedAt = Date()
            conversationTaskIDs = []
        }
        conversationTaskIDs.append(taskID)
        history = AgentHistory()
        continueInstructions = []
        state = LocalPilotState.empty
        state.taskID = taskID
        state.originalTask = task
        state.status = .running
        stepCount = 0
        runGeneratedTokens = 0
        todo = []
        computerUseStarted = false
        runStartedAt = Date()
        runIsDryRun = settings.dryRunExecutionOnly

        messages.append(ChatMessage(role: .user, text: task))
        recentLogSnippets = []
        runEndedAt = nil
        runStatus = .running
        overlayState = .idle
        executorEnabled = false
        setActivity(.generating(.prefilling))
        PointerIndicator.shared.hide()

        log(event: "task_started", detail: task)
        if useModelLoop {
            let dryRun = runIsDryRun
            let prepared = sendToExecutor { await $0.prepareForRun(dryRun: dryRun) }
            actionLoop = Task { [weak self] in
                await prepared.value
                await self?.runAgentLoop(task: task, runID: taskID)
            }
        }
    }

    public func pause() {
        guard runStatus == .running else { return }
        runStatus = .paused
        overlayState = .paused
        executorEnabled = false
        sendToExecutor { await $0.setPaused(true) }
        currentActionLabel = "Paused"
        liveActivity = nil
        liveGeneration = nil
        state.status = .paused
        log(event: "task_paused", detail: "Paused by user")
    }

    public func continueTask(instruction rawInstruction: String) {
        // While an approval is pending the loop is parked on that decision;
        // resuming here would leave it waiting with the UI claiming "running".
        guard runStatus == .paused, pendingApproval == nil else { return }
        let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            continueInstructions.append(instruction)
            messages.append(ChatMessage(role: .user, text: instruction))
        }

        pendingQuestion = nil
        runStatus = .running
        overlayState = .running
        executorEnabled = true
        sendToExecutor { await $0.setPaused(false) }
        currentActionLabel = "Resuming"
        liveActivity = .generating(.prefilling)
        state.status = .running
        log(event: "task_continued", detail: instruction.isEmpty ? "No extra instruction" : instruction)
    }

    public func stop() {
        guard runStatus.isActive else { return }
        runStatus = .stopped
        overlayState = .idle
        executorEnabled = false
        currentActionLabel = "Stopped"
        liveActivity = nil
        liveGeneration = nil
        PointerIndicator.shared.hide()
        state.status = .stopped
        runEndedAt = Date()
        stopLoopOnly()
        sendToExecutor { await $0.stopImmediately() }
        messages.append(ChatMessage(role: .agent, text: "Stopped. The executor is disabled and no queued actions remain.", outcome: .stopped))
        log(event: "task_stopped", detail: "Hard stop by user")
    }

    /// Stop anything in flight and clear the conversation.
    public func newConversation() {
        stop()
        conversationID = nil
        conversationTaskIDs = []
        resetTranscript(to: [])
    }

    /// Show a saved chat so it can be read or continued.
    public func openConversation(id: UUID) {
        guard id != conversationID else { return }
        guard let conversation = conversationStore.load(id: id) else { return }
        stop()
        conversationID = conversation.id
        conversationTitle = conversation.title
        conversationCreatedAt = conversation.createdAt
        conversationTaskIDs = conversation.taskIDs
        resetTranscript(to: conversation.messages)
    }

    public func deleteConversation(id: UUID) {
        if id == conversationID { newConversation() }
        let store = conversationStore
        let previous = conversationWrites
        conversationWrites = Task.detached {
            await previous?.value
            store.delete(id: id)
        }
        Task { [weak self] in
            await self?.conversationWrites?.value
            self?.conversationsRevision += 1
        }
    }

    private func resetTranscript(to transcript: [ChatMessage]) {
        messages = transcript
        stepScreenshots = [:]
        todo = []
        computerUseStarted = false
        recentLogSnippets = []
        runEndedAt = nil
        runStatus = .idle
        currentActionLabel = "Idle"
        liveActivity = nil
        liveGeneration = nil
        pendingQuestion = nil
        state = .empty
        stepCount = 0
        runStartedAt = nil
        PointerIndicator.shared.hide()
    }

    private func stopLoopOnly() {
        actionLoop?.cancel()
        actionLoop = nil
        pendingApproval = nil
        pendingQuestion = nil
        resolveApproval(false)
    }

    public func approvePendingAction() {
        guard let approval = pendingApproval else { return }
        let approvalActionType: ActionType? = approval.action.type
        pendingApproval = nil
        runStatus = .running
        overlayState = .running
        executorEnabled = true
        state.userApprovals.append(currentActionLabel)
        liveActivity = .running(approvalActionType ?? .observe)
        log(event: "approval_allowed", detail: "User allowed action once")
        resolveApproval(true)
    }

    public func denyPendingAction() {
        guard let approval = pendingApproval else { return }
        pendingApproval = nil
        runStatus = .blocked
        overlayState = .idle
        executorEnabled = false
        currentActionLabel = "Blocked"
        liveActivity = nil
        liveGeneration = nil
        PointerIndicator.shared.hide()
        state.status = .blocked
        runEndedAt = Date()
        state.deniedActions.append(approval.action)
        setResult(for: approval.action.id, "Denied by you")
        messages.append(ChatMessage(role: .agent, text: "You denied the step, so the task stopped here.", outcome: .blocked))
        log(event: "approval_denied", detail: "User denied action")
        resolveApproval(false)
    }

    private func persistSettings() {
        do {
            try settingsStore.save(settings)
            settingsError = nil
        } catch {
            settingsError = "Couldn't save settings: \(error.localizedDescription)"
        }
    }

    // MARK: - Models

    /// Probe the usual local server ports (plus the configured address) and
    /// refresh `localServers`.
    public func refreshLocalModels() {
        guard !isDiscoveringModels else { return }
        isDiscoveringModels = true
        let extra = settings.serverURL.map { [$0] } ?? []
        let httpClient = httpClient
        Task {
            let servers = await LocalModelDiscovery.discover(extra: extra, httpClient: httpClient)
            localServers = servers
            isDiscoveringModels = false
            if settings.modelProviderMode == .localServer {
                let selectedIsServed = servers.contains { $0.baseURL == settings.serverURL && $0.models.contains(settings.plannerModel) }
                modelStatus = selectedIsServed ? .ready : .unavailable("Not currently served. Load it in your model server or pick another.")
            }
            log(event: "models_discovered", detail: servers.map { "\($0.name): \($0.models.count)" }.joined(separator: ", "))
        }
    }

    public func selectBuiltInRules() {
        settings.modelProviderMode = .builtIn
        modelStatus = .ready
    }

    public func selectModel(_ model: String, on server: LocalModelServer) {
        settings.serverBaseURL = server.baseURL.absoluteString
        settings.plannerModel = model
        settings.modelProviderMode = .localServer
        modelStatus = .ready
    }

    /// Verify the selected model answers, updating `modelStatus`.
    public func checkModelConnection() {
        let provider: any LocalModelProvider
        do {
            provider = try makePlannerProvider(settings: settings)
        } catch {
            modelStatus = .unavailable(error.localizedDescription)
            return
        }
        modelStatus = .checking
        Task {
            do {
                try await provider.healthCheck()
                modelStatus = .ready
            } catch {
                modelStatus = .unavailable(error.localizedDescription)
            }
        }
    }

    // MARK: - Loop

    /// Outcome of a safe-boundary check inside the loop.
    private enum Checkpoint {
        case proceed
        /// The user paused and resumed; the screen may have changed, so the
        /// remaining plan is stale and must be re-planned from a fresh observation.
        case resumedAfterPause
        case exit
    }

    /// True while `runID` is still the run the user is looking at.
    private func isCurrent(_ runID: UUID) -> Bool {
        activeTaskID == runID && !Task.isCancelled
    }

    private func checkpoint(_ runID: UUID) async -> Checkpoint {
        guard isCurrent(runID) else { return .exit }
        var didPause = false
        while runStatus == .paused, isCurrent(runID) {
            didPause = true
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return .exit
            }
        }
        guard isCurrent(runID), runStatus == .running else { return .exit }
        return didPause ? .resumedAfterPause : .proceed
    }

    private func runAgentLoop(task: String, runID: UUID) async {
        let compactor = ContextCompactor(config: ContextCompactionConfig(
            contextWindowTokens: max(1, settings.contextWindowSize),
            compactionThreshold: ContextCompactionConfig.defaultValue.compactionThreshold,
            rawTailRatio: ContextCompactionConfig.defaultValue.rawTailRatio
        ))

        do {
            let plannerProvider = try makePlannerProvider(settings: settings)
            let planner = JSONActionPlanner(provider: plannerProvider, structuredOutput: settings.useStructuredDecoding)
            let nativeSession = settings.modelProviderMode == .localServer && settings.toolCallingMode == .native
                ? NativeToolSession(provider: plannerProvider, conversation: messages, dryRun: runIsDryRun) : nil
            setActivity(.connecting(model: settings.activeModelLabel))
            modelStatus = .checking
            try await plannerProvider.healthCheck()
            guard isCurrent(runID) else { return }
            modelStatus = .ready

            let maxPlan = 6
            // Harness recovery state (see `HarnessLimits`).
            var consecutiveCorrections = 0
            var lastSignature: String?
            var repeatCount = 0
            var needsObservation = false
            var wantsScreenshot: ScreenshotArea?
            var latestScreenshot: ScreenshotAttachment?

            planningRounds: while stepCount < HarnessLimits.maxStepsPerRun {
                guard await checkpoint(runID) != .exit else { return }

                if needsObservation { setActivity(.observing) }
                // Native tool calling works from pictures: after anything that
                // changes the screen, the model gets a fresh screenshot of the
                // window rather than a text dump of it.
                let autoPicture: ScreenshotArea? = nativeSession != nil ? .window : nil
                var context = needsObservation
                    ? await observe(task: task, screenshot: wantsScreenshot ?? autoPicture, visual: nativeSession != nil)
                    : .empty
                if !needsObservation {
                    context.visibleText = ([history.compactedSummary] + history.recentSteps).filter { !$0.isEmpty }.joined(separator: "\n")
                }
                wantsScreenshot = nil
                if let shot = context.screenshot { latestScreenshot = shot }
                guard isCurrent(runID) else { return }
                if compactor.shouldCompact(estimatedTokens: compactor.estimateTokens(context.visibleText)) {
                    log(event: "context_compacted", detail: "Context kept lean: rolling summary plus recent step tail.")
                }

                setActivity(.generating(.prefilling))
                log(event: "planning", detail: "Requesting next action plan")
                generationSerial += 1
                let serial = generationSerial
                liveGeneration = LiveGeneration()
                let response: ActionPlan
                if let nativeSession {
                    response = try await nativeSession.next(context: context, conversation: messages) { [weak self] event in
                        Task { @MainActor in self?.applyGeneration(event, serial: serial) }
                    }
                } else {
                    response = try await proposePlan(planner: planner, task: task, context: context, maxPlan: maxPlan)
                }
                generationSerial += 1
                liveGeneration = nil
                if let reasoning = nativeSession?.lastReasoning, !reasoning.isEmpty, isCurrent(runID) {
                    messages.append(ChatMessage(role: .agent, text: "Thought", detail: reasoning, isThought: true))
                }
                guard await checkpoint(runID) == .proceed else {
                    if isCurrent(runID), runStatus == .running { continue planningRounds }
                    return
                }
                if let preamble = nativeSession?.preamble?.trimmingCharacters(in: .whitespacesAndNewlines), !preamble.isEmpty {
                    messages.append(ChatMessage(role: .agent, text: preamble))
                }
                if let checklist = response.todo {
                    todo = checklist
                    messages.append(ChatMessage(
                        role: .system,
                        text: "Updated checklist",
                        detail: checklist.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                    ))
                    nativeSession?.completeChecklist()
                    if nativeSession != nil { stepCount += 1 }
                }
                let plan = response.actions
                if plan.isEmpty, let reply = response.reply {
                    completeTask(message: reply)
                    return
                }
                if plan.count > 1 {
                    log(event: "plan_proposed", detail: "Planner proposed \(plan.count) actions; each is gated and executed one at a time.")
                }

                // Execute the planned actions one at a time. Each is independently
                // re-validated and remains interruptible; we re-observe between
                // steps and abandon the rest of the plan to re-plan if a step
                // fails, the user pauses, or the screen no longer matches.
                for (index, proposed) in plan.enumerated() {
                    guard stepCount < HarnessLimits.maxStepsPerRun else { break planningRounds }
                    switch await checkpoint(runID) {
                    case .exit: return
                    case .resumedAfterPause: continue planningRounds
                    case .proceed: break
                    }

                    if index > 0, proposed.targetElementID != nil {
                        history.record("Replan element actions from a fresh observation after the previous UI action.", compactor: compactor, maxRecent: 4)
                        continue planningRounds
                    }
                    if index > 0 {
                        setActivity(.observing)
                        context = await observe(task: task)
                        guard isCurrent(runID) else { return }
                    }

                    // An element action on the first turn needs an observation,
                    // not a guessed id. Never execute it against an unseen tree.
                    if proposed.targetElementID != nil, context.elements.isEmpty {
                        needsObservation = true
                        if !computerUseStarted { computerUseStarted = true; overlayState = .running }
                    }
                    // Malformed actions go back to the planner as feedback rather
                    // than ending the task; small models often fix them on retry.
                    let action: StructuredAction
                    switch ActionValidator.validate(proposed, elements: context.elements) {
                    case .valid(let checked) where Self.hasOffScaleCoordinates(checked, basis: context.screenshot ?? latestScreenshot):
                        nativeSession?.complete(action: proposed, result: "Not executed: x and y must be between 0 and 1000 (a scale across the screenshot, not pixels).")
                        consecutiveCorrections += 1
                        messages.append(ChatMessage(role: .system, text: "Rejected an off-screen \(proposed.type.displayName.lowercased()) step", detail: callDescription(for: proposed, session: nativeSession), result: "x and y must be between 0 and 1000."))
                        guard consecutiveCorrections < HarnessLimits.maxConsecutiveCorrections else {
                            blockTask(reason: "The model gave off-screen coordinates \(HarnessLimits.maxConsecutiveCorrections) times in a row.", action: proposed)
                            return
                        }
                        continue planningRounds
                    case .valid(let checked):
                        action = checked
                        consecutiveCorrections = 0
                    case .invalid(let problem):
                        nativeSession?.complete(action: proposed, result: "Not executed: " + problem)
                        consecutiveCorrections += 1
                        log(event: "action_rejected", detail: problem)
                        history.record("Rejected \(proposed.type.rawValue) (invalid, not executed): \(problem)", compactor: compactor, maxRecent: 4)
                        messages.append(ChatMessage(
                            role: .system,
                            text: "Rejected an invalid \(proposed.type.displayName.lowercased()) step",
                            detail: callDescription(for: proposed, session: nativeSession),
                            result: problem
                        ))
                        guard consecutiveCorrections < HarnessLimits.maxConsecutiveCorrections else {
                            blockTask(reason: "The model proposed \(HarnessLimits.maxConsecutiveCorrections) invalid steps in a row. Last problem: \(problem)", action: proposed)
                            return
                        }
                        continue planningRounds
                    }

                    messages.append(ChatMessage(
                        id: action.id,
                        role: .agent,
                        text: action.summary,
                        action: action.type,
                        detail: callDescription(for: action, session: nativeSession)
                    ))
                    currentActionLabel = "Checking \(action.type.displayName.lowercased())"

                    let policy = policyEngine.classify(action: action, context: context)
                    log(event: "policy_decision", detail: "\(policy.classification.rawValue): \(policy.reason)")

                    switch policy.classification {
                    case .block:
                        blockTask(reason: policy.reason, action: action)
                        return
                    case .askUser:
                        let allowed = await requestApproval(action: action, reason: policy.reason)
                        guard allowed, isCurrent(runID) else { return }
                    case .allow:
                        break
                    }

                    // Last safe boundary before touching the computer.
                    switch await checkpoint(runID) {
                    case .exit: return
                    case .resumedAfterPause: continue planningRounds
                    case .proceed: break
                    }

                    if action.type == .askUser {
                        stepCount += 1
                        let question = action.question
                        history.record("ask_user: asked \"\(question)\". The answer, if any, is under user instructions.", compactor: compactor, maxRecent: 4)
                        askUser(question)
                        // The next checkpoint waits for the user's answer.
                        continue planningRounds
                    }

                    if action.type.touchesComputer {
                        computerUseStarted = true
                        overlayState = .running
                        executorEnabled = true
                        needsObservation = true
                    }
                    stepCount += 1
                    setActivity(.running(action.type))
                    let result: String
                    if action.type == .screenshot, let nativeSession {
                        // Native mode: the picture comes back with observe's own result.
                        let area = ScreenshotArea(rawValue: action.targetText) ?? .window
                        let shot = await contextBuilder.captureScreenshot(area: area)
                        guard isCurrent(runID) else { return }
                        result = Self.describeScreenshot(shot, area: area)
                        if let shot {
                            latestScreenshot = shot
                            stepScreenshots[action.id] = shot
                        }
                        nativeSession.complete(action: action, result: result, screenshot: shot)
                        // The model just got this picture; don't send another one.
                        needsObservation = false
                    } else {
                        // Click x/y are 0–1000 positions in the newest screenshot the model has seen.
                        let executable = (context.screenshot ?? latestScreenshot).map { action.inScreenPoints(using: $0) } ?? action
                        result = await executor.execute(executable)
                        if action.type == .screenshot { wantsScreenshot = ScreenshotArea(rawValue: action.targetText) ?? .window }
                        guard isCurrent(runID) else { return }
                        nativeSession?.complete(action: action, result: result)
                    }
                    setResult(for: action.id, result)
                    state.completedSteps.append(action.type.rawValue)
                    state.lastActionResult = result
                    history.record("\(action.type.rawValue): \(result)", compactor: compactor, maxRecent: 4)
                    recordStepResult(result)
                    log(event: "executor_result", detail: result)

                    if action.type == .finish {
                        completeTask(message: action.text ?? response.reply ?? (action.expectedResult.isEmpty ? "Done." : action.expectedResult))
                        return
                    }

                    if action.signature == lastSignature, action.type != .scroll {
                        repeatCount += 1
                    } else {
                        lastSignature = action.signature
                        repeatCount = 1
                    }
                    if repeatCount >= HarnessLimits.maxIdenticalSteps {
                        blockTask(reason: "The model repeated the same \(action.type.displayName.lowercased()) step \(repeatCount) times without making progress.", action: nil)
                        return
                    }
                    if repeatCount >= 2 {
                        history.record("Note: that exact \(action.type.rawValue) has now run \(repeatCount) times in a row. If it changed nothing, choose a different action, ask_user, or finish.", compactor: compactor, maxRecent: 4)
                        log(event: "repetition_warning", detail: "\(action.type.rawValue) repeated \(repeatCount)x")
                        continue planningRounds
                    }

                    if Self.indicatesFailure(result) {
                        log(event: "plan_aborted", detail: "Step result indicates failure; re-planning from fresh observation.")
                        continue planningRounds
                    }
                }
                if let reply = response.reply {
                    completeTask(message: runIsDryRun ? "Dry run: actions were validated without controlling your Mac.\n\n" + reply : reply)
                    return
                }
            }

            blockTask(reason: "Stopped after \(HarnessLimits.maxStepsPerRun) steps without finishing. Send another message to keep going.", action: nil)
        } catch {
            // Cancellation surfaces as CancellationError or URLError.cancelled
            // depending on where it lands. Either way, a stopped or superseded
            // run must not overwrite the state of whatever replaced it.
            guard isCurrent(runID), runStatus.isActive else { return }
            if error is ModelProviderError || error is URLError {
                modelStatus = .unavailable(error.localizedDescription)
            }
            blockTask(reason: "Model loop failed: \(error.localizedDescription)", action: nil)
        }
    }

    private func observe(task: String, screenshot: ScreenshotArea? = nil, visual: Bool = false) async -> AgentContext {
        let context = await contextBuilder.makeContext(settings: settings, task: task, history: history, screenshot: screenshot, visual: visual)
        state.lastObservationSummary = context.visibleText.components(separatedBy: "\n").last ?? ""
        log(event: "screen_observed", detail: state.lastObservationSummary)
        return context
    }

    /// Ask the planner for a plan, retrying once on malformed JSON before
    /// failing closed.
    private func proposePlan(
        planner: JSONActionPlanner,
        task: String,
        context: AgentContext,
        maxPlan: Int
    ) async throws -> ActionPlan {
        do {
            return try await planner.proposeResponse(originalTask: task, context: context, recentMessages: messages, maxActions: maxPlan)
        } catch let PlannerError.invalidOutput(preview) {
            log(event: "planner_invalid_json", detail: "Reply did not match the action schema; retrying once. Reply: \(preview)")
            return try await planner.proposeResponse(originalTask: task, context: context, recentMessages: messages, maxActions: maxPlan)
        }
    }

    /// A screenshot-relative click or type whose position is off the 0–1000 scale.
    static func hasOffScaleCoordinates(_ action: StructuredAction, basis: ScreenshotAttachment?) -> Bool {
        guard basis != nil, action.targetElementID == nil, let coordinates = action.coordinates,
              [.click, .doubleClick, .typeTextSafe].contains(action.type) else { return false }
        return !ScreenshotAttachment.isOnScale(coordinates)
    }

    static func describeScreenshot(_ shot: ScreenshotAttachment?, area: ScreenshotArea) -> String {
        guard let shot else {
            return "Screenshot unavailable: LocalPilot needs Screen Recording permission (then a relaunch). Use observe with mode \"app_state\" instead."
        }
        let subject = area == .window && shot.area == .window ? "the front window" : "the whole screen"
        return "Took a screenshot of \(subject). It is attached below; click and type_text x/y are 0-1000 across and down it."
    }

    private func askUser(_ question: String) {
        pendingQuestion = question
        messages.append(ChatMessage(role: .agent, text: question, action: .askUser))
        runStatus = .paused
        overlayState = .paused
        executorEnabled = false
        currentActionLabel = "Waiting for your answer"
        liveActivity = nil
        liveGeneration = nil
        state.status = .paused
        sendToExecutor { await $0.setPaused(true) }
        log(event: "ask_user", detail: question)
    }

    private func requestApproval(action: StructuredAction, reason: String) async -> Bool {
        resolveApproval(false)
        pendingApproval = PendingApproval(action: action, reason: reason)
        runStatus = .paused
        overlayState = .approvalRequired
        executorEnabled = false
        currentActionLabel = "Approval required"
        liveActivity = .awaitingApproval
        log(event: "approval_required", detail: reason)

        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
        }
    }

    private func resolveApproval(_ allowed: Bool) {
        let continuation = approvalContinuation
        approvalContinuation = nil
        continuation?.resume(returning: allowed)
    }

    private func completeTask(message rawMessage: String) {
        guard runStatus == .running else { return }
        // Thinking models often lead the reply with blank lines.
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty ? "Done." : trimmed
        runStatus = .done
        overlayState = .idle
        executorEnabled = false
        currentActionLabel = "Done"
        liveActivity = nil
        liveGeneration = nil
        PointerIndicator.shared.hide()
        state.status = .done
        runEndedAt = Date()
        messages.append(ChatMessage(role: .agent, text: message, outcome: computerUseStarted ? .done : nil))
        log(event: "task_done", detail: message)
    }

    private func blockTask(reason: String, action: StructuredAction?) {
        if let action {
            state.deniedActions.append(action)
            setResult(for: action.id, "Blocked: " + reason)
        }
        liveActivity = nil
        liveGeneration = nil
        runStatus = .blocked
        overlayState = .idle
        executorEnabled = false
        currentActionLabel = "Blocked"
        PointerIndicator.shared.hide()
        state.status = .blocked
        runEndedAt = Date()
        messages.append(ChatMessage(role: .agent, text: reason, outcome: .blocked))
        log(event: "task_blocked", detail: reason)
    }

    private func setActivity(_ activity: LiveActivity) {
        liveActivity = activity
        currentActionLabel = activity.label
    }

    /// Apply a streaming update, unless the request it belongs to has finished.
    private func applyGeneration(_ event: GenerationEvent, serial: Int) {
        guard serial == generationSerial, runStatus == .running, var live = liveGeneration else { return }
        let model = settings.plannerModel
        switch event {
        case let .prefill(estimate):
            live.estimatedPromptTokens = estimate
            // Until this model's speed is measured, assume a typical local
            // prefill rate so there's always a percentage to show.
            live.expectedPrefillSeconds = Double(estimate) / (prefillRates[model] ?? Self.assumedPrefillTokensPerSecond)
        case let .reasoning(text):
            runGeneratedTokens += 1
            live.firstTokenAt = live.firstTokenAt ?? Date()
            live.reasoning += text
            live.reasoningTokens += 1
        case let .content(text):
            runGeneratedTokens += 1
            live.firstTokenAt = live.firstTokenAt ?? Date()
            live.content += text
            live.contentTokens += 1
        case let .toolCall(name, arguments):
            runGeneratedTokens += 1
            live.firstTokenAt = live.firstTokenAt ?? Date()
            live.toolName += name
            live.toolArguments += arguments
        case let .usage(promptTokens, seconds):
            guard promptTokens > 0, seconds > 0.05 else { break }
            let rate = Double(promptTokens) / seconds
            // Smooth, since prompt caching makes individual requests vary.
            prefillRates[model] = prefillRates[model].map { $0 * 0.5 + rate * 0.5 } ?? rate
        }
        liveGeneration = live
        setActivity(.generating(live.phase))
    }

    private func setResult(for messageID: UUID, _ result: String) {
        guard let index = messages.lastIndex(where: { $0.id == messageID }) else { return }
        messages[index].result = result
    }

    /// The exact call to show for a step: the native tool call when there is
    /// one, otherwise the structured action as JSON.
    private func callDescription(for action: StructuredAction, session: NativeToolSession?) -> String {
        if let call = session?.lastCallDescription { return call }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(action)).map { String(decoding: $0, as: UTF8.self) } ?? action.summary
    }

    private func persistConversation() {
        guard let conversationID, !messages.isEmpty else { return }
        var conversation = Conversation(id: conversationID, title: conversationTitle, createdAt: conversationCreatedAt, messages: messages, taskIDs: conversationTaskIDs)
        conversation.updatedAt = messages.last?.timestamp ?? Date()
        let store = conversationStore
        let previous = conversationWrites
        conversationWrites = Task.detached {
            await previous?.value
            try? store.save(conversation)
        }
        Task { [weak self] in
            await self?.conversationWrites?.value
            self?.conversationsRevision += 1
        }
    }

    /// Heuristic: did an executed step fail or get blocked? If so we abandon the
    /// rest of a pre-planned batch and re-plan from fresh observation rather than
    /// blindly running stale follow-up steps.
    private static func indicatesFailure(_ result: String) -> Bool {
        let lowered = result.lowercased()
        return lowered.contains("blocked") || lowered.contains("failed") || lowered.contains("disabled")
    }

    @discardableResult
    private func sendToExecutor(_ command: @escaping @Sendable (any ActionExecutor) async -> Void) -> Task<Void, Never> {
        let previous = executorControl
        let executor = executor
        let task = Task {
            await previous?.value
            await command(executor)
        }
        executorControl = task
        return task
    }

    private func recordStepResult(_ text: String) {
        recentLogSnippets.insert(text, at: 0)
        if recentLogSnippets.count > 8 {
            recentLogSnippets.removeLast()
        }
    }

    private func log(event: String, detail: String) {
        let logEvent = LocalEvent(
            timestamp: Date(),
            taskID: activeTaskID,
            event: event,
            status: runStatus,
            detail: detail,
            currentAction: currentActionLabel
        )
        let previous = logWrites
        let logger = logger
        logWrites = Task {
            await previous?.value
            await logger.log(logEvent)
        }
    }

    private func makePlannerProvider(settings: AppSettings) throws -> any LocalModelProvider {
        switch settings.modelProviderMode {
        case .builtIn:
            return BuiltInRulesProvider(configuration: settings.plannerConfiguration())
        case .localServer:
            guard let url = settings.serverURL else {
                throw ModelProviderError.invalidServerURL(settings.serverBaseURL)
            }
            return OpenAICompatibleProvider(baseURL: url, configuration: settings.plannerConfiguration(), httpClient: httpClient)
        }
    }
}

/// Recovery limits the harness applies around the planner.
public enum HarnessLimits {
    /// Invalid actions in a row before the run stops.
    public static let maxConsecutiveCorrections = 3
    /// Identical executed actions in a row before the run stops.
    public static let maxIdenticalSteps = 4
    /// Backstop against a runaway loop. Never shown as a budget; loop and
    /// repetition detection normally end a stuck run long before this.
    public static let maxStepsPerRun = 200
}

public enum ModelStatus: Equatable, Sendable {
    case unknown
    case checking
    case ready
    case unavailable(String)
}

public struct PendingApproval: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let action: StructuredAction
    public let reason: String
}

public extension ActionType {
    var displayName: String {
        switch self {
        case .observe: "Observe"
        case .screenshot: "Screenshot"
        case .browserNewTab: "New Chrome tab"
        case .browserNavigate: "Navigate Chrome tab"
        case .browserSwitchTab: "Switch Chrome tab"
        case .browserCloseTab: "Close Chrome tab"
        case .click: "Click"
        case .doubleClick: "Double-click"
        case .typeTextSafe: "Type text"
        case .typeTextSensitive: "Type sensitive text"
        case .pressKey: "Press key"
        case .scroll: "Scroll"
        case .copy: "Copy"
        case .paste: "Paste"
        case .openURL: "Open URL"
        case .runTerminalCommand: "Run command"
        case .switchApp: "Open app"
        case .wait: "Wait"
        case .finish: "Finish"
        case .askUser: "Ask you"
        case .webSearch: "Search the web"
        case .readWebpage: "Read page"
        }
    }
}
