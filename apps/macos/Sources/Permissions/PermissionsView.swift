import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

enum MacPermission: String, CaseIterable, Identifiable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility:
            "Reads the focused window's buttons and fields so the planner can target them by name, and lets live control post clicks and keystrokes."
        case .screenRecording:
            "Lets observation read window titles from other apps. Only needed if you enable screenshot capture."
        }
    }

    var requiredFor: String {
        switch self {
        case .accessibility: "Live control"
        case .screenRecording: "Richer observation"
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    var settingsURL: URL? {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// Triggers the system prompt where macOS offers one.
    func request() {
        switch self {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
    }
}

struct PermissionsView: View {
    /// Bumped to re-read permission state, e.g. when returning from System Settings.
    @State private var refreshToken = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Permissions", subtitle: "What macOS lets LocalPilot see and do.") {
                    Button {
                        refreshToken += 1
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(Theme.mint)
                    Text("Dry run needs no permissions. Grant these only when you're ready for live control.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .card(padding: 12, tint: Theme.mint)

                VStack(spacing: 18) {
                    ForEach(MacPermission.allCases) { permission in
                        PermissionCard(permission: permission) {
                            refreshToken += 1
                        }
                    }
                }
                // New identity on refresh so each card re-reads macOS state.
                .id(refreshToken)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 52)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshToken += 1
        }
        // Toggling a switch in System Settings doesn't reactivate LocalPilot,
        // so poll while this page is open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                refreshToken += 1
            }
        }
    }
}

private struct PermissionCard: View {
    let permission: MacPermission
    let onChange: () -> Void

    var body: some View {
        let granted = permission.isGranted
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: permission.symbol, tint: granted ? Theme.mint : Theme.amber, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(permission.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Chip(
                        text: granted ? "Granted" : "Not granted",
                        symbol: granted ? "checkmark" : "exclamationmark",
                        tint: granted ? Theme.mint : Theme.amber
                    )
                }
                Text(permission.purpose)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Used for: \(permission.requiredFor)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                if !granted, permission == .screenRecording {
                    Text("Already switched on? macOS applies Screen Recording only after LocalPilot restarts.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if !granted, permission == .screenRecording {
                Button("Relaunch", action: relaunch)
                    .buttonStyle(.secondary)
            }
            if !granted {
                Button("Request") {
                    permission.request()
                    onChange()
                }
                .buttonStyle(.primary)
            }
            Button("Open Settings") {
                if let url = permission.settingsURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.secondary)
        }
        .card(padding: 16)
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
