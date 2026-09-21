import Foundation

private let log = FileLog("AutoSwitch")

/// How auto-switch picks among the accounts it is allowed to switch to.
enum AutoSwitchPolicy: String, CaseIterable, Identifiable {
    /// The candidate with the lowest usage — spreads quota evenly.
    case mostHeadroom
    /// The first candidate that qualifies, in the order the user arranged.
    case listOrder

    var id: String { rawValue }
}

/// The accounts auto-switch may switch TO, in the user's priority order, plus
/// how to choose among them.
///
/// Stored as account ids rather than indexes, so a reordered or filtered view
/// cannot silently change which accounts are selected.
@MainActor
final class AutoSwitchConfig: ObservableObject {
    static let shared = AutoSwitchConfig()

    /// Selected accounts, in priority order. **Empty means "all accounts are
    /// allowed"** — the behaviour before this setting existed, so an upgrade
    /// changes nothing until the user touches the list.
    @Published var targetIds: [UUID] {
        didSet { persistTargets() }
    }

    @Published var policy: AutoSwitchPolicy {
        didSet { persistPolicy() }
    }

    private let targetsKey = "autoSwitchTargets"
    private let policyKey = "autoSwitchPolicy"
    private let defaults: UserDefaults

    /// `defaults` is injectable for the same reason `CredentialAnchorStore`'s
    /// is: the tests need to feed it stored values (including the malformed
    /// ones it defends against) without writing to the real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Dedup on the way in, the same way `MenuBarConfig` does. A duplicate id
        // from hand-edited or stale defaults would inflate the "N selected"
        // count and — worse — make `applyOrder`'s count guard permanently
        // unsatisfiable, so every drag to reorder would be silently ignored.
        // The ranking engine itself tolerates duplicates.
        let stored = defaults.stringArray(forKey: targetsKey) ?? []
        var seen = Set<UUID>()
        self.targetIds = stored.compactMap(UUID.init(uuidString:)).filter { seen.insert($0).inserted }
        let rawPolicy = defaults.string(forKey: policyKey) ?? ""
        self.policy = AutoSwitchPolicy(rawValue: rawPolicy) ?? .mostHeadroom
    }

    // MARK: - Editing

    func isSelected(_ accountId: UUID) -> Bool {
        targetIds.contains(accountId)
    }

    /// Selection is by id, never by row index.
    func setSelected(_ isSelected: Bool, for accountId: UUID) {
        if isSelected {
            guard !targetIds.contains(accountId) else { return }
            targetIds.append(accountId)
        } else {
            targetIds.removeAll { $0 == accountId }
        }
    }

    /// Rebuilds the priority order from the order shown on screen.
    ///
    /// The guard is what makes a partial view safe: if the screen did not show
    /// every selected account, the reorder is ignored rather than dropping the
    /// ones it could not see.
    func applyOrder(_ orderedIds: [UUID]) {
        let selected = Set(targetIds)
        let reordered = orderedIds.filter { selected.contains($0) }
        guard reordered.count == targetIds.count else {
            log.warning("[autoSwitch] Reorder ignored: the list on screen showed \(reordered.count) of \(targetIds.count) selected accounts")
            return
        }
        targetIds = reordered
    }

    func clearSelection() {
        targetIds = []
    }

    /// Drops ids for accounts that no longer exist. Called with the FULL account
    /// list — pruning against anything narrower (visible rows, switchable
    /// accounts) would delete selections the user still wants.
    func prune(existingAccountIds: Set<UUID>) {
        let kept = targetIds.filter { existingAccountIds.contains($0) }
        guard kept.count != targetIds.count else { return }
        targetIds = kept
    }

    // MARK: - Persistence

    private func persistTargets() {
        defaults.set(targetIds.map(\.uuidString), forKey: targetsKey)
    }

    private func persistPolicy() {
        defaults.set(policy.rawValue, forKey: policyKey)
    }
}
