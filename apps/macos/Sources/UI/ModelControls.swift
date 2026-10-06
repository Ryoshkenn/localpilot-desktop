import SwiftUI

extension ModelStatus {
    var tint: Color {
        switch self {
        case .unknown: Theme.textTertiary
        case .checking: Theme.amber
        case .ready: Theme.mint
        case .unavailable: Theme.coral
        }
    }

    var summary: String {
        switch self {
        case .unknown: "Not checked yet"
        case .checking: "Connecting…"
        case .ready: "Ready"
        case let .unavailable(reason): reason
        }
    }
}


/// Compact composer label showing the active model and its live status. Opens
/// a popover listing every model served locally, refreshed on open.
struct ModelPicker: View {
    @Bindable var controller: AgentController
    let openSettings: () -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                if controller.modelStatus == .checking {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .fill(controller.modelStatus.tint)
                        .frame(width: 6, height: 6)
                }
                Text(controller.settings.activeModelLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(controller.runStatus.isActive)
        .help(controller.runStatus.isActive ? "The model can't change during a run" : "Choose a model · \(controller.modelStatus.summary)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelPickerPopover(controller: controller) {
                isPresented = false
                openSettings()
            } dismiss: {
                isPresented = false
            }
        }
    }
}

private struct ModelPickerPopover: View {
    @Bindable var controller: AgentController
    let openSettings: () -> Void
    let dismiss: () -> Void

    private var isBuiltIn: Bool { controller.settings.modelProviderMode == .builtIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Model")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if controller.isDiscoveringModels {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        controller.refreshLocalModels()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Look for local model servers again")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.localServers.isEmpty && !controller.isDiscoveringModels {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No local model servers found")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Start LM Studio, Ollama, llama-server, or mlx_lm.server and load a model, then refresh.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    ForEach(controller.localServers) { server in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                SectionLabel(server.name)
                                Text(server.baseURL.host().map { "\($0):\(server.baseURL.port ?? 80)" } ?? "")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                            if server.models.isEmpty {
                                Text("Running, but no models are loaded.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 6)
                            }
                            ForEach(server.models, id: \.self) { model in
                                ModelRow(
                                    title: model,
                                    isSelected: !isBuiltIn && controller.settings.plannerModel == model && controller.settings.serverURL == server.baseURL
                                ) {
                                    controller.selectModel(model, on: server)
                                    dismiss()
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel("Offline")
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                        ModelRow(title: "Built-in rules", subtitle: "Handles a few fixed task shapes. No model needed.", isSelected: isBuiltIn) {
                            controller.selectBuiltInRules()
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 360)

            Divider().overlay(Theme.stroke)
            Button {
                openSettings()
            } label: {
                Label("Server address and model options…", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
        .background(Theme.surface)
        .environment(\.colorScheme, .dark)
        .onAppear { controller.refreshLocalModels() }
    }
}

private struct ModelRow: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
