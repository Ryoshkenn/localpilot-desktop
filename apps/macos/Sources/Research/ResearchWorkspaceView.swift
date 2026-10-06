import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ResearchWorkspaceView: View {
    @Bindable var store: ResearchStore
    let logFileURL: URL

    @State private var selectedEntryID: UUID?
    @State private var activeTab: ResearchTab = .paper
    @State private var query = ""
    @State private var showsCompactInspector = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 46)
                .padding(.bottom, 16)

            summaryStrip
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            Rectangle().fill(Theme.stroke).frame(height: 1)

            GeometryReader { proxy in
                workspaceBody(showsInspector: proxy.size.width >= 1_020)
            }
        }
        .background(Theme.canvas)
        .onAppear {
            if selectedEntryID == nil {
                select(store.firstEntryID(for: .paper))
            }
        }
        .sheet(isPresented: $showsCompactInspector) {
            ResearchEvidenceInspector(store: store)
                .frame(width: 360, height: 720)
                .background(Theme.sidebar)
                .environment(\.colorScheme, .dark)
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "The research file could not be written.")
        }
    }

    private var header: some View {
        PageHeader(title: "Research", subtitle: "Capture the work while it is fresh.") {
            HStack(spacing: 8) {
                searchField

                Button {
                    if let id = store.captureLatestRun(from: logFileURL) {
                        select(id)
                    }
                } label: {
                    Label("Capture latest run", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.secondary)
                .help("Append the newest uncaptured LocalPilot task to the engineering work log")

                Menu {
                    newEntryButton("Research note", kind: .note)
                    newEntryButton("Work log", kind: .workLog)
                    newEntryButton("Paper draft", kind: .paper)
                    newEntryButton("Results log", kind: .results)
                } label: {
                    Label("New entry", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button(action: export) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.secondary)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search research", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(width: 200, height: 32)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
    }

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            ResearchSummaryItem(
                symbol: "doc.text",
                value: "\(store.entries.count) entries",
                detail: "\(store.totalWordCount.formatted()) words"
            )
            summaryDivider
            ResearchSummaryItem(
                symbol: "flask",
                value: "\(store.experiments.count) experiments",
                detail: experimentBreakdown
            )
            summaryDivider
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Draft progress", systemImage: "doc.richtext")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(store.draftProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(Theme.accentGradient)
                            .frame(width: proxy.size.width * store.draftProgress)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
        }
        .frame(height: 64)
        .background(Theme.surfaceSunken.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: 1, height: 34)
    }

    private var experimentBreakdown: String {
        let locals = store.experiments.filter { $0.kind == .local }.count
        let cited = store.experiments.count - locals
        return "\(locals) local · \(cited) cited"
    }

    @ViewBuilder
    private func workspaceBody(showsInspector: Bool) -> some View {
        HStack(spacing: 0) {
            ResearchLibraryView(
                entries: store.entries(matching: query),
                selectedEntryID: $selectedEntryID,
                newEntry: { select(store.createEntry(kind: activeTab == .paper ? .paper : activeTab == .results ? .results : .note)) },
                select: select,
                delete: delete
            )
            .frame(width: showsInspector ? 220 : 200)

            Rectangle().fill(Theme.stroke).frame(width: 1)

            ResearchEditorView(
                entry: store.entry(id: selectedEntryID),
                activeTab: $activeTab,
                title: titleBinding,
                content: contentBinding,
                lastSavedAt: store.lastSavedAt,
                selectTab: selectTab
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if !showsInspector {
                    Button {
                        showsCompactInspector = true
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(.icon)
                    .padding(12)
                    .help("Show experiments and benchmarks")
                }
            }

            if showsInspector {
                Rectangle().fill(Theme.stroke).frame(width: 1)
                ResearchEvidenceInspector(store: store)
                    .frame(width: 330)
            }
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { store.entry(id: selectedEntryID)?.title ?? "" },
            set: { value in
                guard let selectedEntryID else { return }
                store.updateTitle(value, for: selectedEntryID)
            }
        )
    }

    private var contentBinding: Binding<String> {
        Binding(
            get: { store.entry(id: selectedEntryID)?.content ?? "" },
            set: { value in
                guard let selectedEntryID else { return }
                store.updateContent(value, for: selectedEntryID)
            }
        )
    }

    private func newEntryButton(_ title: String, kind: ResearchEntryKind) -> some View {
        Button(title) {
            select(store.createEntry(kind: kind))
        }
    }

    private func select(_ id: UUID) {
        selectedEntryID = id
        if let entry = store.entry(id: id) {
            activeTab = entry.kind.tab
        }
    }

    private func selectTab(_ tab: ResearchTab) {
        activeTab = tab
        select(store.firstEntryID(for: tab))
    }

    private func delete(_ id: UUID) {
        store.deleteEntry(id: id)
        if selectedEntryID == id {
            select(store.firstEntryID(for: activeTab))
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export LocalPilot research"
        panel.nameFieldStringValue = "LocalPilot Research.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct ResearchSummaryItem: View {
    let symbol: String
    let value: String
    let detail: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}
