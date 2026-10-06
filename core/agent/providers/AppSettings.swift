import Foundation

public enum ModelProviderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Deterministic rules for a few task shapes. No model required.
    case builtIn = "internal_in_process"
    /// A model served by a local OpenAI-compatible server (LM Studio, Ollama, ...).
    case localServer = "local_server"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .builtIn: "Built-in rules"
        case .localServer: "Local server"
        }
    }
}

public enum ToolCallingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case native
    case jsonCompatibility = "json_compatibility"
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .native: "Native tools"; case .jsonCompatibility: "JSON compatibility" }
    }
}

/// Sampling and output controls sent with every chat completion request.
/// These mirror what LM Studio's OpenAI-compatible endpoint accepts
/// (llama.cpp and MLX servers accept the same names). `nil` leaves the
/// server's own per-model default in place.
public struct GenerationSettings: Codable, Equatable, Sendable {
    /// Upper bound on tokens generated per reply, including reasoning.
    public var maxTokens: Int = 4_096
    public var topP: Double?
    public var topK: Int?
    /// llama.cpp/MLX repetition penalty; 1.0 disables it.
    public var repeatPenalty: Double?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    /// Fixed seed for reproducible sampling.
    public var seed: Int?
    /// Strings that end generation when produced.
    public var stopSequences: [String] = []

    public static let defaultValue = GenerationSettings()

    public init(
        maxTokens: Int = 4_096,
        topP: Double? = nil,
        topK: Int? = nil,
        repeatPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        stopSequences: [String] = []
    ) {
        self.maxTokens = maxTokens
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.seed = seed
        self.stopSequences = stopSequences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 4_096
        topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        topK = try container.decodeIfPresent(Int.self, forKey: .topK)
        repeatPenalty = try container.decodeIfPresent(Double.self, forKey: .repeatPenalty)
        presencePenalty = try container.decodeIfPresent(Double.self, forKey: .presencePenalty)
        frequencyPenalty = try container.decodeIfPresent(Double.self, forKey: .frequencyPenalty)
        seed = try container.decodeIfPresent(Int.self, forKey: .seed)
        stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences) ?? []
    }

    /// Request fields for an OpenAI-compatible chat completion. Unset values
    /// are omitted so the server's defaults apply.
    public var payload: [String: Any] {
        var value: [String: Any] = ["max_tokens": max(1, maxTokens)]
        if let topP { value["top_p"] = topP }
        if let topK { value["top_k"] = topK }
        if let repeatPenalty { value["repeat_penalty"] = repeatPenalty }
        if let presencePenalty { value["presence_penalty"] = presencePenalty }
        if let frequencyPenalty { value["frequency_penalty"] = frequencyPenalty }
        if let seed { value["seed"] = seed }
        let stops = stopSequences.filter { !$0.isEmpty }
        if !stops.isEmpty { value["stop"] = stops }
        return value
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Token budget the context compactor plans around.
    public static let maximumContextWindowSize = 131_072
    public static let defaultServerURL = "http://127.0.0.1:1234/v1"

    public var modelProviderMode: ModelProviderMode
    /// Base URL of the OpenAI-compatible API, including the `/v1` segment.
    public var serverBaseURL: String
    /// Model identifier as reported by the server's `/models` endpoint.
    public var plannerModel: String
    public var contextWindowSize: Int
    public var temperature: Double
    public var timeoutSeconds: TimeInterval
    public var dryRunExecutionOnly: Bool
    public var useStructuredDecoding: Bool
    public var toolCallingMode: ToolCallingMode = .native
    public var generation: GenerationSettings = .defaultValue
    public var allowedDomains: [String]
    public var allowedApps: [String]
    public var allowedFolders: [String]

    public static let defaultValue = AppSettings(
        modelProviderMode: .builtIn,
        serverBaseURL: defaultServerURL,
        plannerModel: "",
        contextWindowSize: maximumContextWindowSize,
        temperature: 0.1,
        timeoutSeconds: 120,
        dryRunExecutionOnly: true,
        useStructuredDecoding: true,
        allowedDomains: [],
        allowedApps: [],
        allowedFolders: []
    )

    public init(
        modelProviderMode: ModelProviderMode,
        serverBaseURL: String,
        plannerModel: String,
        contextWindowSize: Int,
        temperature: Double,
        timeoutSeconds: TimeInterval,
        dryRunExecutionOnly: Bool,
        useStructuredDecoding: Bool,
        allowedDomains: [String],
        allowedApps: [String],
        allowedFolders: [String]
    ) {
        self.modelProviderMode = modelProviderMode
        self.serverBaseURL = serverBaseURL
        self.plannerModel = plannerModel
        self.contextWindowSize = contextWindowSize
        self.temperature = temperature
        self.timeoutSeconds = timeoutSeconds
        self.dryRunExecutionOnly = dryRunExecutionOnly
        self.useStructuredDecoding = useStructuredDecoding
        self.allowedDomains = allowedDomains
        self.allowedApps = allowedApps
        self.allowedFolders = allowedFolders
    }

    /// Short label for the active model, suitable for compact UI.
    public var activeModelLabel: String {
        switch modelProviderMode {
        case .builtIn: ModelProviderMode.builtIn.displayName
        case .localServer: plannerModel.isEmpty ? "No model selected" : plannerModel
        }
    }

    public var serverURL: URL? {
        let trimmed = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            return nil
        }
        return url
    }

    public func plannerConfiguration() -> ModelProviderConfiguration {
        ModelProviderConfiguration(
            providerName: modelProviderMode.rawValue,
            modelName: modelProviderMode == .builtIn ? "built-in-rules" : plannerModel,
            temperature: temperature,
            timeoutSeconds: timeoutSeconds,
            generation: generation
        )
    }

    static func defaultSupportDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appending(path: "LocalPilot Desktop", directoryHint: .isDirectory)
    }

    private enum CodingKeys: String, CodingKey {
        case modelProviderMode
        case serverBaseURL
        case plannerModel
        case contextWindowSize
        case temperature
        case timeoutSeconds
        case dryRunExecutionOnly
        case useStructuredDecoding
        case toolCallingMode
        case generation
        case allowedDomains
        case allowedApps
        case allowedFolders
    }

    /// Every field falls back to its default, and unknown provider modes from
    /// older versions (e.g. the removed managed runtime) fall back to built-in,
    /// so an old settings file never fails to load.
    public init(from decoder: Decoder) throws {
        let defaults = Self.defaultValue
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelProviderMode = (try? container.decodeIfPresent(ModelProviderMode.self, forKey: .modelProviderMode)) ?? defaults.modelProviderMode
        serverBaseURL = try container.decodeIfPresent(String.self, forKey: .serverBaseURL) ?? defaults.serverBaseURL
        plannerModel = try container.decodeIfPresent(String.self, forKey: .plannerModel) ?? defaults.plannerModel
        contextWindowSize = try container.decodeIfPresent(Int.self, forKey: .contextWindowSize) ?? defaults.contextWindowSize
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        timeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
        dryRunExecutionOnly = try container.decodeIfPresent(Bool.self, forKey: .dryRunExecutionOnly) ?? defaults.dryRunExecutionOnly
        toolCallingMode = try container.decodeIfPresent(ToolCallingMode.self, forKey: .toolCallingMode) ?? .native
        useStructuredDecoding = try container.decodeIfPresent(Bool.self, forKey: .useStructuredDecoding) ?? defaults.useStructuredDecoding
        generation = (try? container.decodeIfPresent(GenerationSettings.self, forKey: .generation)) ?? .defaultValue
        allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains) ?? defaults.allowedDomains
        allowedApps = try container.decodeIfPresent([String].self, forKey: .allowedApps) ?? defaults.allowedApps
        allowedFolders = try container.decodeIfPresent([String].self, forKey: .allowedFolders) ?? defaults.allowedFolders
    }
}

public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultSettingsURL()
    }

    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .defaultValue
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func defaultSettingsURL() -> URL {
        AppSettings.defaultSupportDirectory()
            .appending(path: "settings.json")
    }
}
