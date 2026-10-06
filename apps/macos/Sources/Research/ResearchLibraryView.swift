import SwiftUI

struct ResearchLibraryView: View {
    let entries: [ResearchEntry]
    @Binding var selectedEntryID: UUID?
    let newEntry: () -> Void
    let select: (UUID) -> Void
    let delete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Research Library")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: newEntry) {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("New entry in the selected section")
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textTertiary)
                    Text("No matching entries")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(entries) { entry in
                            ResearchLibraryRow(entry: entry, isSelected: selectedEntryID == entry.id) {
                                select(entry.id)
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    delete(entry.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }
}

private struct ResearchLibraryRow: View {
    let entry: ResearchEntry
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: entry.kind.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 17, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(entry.kind.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isSelected ? Theme.accent.opacity(0.9) : Theme.textTertiary)
                    Text(entry.updatedAt, format: .relative(presentation: .named))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.17) : (isHovering ? Color.white.opacity(0.04) : .clear))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.24), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
