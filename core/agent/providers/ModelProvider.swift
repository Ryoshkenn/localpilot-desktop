import Foundation

public enum ModelResponseFormat: Sendable, Equatable {
    case json
    /// Constrain decoding to a JSON Schema document. `schema` is the schema as a
    /// JSON string; `name` is a runtime-facing label.
    case jsonSchema(name: String, schema: String)
}

public struct ModelProviderConfiguration: Codable, Equatable, Sendable {
    public var providerName: String
    public var modelName: String
    public var temperature: Double
    public var timeoutSeconds: TimeInterval
    public var generation: GenerationSettings

    public init(providerName: String, modelName: String, temperature: Double, timeoutSeconds: TimeInterval, generation: GenerationSettings = .defaultValue) {
        self.providerName = providerName
        self.modelName = modelName
        self.temperature = temperature
        self.timeoutSeconds = timeoutSeconds
        self.generation = generation
    }
}

public protocol LocalModelProvider: Sendable {
    var configuration: ModelProviderConfiguration { get }
    func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String
    func complete(prompt: String, system: String?, format: ModelResponseFormat?, screenshot: ScreenshotAttachment?) async throws -> String
    func respond(messages: [NativeMessage], tools: [NativeToolDefinition]) async throws -> NativeMessage
    /// Like `respond(messages:tools:)`, reporting what the model produces as it streams.
    func respond(messages: [NativeMessage], tools: [NativeToolDefinition], onEvent: @escaping @Sendable (GenerationEvent) -> Void) async throws -> NativeMessage
    /// Throws when the model cannot currently serve requests.
    func healthCheck() async throws
    func cancel() async
}

public extension LocalModelProvider {
    func respond(messages: [NativeMessage], tools: [NativeToolDefinition]) async throws -> NativeMessage {
        throw NativeToolError.unsupported
    }

    func respond(messages: [NativeMessage], tools: [NativeToolDefinition], onEvent: @escaping @Sendable (GenerationEvent) -> Void) async throws -> NativeMessage {
        onEvent(.prefill(estimatedPromptTokens: PromptSizeEstimator.tokens(messages: messages, tools: tools)))
        return try await respond(messages: messages, tools: tools)
    }

    func complete(prompt: String, system: String?, format: ModelResponseFormat?, screenshot: ScreenshotAttachment?) async throws -> String {
        try await complete(prompt: prompt, system: system, format: format)
    }

    func complete(prompt: String) async throws -> String {
        try await complete(prompt: prompt, system: nil, format: nil)
    }
}

// MARK: - Built-in rules

/// A deterministic, rule-based stand-in for a model. It recognizes a handful of
/// simple task shapes ("open <url>", "press <key>", ...) so the loop can be
/// exercised with no model installed. It does not reason about the screen.
public actor BuiltInRulesProvider: LocalModelProvider {
    public let configuration: ModelProviderConfiguration
    private var plannerStep = 0

    public init(configuration: ModelProviderConfiguration? = nil) {
        self.configuration = configuration ?? ModelProviderConfiguration(
            providerName: "built-in",
            modelName: "built-in-rules",
            temperature: 0,
            timeoutSeconds: 1
        )
    }

    public func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        let task = Self.originalTask(from: prompt).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["hi", "hello", "hey", "hi!", "hello!"].contains(task) {
            return #"{"reply":"Hi! How can I help?"}"#
        }
        return try nextPlannerAction(for: prompt)
    }

    public func healthCheck() async throws {}
    public func cancel() async {}

    private func nextPlannerAction(for prompt: String) throws -> String {
        plannerStep += 1
        let action: StructuredAction
        if plannerStep == 1 {
            action = StructuredAction(
                type: .observe,
                targetKind: "screen",
                targetText: "current screen",
                expectedResult: "fresh screen state captured for planner context",
                riskLevel: .low,
                reason: "Built-in rules start with a visible observation step."
            )
        } else if plannerStep == 2, let taskAction = Self.actionForTask(Self.originalTask(from: prompt)) {
            action = taskAction
        } else {
            action = StructuredAction(
                type: .finish,
                targetKind: "task",
                targetText: "current task",
                expectedResult: "task completed",
                riskLevel: .low,
                reason: "Built-in rules completed the task."
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(action), encoding: .utf8) ?? "{}"
    }

    private static func originalTask(from prompt: String) -> String {
        guard let start = prompt.range(of: "Original task:")?.upperBound,
              let end = prompt.range(of: "Current context:")?.lowerBound else {
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(prompt[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func actionForTask(_ task: String) -> StructuredAction? {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if let url = firstURL(in: trimmed), lowered.contains("open") || lowered.contains("go to") {
            return StructuredAction(
                type: .openURL,
                targetKind: "browser",
                targetText: url,
                expectedResult: "URL opens in the default browser",
                riskLevel: .medium,
                reason: "Built-in rules recognized a simple open URL task."
            )
        }

        if lowered.hasPrefix("switch to ") {
            let appName = String(trimmed.dropFirst("switch to ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appName.isEmpty else { return nil }
            return StructuredAction(
                type: .switchApp,
                targetKind: "app",
                targetText: appName,
                expectedResult: "Requested app becomes active",
                riskLevel: .low,
                reason: "Built-in rules recognized a simple app switch task."
            )
        }

        if lowered.hasPrefix("press ") {
            let keyName = String(trimmed.dropFirst("press ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyName.isEmpty else { return nil }
            return StructuredAction(
                type: .pressKey,
                targetKind: "keyboard",
                targetText: keyName,
                text: keyName.lowercased(),
                expectedResult: "Requested key is pressed",
                riskLevel: .low,
                reason: "Built-in rules recognized a simple keypress task."
            )
        }

        if lowered.hasPrefix("type "), let text = quotedText(in: trimmed) ?? textAfterPrefix(trimmed, prefix: "type ") {
            return StructuredAction(
                type: .typeTextSafe,
                targetKind: "focused_field",
                targetText: "focused field",
                text: text,
                expectedResult: "Text is typed into the focused field",
                riskLevel: .low,
                reason: "Built-in rules recognized a simple safe typing task."
            )
        }

        if lowered.contains("scroll down") || lowered == "scroll" {
            return StructuredAction(
                type: .scroll,
                targetKind: "window",
                targetText: "current window",
                coordinates: [0, -5],
                expectedResult: "Current view scrolls down",
                riskLevel: .low,
                reason: "Built-in rules recognized a simple scroll task."
            )
        }

        if lowered.contains("scroll up") {
            return StructuredAction(
                type: .scroll,
                targetKind: "window",
                targetText: "current window",
                coordinates: [0, 5],
                expectedResult: "Current view scrolls up",
                riskLevel: .low,
                reason: "Built-in rules recognized a simple scroll task."
            )
        }

        if lowered.hasPrefix("run "), let command = quotedText(in: trimmed) ?? backtickedText(in: trimmed) ?? textAfterPrefix(trimmed, prefix: "run ") {
            return StructuredAction(
                type: .runTerminalCommand,
                targetKind: "terminal",
                targetText: "shell",
                command: command,
                expectedResult: "Terminal command completes",
                riskLevel: .low,
                reason: "Built-in rules recognized a simple terminal command task."
            )
        }

        if lowered.hasPrefix("double click "), let point = firstPoint(in: lowered) {
            return StructuredAction(
                type: .doubleClick,
                targetKind: "point",
                targetText: "screen point",
                coordinates: point,
                expectedResult: "Target point is double-clicked",
                riskLevel: .low,
                reason: "Built-in rules recognized a simple double-click task."
            )
        }

        if lowered.hasPrefix("click "), let point = firstPoint(in: lowered) {
            return StructuredAction(
                type: .click,
                targetKind: "point",
                targetText: "screen point",
                coordinates: point,
                expectedResult: "Target point is clicked",
                riskLevel: .low,
                reason: "Built-in rules recognized a simple click task."
            )
        }

        return nil
    }

    private static func firstURL(in text: String) -> String? {
        firstMatch(in: text, pattern: #"https?://[^\s]+"#)
    }

    private static func quotedText(in text: String) -> String? {
        firstMatch(in: text, pattern: #""([^"]+)""#, group: 1)
    }

    private static func backtickedText(in text: String) -> String? {
        firstMatch(in: text, pattern: #"`([^`]+)`"#, group: 1)
    }

    private static func firstPoint(in text: String) -> [Double]? {
        guard let match = firstMatch(in: text, pattern: #"(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)"#),
              let comma = match.firstIndex(of: ","),
              let x = Double(match[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Double(match[match.index(after: comma)...].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return [x, y]
    }

    private static func textAfterPrefix(_ text: String, prefix: String) -> String? {
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let value = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func firstMatch(in text: String, pattern: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let resultRange = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[resultRange])
    }
}

// MARK: - HTTP

public struct HTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    /// Applied to `URLRequest.timeoutInterval` when positive.
    public let timeoutSeconds: TimeInterval?

    public init(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }

    public var jsonBody: [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol HTTPClient: Sendable {
    func data(for request: HTTPRequest) async throws -> HTTPResponse
    /// True when `lines(for:)` delivers a response incrementally.
    var supportsStreaming: Bool { get }
    /// Response body as lines, as they arrive. Throws `badStatus` for non-2xx.
    func lines(for request: HTTPRequest) async throws -> AsyncThrowingStream<String, Error>
}

public extension HTTPClient {
    var supportsStreaming: Bool { false }

    func lines(for request: HTTPRequest) async throws -> AsyncThrowingStream<String, Error> {
        let response = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ModelProviderError.badStatus(response.statusCode, String(decoding: response.data, as: UTF8.self))
        }
        let lines = String(decoding: response.data, as: UTF8.self).components(separatedBy: "\n")
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
        }
        if let timeoutSeconds = request.timeoutSeconds, timeoutSeconds > 0 {
            urlRequest.timeoutInterval = timeoutSeconds
        }

        let (data, response) = try await session.data(for: urlRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(data: data, statusCode: statusCode)
    }

    public var supportsStreaming: Bool { true }

    public func lines(for request: HTTPRequest) async throws -> AsyncThrowingStream<String, Error> {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
        }
        if let timeoutSeconds = request.timeoutSeconds, timeoutSeconds > 0 {
            urlRequest.timeoutInterval = timeoutSeconds
        }
        let (bytes, response) = try await session.bytes(for: urlRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 4_096 { break }
            }
            throw ModelProviderError.badStatus(statusCode, String(decoding: body, as: UTF8.self))
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Rough prompt size, used to show prefill progress. OpenAI-compatible servers
/// report nothing while they process the prompt, so this is all there is
/// until the first token arrives.
enum PromptSizeEstimator {
    /// Typical BPE tokenizers average about four characters per token.
    static let charactersPerToken = 4.0
    /// Vision encoders turn a downscaled screenshot into roughly this many tokens.
    static let tokensPerImage = 1_000

    static func tokens(messages: [NativeMessage], tools: [NativeToolDefinition]) -> Int {
        var characters = 0
        var images = 0
        for message in messages {
            characters += (message.content ?? "").count + (message.reasoningContent ?? "").count + 8
            characters += message.toolCalls.reduce(0) { $0 + $1.function.name.count + $1.function.arguments.count }
            if message.screenshot != nil { images += 1 }
        }
        if let toolData = try? JSONSerialization.data(withJSONObject: tools.map(\.payload)) {
            characters += toolData.count
        }
        return Int(Double(characters) / charactersPerToken) + images * tokensPerImage
    }
}

/// Rebuilds a chat completion from OpenAI-style server-sent events and
/// reports each delta as it arrives. A non-SSE body (a server that ignored
/// `stream`) is kept verbatim and decoded as a normal response.
struct NativeStreamAccumulator {
    private var content = ""
    private var reasoning = ""
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var finishReason: String?
    private var plainBody = ""
    private(set) var isDone = false
    /// Prompt size the server reported in its final usage chunk.
    private(set) var promptTokens: Int?

    mutating func consume(line rawLine: String) -> [GenerationEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix(":") else { return [] }
        guard line.hasPrefix("data:") else {
            plainBody += rawLine + "\n"
            return []
        }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            isDone = true
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return [] }
        if let usage = object["usage"] as? [String: Any], let tokens = usage["prompt_tokens"] as? Int {
            promptTokens = tokens
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] else { return [] }

        var events: [GenerationEvent] = []
        if let text = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !text.isEmpty {
            reasoning += text
            events.append(.reasoning(text))
        }
        if let text = delta["content"] as? String, !text.isEmpty {
            content += text
            events.append(.content(text))
        }
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                let index = call["index"] as? Int ?? 0
                var entry = calls[index] ?? (id: "", name: "", arguments: "")
                if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                var nameDelta = ""
                var argumentsDelta = ""
                if let function = call["function"] as? [String: Any] {
                    nameDelta = function["name"] as? String ?? ""
                    argumentsDelta = function["arguments"] as? String ?? ""
                    entry.name += nameDelta
                    entry.arguments += argumentsDelta
                }
                calls[index] = entry
                events.append(.toolCall(name: nameDelta, arguments: argumentsDelta))
            }
        }
        return events
    }

    /// A non-streamed chat completion body equivalent to what was received.
    func completionData() throws -> Data {
        if calls.isEmpty, content.isEmpty, reasoning.isEmpty, !plainBody.isEmpty {
            return Data(plainBody.utf8)
        }
        var message: [String: Any] = ["role": "assistant", "content": content.isEmpty ? NSNull() : content]
        if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
        if !calls.isEmpty {
            message["tool_calls"] = calls.keys.sorted().compactMap { index -> [String: Any]? in
                guard let call = calls[index] else { return nil }
                return [
                    "id": call.id.isEmpty ? "call_\(index)" : call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments.isEmpty ? "{}" : call.arguments]
                ]
            }
        }
        var choice: [String: Any] = ["index": 0, "message": message]
        choice["finish_reason"] = finishReason ?? (calls.isEmpty ? "stop" : "tool_calls")
        return try JSONSerialization.data(withJSONObject: ["choices": [choice]])
    }
}

public enum ModelProviderError: LocalizedError, Sendable, Equatable {
    case badStatus(Int, String)
    case invalidResponse
    case invalidServerURL(String)
    case noModelSelected
    case modelNotAvailable(String)
    case outOfTokens
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case let .badStatus(status, body):
            "Model server returned HTTP \(status): \(body.prefix(300))"
        case .invalidResponse:
            "Model server returned a response LocalPilot could not read."
        case let .invalidServerURL(url):
            "\"\(url)\" is not a valid server address."
        case .noModelSelected:
            "No model is selected. Pick one from the model menu."
        case let .modelNotAvailable(model):
            "The server does not have \"\(model)\" loaded."
        case .outOfTokens:
            "The model used its whole token budget thinking and never answered. Turn off thinking for this model in your server, or pick a non-thinking model."
        case .emptyReply:
            "The model returned an empty reply."
        }
    }
}

// MARK: - OpenAI-compatible local servers

/// Talks to any local server that implements the OpenAI chat completions API:
/// LM Studio, Ollama, llama.cpp's `llama-server`, `mlx_lm.server`, vLLM, Jan.
public actor OpenAICompatibleProvider: LocalModelProvider {
    public let configuration: ModelProviderConfiguration
    private let baseURL: URL
    private let httpClient: HTTPClient
    private var activeTask: Task<String, Error>?
    private var activeToolTask: Task<NativeMessage, Error>?

    public init(
        baseURL: URL,
        configuration: ModelProviderConfiguration,
        httpClient: HTTPClient = URLSessionHTTPClient()
    ) {
        self.baseURL = baseURL
        self.configuration = configuration
        self.httpClient = httpClient
    }

    public func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        try await complete(prompt: prompt, system: system, format: format, screenshot: nil)
    }

    public func complete(prompt: String, system: String?, format: ModelResponseFormat?, screenshot: ScreenshotAttachment?) async throws -> String {
        guard !configuration.modelName.isEmpty else { throw ModelProviderError.noModelSelected }
        activeTask?.cancel()

        var messages: [[String: Any]] = []
        if let system {
            messages.append(["role": "system", "content": system])
        }
        if let screenshot {
            messages.append(["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + screenshot.jpegBase64]]
            ]])
        } else {
            messages.append(["role": "user", "content": prompt])
        }

        var payload = configuration.generation.payload
        payload.merge([
            "model": configuration.modelName,
            "messages": messages,
            "temperature": configuration.temperature,
            "stream": false,
            // Asks hybrid reasoning models (Qwen3.x and similar) to skip
            // thinking. llama.cpp and vLLM honor it; others ignore it.
            "chat_template_kwargs": ["enable_thinking": false],
        ]) { _, new in new }
        if let responseFormat = Self.responseFormat(for: format) {
            payload["response_format"] = responseFormat
        }

        let task = Task<String, Error> {
            let response: HTTPResponse
            do {
                response = try await self.post(payload)
            } catch ModelProviderError.badStatus(let status, _) where (400..<500).contains(status) {
                // Servers disagree on which optional fields they accept (LM
                // Studio rejects json_object, older llama.cpp rejects
                // json_schema, strict servers reject unknown keys). Retry once
                // with a minimal request; the planner still validates the JSON.
                var plain = payload
                plain.removeValue(forKey: "response_format")
                plain.removeValue(forKey: "chat_template_kwargs")
                response = try await self.post(plain)
            }
            try Task.checkCancellation()
            return try Self.decodeContent(response.data)
        }
        activeTask = task
        defer {
            if activeTask == task { activeTask = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Native tools use the server's model-specific chat template and parser.
    /// Never force a JSON reply, disable model thinking, or strip tools on retry.
    public func respond(messages: [NativeMessage], tools: [NativeToolDefinition]) async throws -> NativeMessage {
        try await respond(messages: messages, tools: tools, onEvent: { _ in })
    }

    public func respond(
        messages: [NativeMessage],
        tools: [NativeToolDefinition],
        onEvent: @escaping @Sendable (GenerationEvent) -> Void
    ) async throws -> NativeMessage {
        guard !configuration.modelName.isEmpty else { throw ModelProviderError.noModelSelected }
        activeToolTask?.cancel()
        activeTask?.cancel()
        let streams = httpClient.supportsStreaming
        let task = Task<NativeMessage, Error> {
            var payload = self.configuration.generation.payload
            payload.merge([
                "model": self.configuration.modelName,
                "messages": messages.map(\.payload),
                "tools": tools.map(\.payload),
                "tool_choice": "auto",
                "parallel_tool_calls": false,
                "temperature": self.configuration.temperature,
                "stream": streams
            ]) { _, new in new }
            onEvent(.prefill(estimatedPromptTokens: PromptSizeEstimator.tokens(messages: messages, tools: tools)))
            guard streams else {
                let response = try await self.post(payload)
                try Task.checkCancellation()
                return try Self.decodeNativeResponse(response.data)
            }
            let sentAt = ContinuousClock.now
            let lines: AsyncThrowingStream<String, Error>
            do {
                // Usage in the last chunk gives the real prompt size, which
                // calibrates future prefill estimates.
                var withUsage = payload
                withUsage["stream_options"] = ["include_usage": true]
                lines = try await self.postStreaming(withUsage)
            } catch ModelProviderError.badStatus(let status, _) where (400..<500).contains(status) {
                lines = try await self.postStreaming(payload)
            }
            var accumulator = NativeStreamAccumulator()
            var prefillDuration: Duration?
            for try await line in lines {
                try Task.checkCancellation()
                let events = accumulator.consume(line: line)
                if prefillDuration == nil, !events.isEmpty { prefillDuration = sentAt.duration(to: .now) }
                events.forEach(onEvent)
                if accumulator.isDone { break }
            }
            try Task.checkCancellation()
            if let promptTokens = accumulator.promptTokens, let prefillDuration {
                let seconds = Double(prefillDuration.components.seconds) + Double(prefillDuration.components.attoseconds) / 1e18
                onEvent(.usage(promptTokens: promptTokens, prefillSeconds: seconds))
            }
            return try Self.decodeNativeResponse(accumulator.completionData())
        }
        activeToolTask = task
        defer { if activeToolTask == task { activeToolTask = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    static func decodeNativeResponse(_ data: Data) throws -> NativeMessage {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    var role: String
                    var content: String?
                    var tool_calls: [NativeToolCall]?
                    var reasoning_content: String?
                }
                var message: Message
                var finish_reason: String?
            }
            var choices: [Choice]
        }
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let choice = completion.choices.first, choice.message.role == "assistant" else {
            throw NativeToolError.invalidResponse
        }
        guard choice.finish_reason != "length" else { throw NativeToolError.truncated }
        let calls = choice.message.tool_calls ?? []
        guard calls.allSatisfy({ !$0.id.isEmpty && $0.type == "function" && !$0.function.name.isEmpty }),
              Set(calls.map(\.id)).count == calls.count else { throw NativeToolError.invalidResponse }
        let content = choice.message.content
        guard !calls.isEmpty || content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ModelProviderError.emptyReply
        }
        guard choice.finish_reason != "tool_calls" || !calls.isEmpty else { throw NativeToolError.invalidResponse }
        return NativeMessage(role: "assistant", content: content, toolCalls: calls, reasoningContent: choice.message.reasoning_content)
    }

    public func healthCheck() async throws {
        guard !configuration.modelName.isEmpty else { throw ModelProviderError.noModelSelected }
        let models = try await Self.listModels(baseURL: baseURL, httpClient: httpClient, timeoutSeconds: min(configuration.timeoutSeconds, 5))
        guard models.contains(configuration.modelName) else {
            throw ModelProviderError.modelNotAvailable(configuration.modelName)
        }
    }

    public func cancel() {
        activeToolTask?.cancel()
        activeToolTask = nil
        activeTask?.cancel()
        activeTask = nil
    }

    /// Model identifiers the server reports from `GET /models`.
    public static func listModels(baseURL: URL, httpClient: HTTPClient = URLSessionHTTPClient(), timeoutSeconds: TimeInterval = 2) async throws -> [String] {
        struct ModelList: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let response = try await httpClient.data(for: HTTPRequest(
            url: baseURL.appending(path: "models"),
            method: "GET",
            timeoutSeconds: timeoutSeconds
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ModelProviderError.badStatus(response.statusCode, String(decoding: response.data, as: UTF8.self))
        }
        guard let list = try? JSONDecoder().decode(ModelList.self, from: response.data) else {
            throw ModelProviderError.invalidResponse
        }
        return list.data.map(\.id)
    }

    private func postStreaming(_ payload: [String: Any]) async throws -> AsyncThrowingStream<String, Error> {
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await httpClient.lines(for: HTTPRequest(
            url: baseURL.appending(path: "chat/completions"),
            method: "POST",
            headers: ["Content-Type": "application/json", "Accept": "text/event-stream"],
            body: body,
            timeoutSeconds: configuration.timeoutSeconds
        ))
    }

    private func post(_ payload: [String: Any]) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try await httpClient.data(for: HTTPRequest(
            url: baseURL.appending(path: "chat/completions"),
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body,
            timeoutSeconds: configuration.timeoutSeconds
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ModelProviderError.badStatus(response.statusCode, String(decoding: response.data, as: UTF8.self))
        }
        return response
    }

    private static func responseFormat(for format: ModelResponseFormat?) -> [String: Any]? {
        switch format {
        case let .jsonSchema(name, schema):
            guard let data = schema.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return ["type": "json_schema", "json_schema": ["name": name, "schema": object, "strict": false]]
        case .json, .none:
            // `json_object` is not universally supported; the prompt asks for
            // JSON and the planner extracts it.
            return nil
        }
    }

    static func decodeContent(_ data: Data) throws -> String {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                    // LM Studio and vLLM split out a thinking model's reasoning.
                    let reasoningContent: String?
                    let reasoning: String?

                    enum CodingKeys: String, CodingKey {
                        case content
                        case reasoningContent = "reasoning_content"
                        case reasoning
                    }
                }
                let message: Message
                let finishReason: String?

                enum CodingKeys: String, CodingKey {
                    case message
                    case finishReason = "finish_reason"
                }
            }
            let choices: [Choice]
        }
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let choice = completion.choices.first else {
            throw ModelProviderError.invalidResponse
        }
        let content = choice.message.content ?? ""
        let reasoning = choice.message.reasoningContent ?? choice.message.reasoning ?? ""
        // Some servers route a thinking model's entire reply, JSON included,
        // into the reasoning field and leave `content` empty.
        if !content.contains("{"), reasoning.contains("{") {
            return reasoning
        }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if choice.finishReason == "length" {
                throw ModelProviderError.outOfTokens
            }
            throw ModelProviderError.emptyReply
        }
        return content
    }
}

// MARK: - Discovery

/// A local model server found on this Mac and the models it currently offers.
public struct LocalModelServer: Identifiable, Equatable, Sendable {
    public var id: String { baseURL.absoluteString }
    public let name: String
    public let baseURL: URL
    public let models: [String]

    public init(name: String, baseURL: URL, models: [String]) {
        self.name = name
        self.baseURL = baseURL
        self.models = models
    }
}

public enum LocalModelDiscovery {
    /// Default ports of popular local runtimes, all serving the OpenAI API under `/v1`.
    public static let knownServers: [(name: String, url: String)] = [
        ("LM Studio", "http://127.0.0.1:1234/v1"),
        ("Ollama", "http://127.0.0.1:11434/v1"),
        ("llama.cpp / MLX server", "http://127.0.0.1:8080/v1"),
        ("vLLM", "http://127.0.0.1:8000/v1"),
        ("Jan", "http://127.0.0.1:1337/v1"),
    ]

    /// Probes the known ports plus any `extra` addresses in parallel and returns
    /// the servers that answered, in probe order.
    public static func discover(extra: [URL] = [], httpClient: HTTPClient = URLSessionHTTPClient()) async -> [LocalModelServer] {
        var candidates = knownServers.compactMap { entry in URL(string: entry.url).map { (entry.name, $0) } }
        for url in extra where !candidates.contains(where: { $0.1 == url }) {
            candidates.append(("Custom server", url))
        }

        return await withTaskGroup(of: (Int, LocalModelServer?).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    let models = try? await OpenAICompatibleProvider.listModels(baseURL: candidate.1, httpClient: httpClient, timeoutSeconds: 1.5)
                    guard let models else { return (index, nil) }
                    // Embedding models can't plan; hide them from the picker.
                    let chatModels = models.filter { !$0.localizedCaseInsensitiveContains("embed") }
                    return (index, LocalModelServer(name: candidate.0, baseURL: candidate.1, models: chatModels))
                }
            }
            var found: [(Int, LocalModelServer)] = []
            for await (index, server) in group {
                if let server { found.append((index, server)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
