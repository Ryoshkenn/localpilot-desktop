import SwiftUI

struct ResearchEditorView: View {
    let entry: ResearchEntry?
    @Binding var activeTab: ResearchTab
    @Binding var title: String
    @Binding var content: String
    let lastSavedAt: Date?
    let selectTab: (ResearchTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorHeader
            Rectangle().fill(Theme.stroke).frame(height: 1)

            if let entry {
                metadata(entry)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                TextEditor(text: $content)
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(5)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(Theme.canvas)
                    .accessibilityLabel("\(entry.kind.label) content")
            } else {
                EmptyPlaceholder(
                    symbol: "doc.text.magnifyingglass",
                    title: "Select an entry",
                    message: "Choose a note, draft, or results log from the research library."
                )
            }
        }
        .background(Theme.canvas)
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 12) {
                TextField("Untitled entry", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .disabled(entry == nil)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Circle()
                        .fill(lastSavedAt == nil ? Theme.textTertiary : Theme.mint)
                        .frame(width: 7, height: 7)
                    Text(saveLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            HStack(spacing: 22) {
                ForEach(ResearchTab.allCases) { tab in
                    Button {
                        selectTab(tab)
                    } label: {
                        VStack(spacing: 8) {
                            Text(tab.rawValue)
                                .font(.system(size: 12.5, weight: activeTab == tab ? .semibold : .regular))
                                .foregroundStyle(activeTab == tab ? Theme.accent : Theme.textSecondary)
                            Rectangle()
                                .fill(activeTab == tab ? Theme.accent : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func metadata(_ entry: ResearchEntry) -> some View {
        HStack(spacing: 0) {
            metadataItem("Type", value: entry.kind.label, symbol: entry.kind.symbol)
            metadataItem("Last updated", value: entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
            metadataItem("Word count", value: entry.wordCount.formatted())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func metadataItem(_ label: String, value: String, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5))
                }
                Text(value)
                    .lineLimit(1)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var saveLabel: String {
        guard let lastSavedAt else { return "Local draft" }
        return "Saved \(lastSavedAt.formatted(.relative(presentation: .named)))"
    }
}
