import SwiftUI

struct ResearchEvidenceInspector: View {
    @Bindable var store: ResearchStore

    @State private var recordKind: ResearchRecordKind = .local
    @State private var method = ""
    @State private var device = ""
    @State private var task = ""
    @State private var outcome: ResearchOutcome = .success
    @State private var successRate = ""
    @State private var latency = ""
    @State private var tokens = ""
    @State private var source = ""
    @State private var notes = ""
    @State private var validationMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                captureSection
                    .padding(16)

                Rectangle().fill(Theme.stroke).frame(height: 1)

                benchmarkSection
                    .padding(16)
            }
        }
        .background(Theme.sidebar)
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Record experiment", systemImage: "flask")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Picker("Record type", selection: $recordKind) {
                ForEach(ResearchRecordKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Theme.accent)

            InspectorField(title: recordKind == .local ? "Model" : "Method") {
                ThemedTextField(recordKind == .local ? "Qwen 3B, Llama 3.2…" : "OSWorld baseline…", text: $method)
            }

            InspectorField(title: "Device") {
                ThemedTextField(recordKind == .local ? "MacBook Pro, Raspberry Pi…" : "Evaluation hardware", text: $device)
            }

            InspectorField(title: "Task") {
                ThemedTextField("What was evaluated?", text: $task)
            }

            if recordKind == .local {
                InspectorField(title: "Outcome") {
                    Picker("Outcome", selection: $outcome) {
                        ForEach(ResearchOutcome.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tint(Theme.accent)
                }
            } else {
                InspectorField(title: "Success") {
                    ThemedTextField("Percent", text: $successRate)
                }
                InspectorField(title: "Source") {
                    ThemedTextField("Paper, report, or URL", text: $source)
                }
            }

            HStack(spacing: 10) {
                InspectorField(title: "Latency") {
                    ThemedTextField("Seconds", text: $latency)
                }
                InspectorField(title: "Tokens") {
                    ThemedTextField("Count", text: $tokens)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextEditor(text: $notes)
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(7)
                    .frame(height: 64)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: record) {
                Label("Record run", systemImage: "flask.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
        }
    }

    private var benchmarkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Benchmark comparison", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Local aggregates and cited results stay visibly separate.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(spacing: 0) {
                benchmarkHeader
                ForEach(store.benchmarkComparisons) { comparison in
                    BenchmarkComparisonRow(comparison: comparison)
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                }
            }
            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Label(
                "A shared table does not make unlike evaluations equivalent. Document task, environment, scoring, and source before drawing a comparison.",
                systemImage: "info.circle"
            )
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var benchmarkHeader: some View {
        HStack(spacing: 8) {
            Text("Method").frame(maxWidth: .infinity, alignment: .leading)
            Text("Success").frame(width: 46, alignment: .trailing)
            Text("Latency").frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.025))
    }

    private func record() {
        let cleanMethod = method.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMethod.isEmpty, !cleanTask.isEmpty else {
            validationMessage = "Method and task are required."
            return
        }

        let parsedSuccess = parseDouble(successRate)
        if recordKind == .cited,
           !successRate.isEmpty,
           (parsedSuccess == nil || !(0 ... 100).contains(parsedSuccess ?? -1)) {
            validationMessage = "Success must be a number from 0 to 100."
            return
        }
        if recordKind == .cited, source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationMessage = "Cited results need a source."
            return
        }

        store.addExperiment(
            ResearchExperiment(
                id: UUID(),
                kind: recordKind,
                method: cleanMethod,
                device: device.trimmingCharacters(in: .whitespacesAndNewlines),
                task: cleanTask,
                outcome: recordKind == .local ? outcome : nil,
                successRate: recordKind == .cited ? parsedSuccess : nil,
                latencySeconds: parseDouble(latency),
                tokenCount: Int(tokens.replacingOccurrences(of: ",", with: "")),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                source: recordKind == .local ? "Local measurement" : source.trimmingCharacters(in: .whitespacesAndNewlines),
                createdAt: .now
            )
        )

        task = ""
        notes = ""
        latency = ""
        tokens = ""
        successRate = ""
        validationMessage = nil
    }

    private func parseDouble(_ value: String) -> Double? {
        let clean = value
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return Double(clean)
    }
}

private struct InspectorField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BenchmarkComparisonRow: View {
    let comparison: BenchmarkComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(comparison.method)
                    .font(.system(size: 10.5, weight: comparison.isLocal ? .semibold : .medium))
                    .foregroundStyle(comparison.isLocal ? Theme.accent : Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(comparison.success)
                    .frame(width: 46, alignment: .trailing)
                Text(comparison.latency)
                    .frame(width: 48, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(comparison.isPlaceholder ? Theme.textTertiary : Theme.textSecondary)

            HStack(spacing: 5) {
                Image(systemName: comparison.isLocal ? "internaldrive" : "quote.bubble")
                    .font(.system(size: 8.5))
                Text(comparison.source)
                    .lineLimit(1)
                if comparison.tokens != "—" {
                    Text("·")
                    Text("\(comparison.tokens) tokens")
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(comparison.isPlaceholder ? Theme.amber.opacity(0.85) : Theme.textTertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(comparison.isLocal ? Theme.accent.opacity(0.09) : .clear)
    }
}
