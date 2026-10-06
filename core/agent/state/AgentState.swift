import Foundation

public enum AgentRunStatus: String, Codable, Sendable {
    case idle
    case running
    case paused
    case stopping
    case stopped
    case done
    case blocked

    /// True while a run owns the loop (it can still be paused or stopped).
    public var isActive: Bool {
        self == .running || self == .paused || self == .stopping
    }
}

public enum OverlayState: String, Codable, Sendable {
    case idle
    case running
    case paused
    case approvalRequired = "approval_required"
    case stopping
    case stopped
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case agent
        case system
    }

    public let id: UUID
    public let role: Role
    public let text: String
    public let timestamp: Date
    /// Set when the message describes a proposed agent step.
    public let action: ActionType?
    /// Set when the message reports how a run ended.
    public let outcome: AgentRunStatus?
    /// Exact call the model made (tool name and arguments), or the model's
    /// reasoning for a thought. Shown when the step is expanded.
    public var detail: String?
    /// What the executor reported back for a step, filled in once it ran.
    public var result: String?
    /// True for a captured block of model reasoning.
    public var isThought: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = Date(),
        action: ActionType? = nil,
        outcome: AgentRunStatus? = nil,
        detail: String? = nil,
        result: String? = nil,
        isThought: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.action = action
        self.outcome = outcome
        self.detail = detail
        self.result = result
        self.isThought = isThought
    }

    /// Steps, thoughts, and harness notices render inside a collapsible
    /// activity group rather than as chat bubbles.
    public var isActivity: Bool {
        outcome == nil && (action != nil || isThought || role == .system)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, timestamp, action, outcome, detail, result, isThought
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        action = try container.decodeIfPresent(ActionType.self, forKey: .action)
        outcome = try container.decodeIfPresent(AgentRunStatus.self, forKey: .outcome)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        isThought = try container.decodeIfPresent(Bool.self, forKey: .isThought) ?? false
    }
}

/// What the model is doing right now, shown live where its reply will appear.
public enum GenerationPhase: Equatable, Sendable {
    /// Request sent; the server is reading the prompt before the first token.
    case prefilling
    /// Streaming reasoning tokens.
    case thinking(tokens: Int)
    /// Streaming the visible reply.
    case writing(tokens: Int)
    /// Streaming a tool call's name and arguments.
    case callingTool(name: String)
}

/// One streaming update from the model server.
public enum GenerationEvent: Equatable, Sendable {
    /// Request sent; the server is processing the prompt. The size is a local estimate.
    case prefill(estimatedPromptTokens: Int)
    /// A piece of reasoning text.
    case reasoning(String)
    /// A piece of the visible reply.
    case content(String)
    /// Pieces of a tool call's name and JSON arguments.
    case toolCall(name: String, arguments: String)
    /// Real prompt size from the server, and how long prefill took.
    case usage(promptTokens: Int, prefillSeconds: Double)
}

/// Everything streamed so far for the in-flight model request.
public struct LiveGeneration: Equatable, Sendable {
    public let startedAt: Date
    public var estimatedPromptTokens: Int
    /// Predicted prefill time from this model's measured speed, once known.
    public var expectedPrefillSeconds: Double?
    public var firstTokenAt: Date?
    public var reasoning = ""
    public var content = ""
    public var toolName = ""
    public var toolArguments = ""
    /// Streamed chunks; servers send about one token per chunk.
    public var reasoningTokens = 0
    public var contentTokens = 0

    public init(startedAt: Date = Date(), estimatedPromptTokens: Int = 0, expectedPrefillSeconds: Double? = nil) {
        self.startedAt = startedAt
        self.estimatedPromptTokens = estimatedPromptTokens
        self.expectedPrefillSeconds = expectedPrefillSeconds
    }

    public var phase: GenerationPhase {
        if !toolName.isEmpty || !toolArguments.isEmpty { return .callingTool(name: toolName) }
        if contentTokens > 0 { return .writing(tokens: contentTokens) }
        if reasoningTokens > 0 { return .thinking(tokens: reasoningTokens) }
        return .prefilling
    }
}

/// A live status line for the transcript while a run is active.
public enum LiveActivity: Equatable, Sendable {
    case connecting(model: String)
    case observing
    case generating(GenerationPhase)
    case running(ActionType)
    case awaitingApproval
    case waitingForUser

    public var label: String {
        switch self {
        case let .connecting(model): "Connecting to \(model)"
        case .observing: "Reading the screen"
        case .generating(.prefilling): "Processing prompt"
        case .generating(.thinking): "Thinking"
        case .generating(.writing): "Writing"
        case let .generating(.callingTool(name)): name.isEmpty ? "Calling tool" : "Calling \(name)"
        case let .running(action): action.displayName
        case .awaitingApproval: "Waiting for approval"
        case .waitingForUser: "Waiting for your answer"
        }
    }

    /// Token count for streaming phases, if known.
    public var tokens: Int? {
        switch self {
        case let .generating(.thinking(tokens)), let .generating(.writing(tokens)): tokens
        default: nil
        }
    }
}

public struct LocalPilotState: Codable, Equatable, Sendable {
    public var taskID: UUID?
    public var originalTask: String
    public var currentSubtask: String
    public var status: AgentRunStatus
    public var allowedDomains: [String]
    public var allowedApps: [String]
    public var allowedFolders: [String]
    public var completedSteps: [String]
    public var knownFacts: [String: String]
    public var openRisks: [String]
    public var deniedActions: [StructuredAction]
    public var userApprovals: [String]
    public var lastObservationSummary: String
    public var lastActionResult: String

    public static let empty = LocalPilotState(
        taskID: nil,
        originalTask: "",
        currentSubtask: "",
        status: .idle,
        allowedDomains: [],
        allowedApps: [],
        allowedFolders: [],
        completedSteps: [],
        knownFacts: [:],
        openRisks: [],
        deniedActions: [],
        userApprovals: [],
        lastObservationSummary: "",
        lastActionResult: ""
    )
}
