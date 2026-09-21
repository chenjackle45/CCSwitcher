import SwiftUI

/// The accounts auto-switch is allowed to switch to, in priority order.
///
/// Every account is listed, the active one included: it is not a target right
/// now, but it will be as soon as the user switches away from it, and hiding a
/// row whose selection is stored is how a selection gets lost.
struct AutoSwitchTargetsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var config = AutoSwitchConfig.shared
    @AppStorage("showFullEmail") private var showFullEmail = false

    /// Selected accounts first, in their priority order; then the rest.
    private var orderedAccounts: [Account] {
        let rank = Dictionary(config.targetIds.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return appState.accounts.sorted { lhs, rhs in
            let lr = rank[lhs.id] ?? Int.max
            let rr = rank[rhs.id] ?? Int.max
            if lr != rr { return lr < rr }
            return lhs.email < rhs.email
        }
    }

    /// Every ticked account is the one currently in use (or no longer exists),
    /// so nothing can be switched to.
    private var selectionHasNoUsableTarget: Bool {
        guard !config.targetIds.isEmpty else { return false }
        let selectable = appState.accounts.filter { !$0.isActive }.map(\.id)
        return !config.targetIds.contains { selectable.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts to switch to")
                .font(.subheadline.weight(.semibold))

            Text("Tick the accounts auto-switch may move to, and drag to set the order. Nothing ticked means every account is allowed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(orderedAccounts) { account in
                    row(account)
                }
                .onMove { source, destination in
                    var ids = orderedAccounts.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    config.applyOrder(ids)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 180)

            HStack {
                if config.targetIds.isEmpty {
                    Label("Every account is allowed", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if selectionHasNoUsableTarget {
                    // The account in use is never a switch target — it is the one
                    // being switched away from. Ticking only it leaves auto-switch
                    // with nothing to pick, and nothing on screen said so.
                    Label("Only the account in use is ticked, so auto-switch has nowhere to go", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Clear selection") { config.clearSelection() }
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Text("\(config.targetIds.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear selection") { config.clearSelection() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    private func row(_ account: Account) -> some View {
        let utilization = AutoSwitchEngine.bindingUtilization(appState.accountUsage[account.id])
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { config.isSelected(account.id) },
                set: { config.setSelected($0, for: account.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)

            Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                .font(.callout)
                .lineLimit(1)

            if account.isActive {
                Text("in use")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(.tertiary, lineWidth: 1))
            }

            Spacer(minLength: 8)

            if let utilization {
                UsageMiniBar(utilization: utilization)
                Text("\(Int(utilization))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text("—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Small read-only bar, so the list can be read as "who has room left".
///
/// Colour comes from `MenuBarConfig.limitBarColor` rather than its own
/// thresholds: that is where the user's custom limit-bar palette and their
/// low-remaining threshold live, and a second hard-coded copy here would be the
/// one bar in the app that ignores both.
///
/// Always asked for the weekly colour, even though the number is the higher of
/// the 5-hour and weekly windows: this list answers "who has room left", and
/// alternating between two palettes row by row would read as noise.
private struct UsageMiniBar: View {
    let utilization: Double
    @ObservedObject private var menuBarConfig = MenuBarConfig.shared

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.2))
            Capsule()
                .fill(menuBarConfig.limitBarColor(for: .weekly, utilization: utilization, context: .dashboard))
                .frame(width: 70 * min(max(utilization, 0), 100) / 100)
        }
        .frame(width: 70, height: 5)
    }
}
