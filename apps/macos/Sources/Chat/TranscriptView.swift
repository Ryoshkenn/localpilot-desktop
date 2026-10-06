import AppKit
import SwiftUI

/// Chat messages with the agent's work between them, used by the main chat
/// and the Agent Mode panel. Runs of tool calls and thoughts collapse into a
/// group whose header shows what the model is doing right now; opening it
/// shows every step, with the newest expanded while it runs.
struct TranscriptView: View {
    let controller: AgentController
    let messages: [ChatMessage]
    /// Groups the user opened, keyed by the message each group follows.
    @Binding var openGroups: Set<UUID>
    /// Message the first group follows when `messages` is a slice.
    var anchor: UUID?
    var compact = false

    /// Live status only shows while the loop is actually working.
    private var liveActivity: LiveActivity? {
        controller.runStatus == .running ? controller.liveActivity : nil
    }

    private var streamingReply: String {
        guard liveActivity != nil, let generation = controller.liveGeneration,
              generation.toolName.isEmpty, generation.toolArguments.isEmpty else { return "" }
        return generation.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let items = TranscriptItem.build(from: messages, anchor: anchor)
        let trailingGroupIsLive = liveActivity != nil && items.last?.isGroup == true
        // A live run with no activity yet gets its own group after the last message.
        let liveKey = messages.last(where: { !$0.isActivity })?.id ?? anchor
        let gap: CGFloat = compact ? 10 : 14
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isFirst = index == 0
                switch item {
                case let .message(message):
                    MessageRow(message: message, compact: compact)
                        .padding(.top, isFirst ? 0 : (message.role == .user ? 28 : gap))
                case let .group(_, key, steps):
                    let isLive = trailingGroupIsLive && index == items.count - 1
                    ActivityGroupView(
                        steps: steps,
                        live: isLive ? liveActivity : nil,
                        generation: isLive ? controller.liveGeneration : nil,
                        isExpanded: expansion(for: key)
                    )
                    .padding(.top, isFirst ? 0 : gap)
                }
            }
            if let liveActivity, !trailingGroupIsLive, let liveKey {
                ActivityGroupView(
                    steps: [],
                    live: liveActivity,
                    generation: controller.liveGeneration,
                    isExpanded: expansion(for: liveKey)
                )
                .padding(.top, items.isEmpty ? 0 : gap)
            }
            if !streamingReply.isEmpty {
                // The reply streams in place, as plain chat text.
                AgentMessage(text: streamingReply, compact: compact, showsCopy: false)
                    .padding(.top, gap)
            }
        }
        .environment(\.stepScreenshots, controller.stepScreenshots)
    }

    private func expansion(for key: UUID) -> Binding<Bool> {
        Binding(
            get: { openGroups.contains(key) },
            set: { isOpen in
                if isOpen { openGroups.insert(key) } else { openGroups.remove(key) }
            }
        )
    }
}

/// Called just before the user expands or collapses something in the
/// transcript, so the enclosing scroll view can hold its position and let the
/// content grow downward instead of pushing what the user is reading up.
extension EnvironmentValues {
    @Entry var transcriptWillResize: () -> Void = {}
    /// Screenshots the model took, by step, so a step can show what it saw.
    @Entry var stepScreenshots: [UUID: ScreenshotAttachment] = [:]
}

/// Scrolling for a transcript: opens at the bottom and follows new output
/// while the user is at the bottom. Anything the user expands or collapses
/// grows downward from where they are, rather than shoving the view up.
struct TranscriptScrolling: ViewModifier {
    @State private var follows = true

    func body(content: Content) -> some View {
        content
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(follows ? .bottom : .top, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                follows = atBottom
            }
            .environment(\.transcriptWillResize) { follows = false }
    }
}

extension View {
    func transcriptScrolling() -> some View {
        modifier(TranscriptScrolling())
    }
}

/// The transcript as chat messages interleaved with runs of agent activity
/// (tool calls, thoughts, harness notes), which render as one collapsible group.
enum TranscriptItem: Identifiable {
    case message(ChatMessage)
    /// `key` is the message the group follows, so a group keeps its open
    /// state as it grows from a live placeholder into finished steps.
    case group(id: UUID, key: UUID, steps: [ChatMessage])

    var id: UUID {
        switch self {
        case let .message(message): message.id
        case let .group(id, _, _): id
        }
    }

    var isGroup: Bool {
        if case .group = self { true } else { false }
    }

    static func build(from messages: [ChatMessage], anchor initialAnchor: UUID? = nil) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var pending: [ChatMessage] = []
        var anchor = initialAnchor
        func flush() {
            guard let first = pending.first else { return }
            items.append(.group(id: first.id, key: anchor ?? first.id, steps: pending))
            pending = []
        }
        for message in messages {
            if message.isActivity {
                pending.append(message)
            } else {
                flush()
                items.append(.message(message))
                anchor = message.id
            }
        }
        flush()
        return items
    }
}

/// A plain reply from the model, laid out like prose rather than a bubble.
private struct AgentMessage: View {
    let text: String
    var compact = false
    var showsCopy = true
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(markdown(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                .font(.system(size: compact ? 13 : 14))
                .lineSpacing(3)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsCopy {
                CopyButton(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .opacity(isHovering ? 1 : 0.55)
            }
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - Activity

private struct ActivityGroupView: View {
    let steps: [ChatMessage]
    let live: LiveActivity?
    let generation: LiveGeneration?
    @Binding var isExpanded: Bool
    @Environment(\.transcriptWillResize) private var willResize

    private var summary: String {
        let calls = steps.filter { $0.action != nil }.count
        let thoughts = steps.filter(\.isThought).count
        var parts: [String] = []
        if calls > 0 { parts.append(calls == 1 ? "Used 1 tool" : "Used \(calls) tools") }
        if thoughts > 0 { parts.append(parts.isEmpty ? "Thought" : "thought") }
        if parts.isEmpty { parts.append(steps.count == 1 ? "1 note" : "\(steps.count) notes") }
        return parts.joined(separator: ", ")
    }

    /// The model has started its next output, so the previous step compacts.
    private var modelHasMovedOn: Bool {
        generation?.firstTokenAt != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                willResize()
                isExpanded.toggle()
            } label: {
                header
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide steps" : "Show steps")

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        ActivityRow(
                            step: step,
                            autoOpen: live != nil && index == steps.count - 1 && !modelHasMovedOn
                        )
                    }
                    if let live, let generation, case .generating = live {
                        LiveOutputRow(generation: generation)
                    }
                }
                .padding(.leading, 7)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.stroke).frame(width: 1).padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let live {
                LiveSpinner()
                PulsingLabel(text: live.label)
                if let generation {
                    GenerationMetrics(activity: live, generation: generation)
                }
            } else {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the model is producing right now, as plain flowing text: prompt
/// progress, then its reasoning, then any tool call being written. The reply
/// itself streams below the group as a normal message.
private struct LiveOutputRow: View {
    let generation: LiveGeneration

    private var callText: String {
        guard !generation.toolName.isEmpty || !generation.toolArguments.isEmpty else { return "" }
        return "\(generation.toolName)(\(generation.toolArguments)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch generation.phase {
            case .prefilling:
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16)
                    PrefillProgress(generation: generation)
                }
            default:
                if !generation.reasoning.isEmpty {
                    streamed(generation.reasoning, symbol: "brain", monospaced: false)
                }
                if !callText.isEmpty {
                    streamed(callText, symbol: "wrench.and.screwdriver", monospaced: true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func streamed(_ text: String, symbol: String, monospaced: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Theme.textTertiary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The live status label. A gentle opacity pulse, which (unlike a moving
/// gradient) doesn't re-layout as the label changes.
private struct PulsingLabel: View {
    let text: String
    @State private var dimmed = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .opacity(dimmed ? 0.55 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
            }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    var compact = false

    var body: some View {
        if let outcome = message.outcome, outcome != .done {
            OutcomeBanner(status: outcome, text: message.text)
        } else {
            switch message.role {
            case .user: UserBubble(text: message.text, compact: compact)
            case .agent, .system: AgentMessage(text: message.text, compact: compact)
            }
        }
    }
}

private struct UserBubble: View {
    let text: String
    var compact = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: compact ? 40 : 120)
                Text(text)
                    .font(.system(size: compact ? 13 : 14))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
            }
            CopyButton(text: text)
                .opacity(isHovering ? 1 : 0.55)
        }
        .onHover { isHovering = $0 }
    }
}

/// A plain reply from the model, laid out like prose rather than a bubble.

/// Copies a message; shows a checkmark briefly to confirm.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11.5))
                .foregroundStyle(copied ? Theme.mint : Theme.textTertiary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy message")
    }
}

/// Inline markdown (bold, code, links) with the text's own line breaks kept.
/// Links are underlined, since the monochrome palette has no link color.
private func markdown(_ text: String) -> AttributedString {
    guard var result = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
        return AttributedString(text)
    }
    for run in result.runs where run.link != nil {
        result[run.range].underlineStyle = .single
    }
    return result
}

/// Short live numbers after the status label: prompt size and progress while
/// prefilling, token counts while streaming.
private struct GenerationMetrics: View {
    let activity: LiveActivity
    let generation: LiveGeneration

    var body: some View {
        Group {
            switch generation.phase {
            case .prefilling:
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    prefillText(now: context.date)
                }
            case let .thinking(tokens), let .writing(tokens):
                Text("\(tokens) tokens")
                    .contentTransition(.numericText())
            case .callingTool:
                Text("\(generation.toolArguments.count) chars")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textTertiary)
        .monospacedDigit()
    }

    /// Prompt processing shows only an estimated percentage. It's estimated
    /// from this model's measured speed and never claims 100%.
    private func prefillText(now: Date) -> Text {
        let elapsed = max(0, now.timeIntervalSince(generation.startedAt))
        guard let expected = generation.expectedPrefillSeconds, expected > 0 else { return Text("") }
        return Text("\(Int(min(0.97, elapsed / expected) * 100))%")
    }

    static func compact(_ tokens: Int) -> String {
        tokens >= 1_000 ? String(format: "%.1fk", Double(tokens) / 1_000) : "\(tokens)"
    }
}

/// The in-flight model output, streamed as it arrives: prompt progress, then
/// reasoning, the reply, and any tool call being written.

/// A thin bar for prompt processing. Determinate once this model's prefill
/// speed has been measured; otherwise an indeterminate sweep.
private struct PrefillProgress: View {
    let generation: LiveGeneration

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(generation.startedAt))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    if let expected = generation.expectedPrefillSeconds, expected > 0 {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: proxy.size.width * min(0.97, elapsed / expected))
                    } else {
                        let sweep = elapsed.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule()
                            .fill(Theme.accent.opacity(0.8))
                            .frame(width: proxy.size.width * 0.25)
                            .offset(x: proxy.size.width * (sweep * 1.25 - 0.25))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 320)
    }
}

/// Streams text in a bounded box that keeps its newest line in view.

/// One line per step; click it to see the exact call and what came back.
/// `autoOpen` expands the newest step while the run is working on it.
private struct ActivityRow: View {
    let step: ChatMessage
    let autoOpen: Bool
    /// Set once the user clicks, overriding `autoOpen`.
    @State private var userOpen: Bool?
    @State private var isHovering = false
    @Environment(\.transcriptWillResize) private var willResize
    @Environment(\.stepScreenshots) private var screenshots

    private var isOpen: Bool { userOpen ?? autoOpen }

    private var symbol: String {
        if step.isThought { return "brain" }
        if let action = step.action { return action.symbol }
        return "exclamationmark.bubble"
    }

    private var title: String {
        if step.isThought { return "Thought" }
        if let action = step.action { return action.displayName }
        return step.text
    }

    /// Secondary text after the title: the step summary, or a reasoning preview.
    private var subtitle: String {
        if step.isThought {
            return step.detail?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
        return step.action == nil ? "" : step.text
    }

    private var failed: Bool {
        guard let result = step.result?.lowercased() else { return step.action == nil && !step.isThought }
        return result.hasPrefix("blocked") || result.hasPrefix("denied") || result.contains("failed")
    }

    /// An action that has been proposed but hasn't reported back yet.
    private var isRunning: Bool {
        step.action != nil && step.result == nil && autoOpen
    }

    private var hasDetails: Bool {
        !(step.detail ?? "").isEmpty || !(step.result ?? "").isEmpty || screenshots[step.id] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if hasDetails {
                    willResize()
                    userOpen = !isOpen
                }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if isRunning {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(failed ? Theme.coral : Theme.textTertiary)
                        }
                    }
                    .frame(width: 16)
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .layoutPriority(1)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if hasDetails {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .opacity(isHovering || isOpen ? 1 : 0)
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering && hasDetails ? Color.white.opacity(0.04) : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(hasDetails ? (isOpen ? "Hide details" : "Show the exact call") : "")

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    if let detail = step.detail, !detail.isEmpty {
                        DetailBlock(label: step.isThought ? "Reasoning" : "Call", text: detail)
                    }
                    if let result = step.result, !result.isEmpty {
                        DetailBlock(label: "Result", text: result)
                    } else if isRunning {
                        Text("Running…")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if let shot = screenshots[step.id] {
                        ScreenshotThumbnail(screenshot: shot)
                    }
                }
                .padding(.leading, 32)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isOpen)
    }
}

/// The picture the model saw. Click to open it full size in Preview.
private struct ScreenshotThumbnail: View {
    let screenshot: ScreenshotAttachment
    @State private var image: NSImage?

    var body: some View {
        Button(action: openFullSize) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Theme.surfaceSunken)
                        .aspectRatio(CGFloat(max(1, screenshot.pixelWidth)) / CGFloat(max(1, screenshot.pixelHeight)), contentMode: .fit)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Open full size")
        .task(id: screenshot.jpegBase64.count) {
            image = Data(base64Encoded: screenshot.jpegBase64).flatMap(NSImage.init(data:))
        }
    }

    private func openFullSize() {
        guard let data = Data(base64Encoded: screenshot.jpegBase64) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalPilot-screenshot-\(UUID().uuidString.prefix(8)).jpg")
        guard (try? data.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct DetailBlock: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.6)
                Spacer()
                CopyButton(text: text)
            }
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// Text with a light sweep across it, used for the live status line.

private struct LiveSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 16, height: 16)
    }
}

/// The model's checklist, shown only once it has created one with the todo tool.

/// The model's checklist, shown only once it has created one with the todo tool.
struct ChecklistCard: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textTertiary)
                    Text(item)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }
}

private struct OutcomeBanner: View {
    let status: AgentRunStatus
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.tint)
                .frame(width: 16)
            Text(markdown(text))
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
