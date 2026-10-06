import SwiftUI

/// Review UI for a step the policy engine refused to auto-allow. Used inline
/// in the chat and inside the Agent Mode HUD, so an approval can be answered
/// without switching away from the app the agent is working in.
struct ApprovalCard: View {
    let approval: PendingApproval
    var compact = false
    let allow: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: "hand.raised.fill", tint: Theme.amber, size: compact ? 26 : 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approval needed")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(approval.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: approval.action.type.symbol)
                        .foregroundStyle(approval.action.type.tint)
                    Text(approval.action.type.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Chip(text: "\(approval.action.riskLevel.rawValue) risk", tint: riskTint)
                    Spacer(minLength: 0)
                }
                KeyValueRow(key: "Target", value: approval.action.targetText)
                if let payload = approval.action.command ?? approval.action.text {
                    Text(payload)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(compact ? 3 : 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 1)
                        )
                }
                if !compact {
                    KeyValueRow(key: "Expected", value: approval.action.expectedResult)
                    KeyValueRow(key: "Why", value: approval.action.reason)
                }
            }

            HStack {
                Button(action: deny) {
                    Label("Deny", systemImage: "xmark")
                }
                .buttonStyle(.danger)
                .help("Refuse this step and stop the task")
                Spacer()
                Button(action: allow) {
                    Label("Allow once", systemImage: "checkmark")
                }
                .buttonStyle(.primary)
                .help("Run this one step; later steps are checked again")
            }
        }
        .card(padding: compact ? 14 : 16, tint: Theme.amber)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed: \(approval.reason)")
    }

    private var riskTint: Color {
        switch approval.action.riskLevel {
        case .low: Theme.mint
        case .medium: Theme.amber
        case .high: Theme.coral
        }
    }
}
