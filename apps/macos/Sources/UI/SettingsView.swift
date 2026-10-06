import SwiftUI

struct SettingsView: View {
    @Bindable var controller: AgentController
    /// Unsaved generation edits; applied only when the user presses Save.
    @State private var draft = GenerationDraft(.defaultValue)

    private var isLocalServer: Bool {
        controller.settings.modelProviderMode == .localServer
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Settings", subtitle: "Changes save automatically.")
                if let error = controller.settingsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.coral)
                }
                modelCard
                executionCard
                generationCard
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 52)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: isLocalServer)
        }
        .background(Theme.canvas)
        .onAppear {
            controller.refreshLocalModels()
            draft = GenerationDraft(controller.settings)
        }
    }

    // MARK: Model

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionLabel("Model")
                Spacer()
                ConnectionStatus(status: controller.modelStatus)
            }
            HStack(spacing: 10) {
                ProviderOption(
                    title: "Local server",
                    subtitle: "A model served by LM Studio, Ollama, llama-server, or mlx_lm.server.",
                    symbol: "server.rack",
                    isSelected: isLocalServer
                ) { controller.settings.modelProviderMode = .localServer }
                ProviderOption(
                    title: "Built-in rules",
                    subtitle: "Handles a few fixed task shapes with no model. Useful for testing the loop.",
                    symbol: "list.bullet.rectangle",
                    isSelected: !isLocalServer
                ) { controller.selectBuiltInRules() }
            }

            if isLocalServer {
                LabeledField(title: "Server address", hint: "OpenAI-compatible base URL, including /v1.") {
                    HStack(spacing: 8) {
                        ThemedTextField(AppSettings.defaultServerURL, text: $controller.settings.serverBaseURL)
                        Button("Test") { controller.checkModelConnection() }
                            .buttonStyle(.secondary)
                            .disabled(controller.settings.plannerModel.isEmpty)
                    }
                }
                discoveredModels
            }
        }
        .card(padding: 18)
    }

    private var discoveredModels: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models found on this Mac")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    controller.refreshLocalModels()
                } label: {
                    if controller.isDiscoveringModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.secondary)
                .disabled(controller.isDiscoveringModels)
            }

            if controller.localServers.isEmpty {
                Text(controller.isDiscoveringModels
                     ? "Looking for servers…"
                     : "Nothing is running on the usual ports (1234, 11434, 8080, 8000, 1337) or the address above. Start a server and load a model, then refresh.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(controller.localServers) { server in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.mint).frame(width: 6, height: 6)
                        Text(server.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(server.baseURL.absoluteString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text(server.models.count == 1 ? "1 model" : "\(server.models.count) models")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    ForEach(server.models, id: \.self) { model in
                        let isSelected = controller.settings.plannerModel == model && controller.settings.serverURL == server.baseURL
                        Divider().overlay(Theme.stroke)
                        Button {
                            controller.selectModel(model, on: server)
                        } label: {
                            HStack {
                                Text(model)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if isSelected {
                                    Chip(text: "In use", symbol: "checkmark", tint: Theme.accent)
                                } else {
                                    Text("Use")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
            }
        }
    }

    // MARK: Execution

    private var executionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Execution")
            ToggleRow(
                title: "Dry run",
                subtitle: controller.settings.dryRunExecutionOnly
                    ? "Steps are planned and checked, but no clicks, keys, commands, or URLs reach your Mac."
                    : "Live control is on. Allowed steps move the mouse, type, and run commands for real. Needs Accessibility permission.",
                isOn: $controller.settings.dryRunExecutionOnly,
                tint: Theme.mint
            )
            .disabled(controller.runStatus.isActive)
            Divider().overlay(Theme.stroke)
            LabeledField(title: "Tool calling", hint: "Native tools use your model server's tool-calling support. Use JSON compatibility only when that support is unavailable.") {
                Picker("Tool calling", selection: $controller.settings.toolCallingMode) {
                    ForEach(ToolCallingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .disabled(controller.runStatus.isActive)
            }
            if controller.settings.toolCallingMode == .jsonCompatibility {
                ToggleRow(
                    title: "Constrain compatibility JSON",
                    subtitle: "Ask the server to enforce the compatibility response schema.",
                    isOn: $controller.settings.useStructuredDecoding
                )
            }
        }
        .card(padding: 18)
    }

    // MARK: Generation

    private var savedDraft: GenerationDraft { GenerationDraft(controller.settings) }
    private var hasUnsavedChanges: Bool { draft != savedDraft }

    private var generationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Generation")
            if !isLocalServer {
                Text("These settings only apply to the local server provider. Switch to Local server above for them to take effect.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledField(title: "Temperature", hint: "How creative or predictable replies are. Lower is more predictable; agents usually work best near 0.") {
                SliderReadout(value: $draft.temperature, range: 0...2, step: 0.05)
            }
            Divider().overlay(Theme.stroke)
            LabeledField(title: "Max output tokens", hint: "Upper bound on tokens per reply, including reasoning tokens.") {
                HStack(spacing: 12) {
                    Stepper(value: $draft.generation.maxTokens, in: 256...32_768, step: 256) {
                        Text("\(draft.generation.maxTokens) tokens")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    // Formatted fields commit on Return or focus loss, so a
                    // partly typed number isn't clamped while typing.
                    TextField("", value: maxTokensBinding, format: .number.grouping(.never))
                        .fieldChrome()
                        .frame(width: 96)
                }
            }
            Divider().overlay(Theme.stroke)
            OptionalSettingRow(
                title: "Top P",
                caption: "Only sample from the smallest set of tokens covering this much probability. Lower values make output more focused.",
                value: $draft.generation.topP,
                fallback: 0.95
            ) { value in
                SliderReadout(value: value, range: 0...1, step: 0.01)
            }
            Divider().overlay(Theme.stroke)
            OptionalSettingRow(
                title: "Top K",
                caption: "Only sample from this many of the most likely tokens. Lower values make output more focused.",
                value: $draft.generation.topK,
                fallback: 40
            ) { value in
                SliderReadout(
                    value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                    range: 1...200,
                    step: 1,
                    fractionDigits: 0
                )
            }
            Divider().overlay(Theme.stroke)
            OptionalSettingRow(
                title: "Repeat penalty",
                caption: "Penalizes reusing tokens already produced. 1.0 turns it off; higher values discourage repetition more.",
                value: $draft.generation.repeatPenalty,
                fallback: 1.1
            ) { value in
                SliderReadout(value: value, range: 1...2, step: 0.01)
            }
            Divider().overlay(Theme.stroke)
            OptionalSettingRow(
                title: "Presence penalty",
                caption: "Penalizes tokens that already appear at all. Positive values encourage talking about new things.",
                value: $draft.generation.presencePenalty,
                fallback: 0
            ) { value in
                SliderReadout(value: value, range: -2...2, step: 0.05)
            }
            Divider().overlay(Theme.stroke)
            OptionalSettingRow(
                title: "Frequency penalty",
                caption: "Penalizes tokens based on how often they already appear. Positive values reduce word-for-word repetition.",
                value: $draft.generation.frequencyPenalty,
                fallback: 0
            ) { value in
                SliderReadout(value: value, range: -2...2, step: 0.05)
            }
            Divider().overlay(Theme.stroke)
            OptionalSettingRow(
                title: "Seed",
                caption: "Fixes sampling randomness so the same prompt gives the same reply. Off means random.",
                value: $draft.generation.seed,
                fallback: 42
            ) { value in
                TextField("", value: value, format: .number.grouping(.never))
                    .fieldChrome()
                    .frame(width: 140)
            }
            Divider().overlay(Theme.stroke)
            LabeledField(title: "Stop sequences", hint: "The model stops generating when it produces one of these. Separate with commas or new lines.") {
                ThemedTextField("e.g. <|stop|>, DONE", text: $draft.stopSequencesText)
            }
            Divider().overlay(Theme.stroke)
            SectionLabel("Runtime")
            LabeledField(title: "Context window", hint: "Context length is set when the model is loaded in LM Studio; this value only sizes LocalPilot's own context budget.") {
                Stepper(value: $draft.contextWindowSize, in: 4_096...AppSettings.maximumContextWindowSize, step: 1_024) {
                    Text("\(draft.contextWindowSize) tokens")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                }
            }
            LabeledField(title: "Response timeout", hint: "How long to wait for one planning step. Models can be slow on first load.") {
                Stepper(value: $draft.timeoutSeconds, in: 10...600, step: 10) {
                    Text("\(Int(draft.timeoutSeconds)) seconds")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                }
            }
            Divider().overlay(Theme.stroke)
            HStack(spacing: 8) {
                Button("Reset to defaults") {
                    draft = GenerationDraft(.defaultValue)
                }
                .buttonStyle(.secondary)
                Spacer()
                if hasUnsavedChanges {
                    Text("Unsaved changes")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.amber)
                    Button("Revert") { draft = savedDraft }
                        .buttonStyle(.secondary)
                }
                Button("Save") { draft.apply(to: &controller.settings) }
                    .buttonStyle(.primary)
                    .disabled(!hasUnsavedChanges)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .card(padding: 18)
        .animation(.easeOut(duration: 0.15), value: hasUnsavedChanges)
    }

    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { draft.generation.maxTokens },
            set: { draft.generation.maxTokens = min(max($0, 256), 32_768) }
        )
    }
}

/// The editable copy of the generation settings.
private struct GenerationDraft: Equatable {
    var temperature: Double
    var generation: GenerationSettings
    var contextWindowSize: Int
    var timeoutSeconds: TimeInterval
    /// Stop sequences as typed; parsed only when saving.
    var stopSequencesText: String

    init(_ settings: AppSettings) {
        temperature = settings.temperature
        generation = settings.generation
        contextWindowSize = settings.contextWindowSize
        timeoutSeconds = settings.timeoutSeconds
        stopSequencesText = settings.generation.stopSequences.joined(separator: ", ")
    }

    var parsedStopSequences: [String] {
        stopSequencesText
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func apply(to settings: inout AppSettings) {
        settings.temperature = temperature
        settings.generation = generation
        settings.generation.stopSequences = parsedStopSequences
        settings.contextWindowSize = contextWindowSize
        settings.timeoutSeconds = timeoutSeconds
    }

    /// Compares parsed values, so retyping the same list isn't a change.
    static func == (lhs: GenerationDraft, rhs: GenerationDraft) -> Bool {
        var left = lhs.generation, right = rhs.generation
        left.stopSequences = lhs.parsedStopSequences
        right.stopSequences = rhs.parsedStopSequences
        return lhs.temperature == rhs.temperature && left == right
            && lhs.contextWindowSize == rhs.contextWindowSize && lhs.timeoutSeconds == rhs.timeoutSeconds
    }
}

/// Slider with a fixed-width numeric readout.
private struct SliderReadout: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var fractionDigits = 2

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $value, in: range, step: step)
                .tint(Theme.accent)
            Text(value, format: .number.precision(.fractionLength(fractionDigits)))
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// A parameter the server has its own default for. The switch decides whether
/// LocalPilot sends a value; when off, the control shows the value it would
/// start from, greyed out.
private struct OptionalSettingRow<Value: Equatable, Control: View>: View {
    let title: String
    let caption: String
    @Binding var value: Value?
    let fallback: Value
    @ViewBuilder let control: (Binding<Value>) -> Control
    /// Remembers an override while it's switched off, so toggling back restores it.
    @State private var remembered: Value?

    private var isOn: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { on in
                if on {
                    value = remembered ?? fallback
                } else {
                    remembered = value
                    value = nil
                }
            }
        )
    }

    private var shownValue: Binding<Value> {
        Binding(
            get: { value ?? remembered ?? fallback },
            set: { value = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Text(value == nil ? "Server default" : "Override")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                Toggle(title, isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            control(shownValue)
                .disabled(value == nil)
                .opacity(value == nil ? 0.4 : 1)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeOut(duration: 0.15), value: value == nil)
    }
}

private struct ConnectionStatus: View {
    let status: ModelStatus

    var body: some View {
        HStack(spacing: 6) {
            if status == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(status.tint).frame(width: 7, height: 7)
            }
            Text(status.summary)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(status.tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 380, alignment: .trailing)
        .help(status.summary)
    }
}

private struct ProviderOption: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, tint: isSelected ? Theme.accent : Theme.textTertiary, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.1) : Theme.surfaceSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
