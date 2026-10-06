import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case chat = "Agent"
    case research = "Research"
    case history = "History"
    case permissions = "Permissions"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .research: "doc.text.magnifyingglass"
        case .history: "clock.arrow.circlepath"
        case .permissions: "lock.shield"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarSection
    let newChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.top, 46)
                .padding(.horizontal, 16)
                .padding(.bottom, 22)

            Button(action: newChat) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18)
                    Text("New chat")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start a new chat (⌘N)")
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(SidebarSection.allCases) { section in
                    SidebarItem(section: section, isSelected: selection == section) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .frame(width: 224)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accentGradient)
                Image(systemName: "location.north.fill")
                    .font(.system(size: 14, weight: .bold))
                    .rotationEffect(.degrees(-35))
                    .foregroundStyle(Theme.onAccent)
            }
            .frame(width: 32, height: 32)
            .shadow(color: Theme.accent.opacity(0.45), radius: 10, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text("LocalPilot")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Desktop agent")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

private struct SidebarItem: View {
    let section: SidebarSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.14) : (isHovering ? Color.white.opacity(0.04) : .clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: 3, height: 16)
                        .offset(x: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
