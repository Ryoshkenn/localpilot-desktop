import AppKit
import SwiftUI

/// One rounded composer box: multi-line field on top, a single bottom row
/// with the access chip on the left and the model picker plus send/stop on
/// the right. The model picker and execution mode live only here.
struct ComposerView: View {
    @Bindable var controller: AgentController
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let openSettings: () -> Void
    let send: () -> Void

    @State private var showsTextCursor = false

    private var isActive: Bool { controller.runStatus.isActive }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 10) {
            TextField(
                isActive ? "LocalPilot is working…" : "Message LocalPilot or ask it to use your Mac…",
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.textPrimary)
            .lineLimit(1...8)
            .focused(isFocused)
            .disabled(isActive)
            .onSubmit(send)
            // The whole upper area of the box acts like the text field: an
            // I-beam on hover, and a click anywhere puts the caret in it.
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { isFocused.wrappedValue = true }
            .onHover { hovering in
                guard hovering != showsTextCursor else { return }
                showsTextCursor = hovering
                if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if showsTextCursor { NSCursor.pop() }
                showsTextCursor = false
            }

            HStack(spacing: 8) {
                AccessChip(controller: controller)
                Spacer(minLength: 8)
                ModelPicker(controller: controller, openSettings: openSettings)
                if controller.runStatus == .running {
                    Button {
                        controller.pause()
                    } label: {
                        Image(systemName: "pause.fill")
                    }
                    .buttonStyle(IconButtonStyle(size: 32))
                    .help("Pause (⇧⌘P)")
                }
                if isActive {
                    Button {
                        controller.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop (⌘.)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(hasText ? .white : Theme.textTertiary)
                            .frame(width: 32, height: 32)
                            .background {
                                if hasText {
                                    Circle().fill(Theme.accentGradient)
                                } else {
                                    Circle().fill(Color.white.opacity(0.12))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasText)
                    .help("Start task (Return)")
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
        )
        // Clicks on the box's empty space (around the controls) focus it too.
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { isFocused.wrappedValue = true }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isFocused.wrappedValue ? Theme.accent.opacity(0.5) : Theme.strokeStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: isFocused.wrappedValue)
    }
}

/// Access-mode chip for the composer's bottom-left slot. Switching to full
/// access asks for confirmation first.
private struct AccessChip: View {
    @Bindable var controller: AgentController
    @State private var showsOptions = false
    @State private var confirmsLive = false
    @State private var isHovering = false

    private var isDryRun: Bool { controller.settings.dryRunExecutionOnly }
    private var tint: Color { isDryRun ? Theme.textSecondary : Theme.amber }

    var body: some View {
        Button {
            showsOptions.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isDryRun ? "shield.lefthalf.filled" : "exclamationmark.shield")
                    .font(.system(size: 12, weight: .medium))
                Text(isDryRun ? "Dry run" : "Full access")
                    .font(.system(size: 13))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering || showsOptions ? Color.white.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(controller.runStatus.isActive)
        .help(controller.runStatus.isActive
              ? "The mode can't change during a run"
              : (isDryRun ? "Dry run: steps are planned and checked, but nothing touches your Mac" : "Live: allowed steps click, type, and run commands for real"))
        .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                option(
                    title: "Dry run",
                    subtitle: "Steps are planned and checked, but nothing touches your Mac",
                    symbol: "shield.lefthalf.filled",
                    isSelected: isDryRun
                ) {
                    controller.settings.dryRunExecutionOnly = true
                }
                option(
                    title: "Full access",
                    subtitle: "Allowed steps click, type, and run commands for real",
                    symbol: "exclamationmark.shield",
                    isSelected: !isDryRun
                ) {
                    if isDryRun { confirmsLive = true }
                }
            }
            .padding(6)
            .frame(width: 320)
        }
        .confirmationDialog("Turn on live control?", isPresented: $confirmsLive) {
            Button("Go live") { controller.settings.dryRunExecutionOnly = false }
            Button("Stay in dry run", role: .cancel) {}
        } message: {
            Text("LocalPilot will move the mouse, type, open URLs, and run allowed commands. Risky steps still ask first, and ⌥⌘. stops it from any app.")
        }
    }

    private func option(title: String, subtitle: String, symbol: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            showsOptions = false
            action()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
