import Foundation

/// Pure, UI-agnostic auto-switch decision logic.
///
/// Mirrors the proven design in `claude-swap` (threshold + hysteresis): when the
/// active account's *binding window* (the higher of its 5h / weekly utilization)
/// reaches the configured threshold, pick the same-provider account with the most
/// quota left — but only one that sits at least `hysteresisPct` below the threshold,
/// so two accounts hovering at the line never ping-pong. All guardrails that need
/// state (cooldown, re-entrancy, verification) live in `AppState`; this stays a
/// pure function.
enum AutoSwitchEngine {

    /// The binding utilization for an account = max of the windows we watch.
    /// We watch the 5-hour (session) and 7-day (weekly-all) windows — the two
    /// that the `/api/oauth/usage` endpoint still populates as top-level fields.
    ///
    /// A window reading whose `resets_at` lies in the past is discarded: accounts
    /// are polled round-robin, so a retained sample can outlive the window it
    /// described — the quota it reports as consumed no longer exists. Within an
    /// unexpired window, consumption only grows, so an unexpired reading is a
    /// valid lower bound even when it is several cycles old.
    ///
    /// `requireKnownWindow` controls what happens when `resets_at` is absent or
    /// unparseable (API omission, format change). Lenient (default) keeps the
    /// reading — right for candidates, where a stale-high reading merely
    /// excludes them and anything chosen is re-verified with a fresh fetch.
    /// Strict discards it — required for the ACTIVE side, where a retained
    /// high reading with no known expiry could otherwise TRIGGER a switch
    /// long after the real window reset.
    ///
    /// Returns nil when no usable reading exists for the account.
    static func bindingUtilization(
        _ usage: UsageAPIResponse?,
        asOf now: Date = Date(),
        requireKnownWindow: Bool = false
    ) -> Double? {
        guard let usage else { return nil }
        return [usage.fiveHour, usage.sevenDay]
            .compactMap { window -> Double? in
                guard let window, let util = window.utilization else { return nil }
                guard let resets = window.resetsAtDate else {
                    return requireKnownWindow ? nil : util
                }
                return resets < now ? nil : util
            }
            .max()
    }

    /// Rank the accounts worth switching to, best first (most headroom).
    ///
    /// The result is a list of *proposals*, not decisions: it is computed from
    /// whatever samples the caller happens to hold, which round-robin polling can
    /// leave several cycles old. `AppState` verifies a candidate's usage before
    /// committing to a switch, and falls through the list when one fails.
    ///
    /// - Parameters:
    ///   - active: the currently active account.
    ///   - candidates: every other account (already filtered to the same provider).
    ///   - usageByAccount: latest usage sample per account id.
    ///   - isSwitchable: whether an account can actually be switched to right now
    ///     (has a stored backup token and isn't flagged expired).
    ///   - activeSampledThisCycle: whether the active account's sample was taken
    ///     by the refresh cycle that is asking. Fresh readings are trusted even
    ///     without a parseable `resets_at` (the number is current by
    ///     construction); only RETAINED readings need the strict expiry check,
    ///     because they are the ones that can describe a window that has since
    ///     reset.
    ///   - targetIds: the accounts the user allows switching to, in priority
    ///     order. **Empty means every account is allowed** — the behaviour
    ///     before the setting existed.
    ///   - policy: how to order the qualifying candidates.
    ///   - threshold: switch when the active binding utilization is >= this (e.g. 90).
    ///   - hysteresisPct: a candidate must sit at least this far below the threshold
    ///     to be eligible (e.g. 10 -> candidate must be <= threshold - 10).
    ///   - now: injected clock, for window-expiry checks and testability.
    /// - Returns: eligible accounts ordered best-first; empty means stay put.
    static func rankedTargets(
        active: Account,
        candidates: [Account],
        usageByAccount: [UUID: UsageAPIResponse],
        isSwitchable: (Account) -> Bool,
        activeSampledThisCycle: Bool,
        targetIds: [UUID] = [],
        policy: AutoSwitchPolicy = .mostHeadroom,
        threshold: Double,
        hysteresisPct: Double,
        asOf now: Date = Date()
    ) -> [Account] {
        // 1) Only act once the active account has reached the threshold on a
        //    window we watch. Unknown active usage -> do nothing (can't decide).
        //    The trigger to move the user off an account must never rest on a
        //    RETAINED reading whose expiry we cannot establish — but a reading
        //    this very cycle fetched is current whether or not the endpoint
        //    sent a parseable resets_at.
        guard let activeUtil = bindingUtilization(usageByAccount[active.id], asOf: now, requireKnownWindow: !activeSampledThisCycle),
              activeUtil >= threshold else {
            return []
        }

        // 2) Keep only switchable candidates KNOWN to sit safely below the
        //    threshold. A candidate with no usable reading is NOT eligible:
        //    accounts are polled round-robin, so "no sample" usually means "not
        //    reached yet" rather than "idle" — treating it as a failover fallback
        //    let an automatic switch land on an account that was itself maxed
        //    out, which is the exact failure this feature exists to prevent.
        let ceiling = threshold - hysteresisPct
        // 3) Honour the user's list. An empty list is "no restriction", not
        //    "nothing allowed": the setting starts empty, and a fresh upgrade
        //    must behave exactly as before. A non-empty list with no qualifying
        //    member means stay put — it must NOT fall back to every account.
        let allowed = Set(targetIds)
        let qualifying = candidates
            .compactMap { candidate -> (Account, Double)? in
                guard candidate.id != active.id, isSwitchable(candidate),
                      allowed.isEmpty || allowed.contains(candidate.id),
                      let util = bindingUtilization(usageByAccount[candidate.id], asOf: now),
                      util <= ceiling else { return nil }
                return (candidate, util)
            }

        // 4) Order them. `listOrder` needs a list to order by, so with no
        //    selection it means the same thing as `mostHeadroom`.
        if policy == .listOrder, !targetIds.isEmpty {
            let rank = Dictionary(targetIds.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            return qualifying
                .sorted { (rank[$0.0.id] ?? .max) < (rank[$1.0.id] ?? .max) }
                .map { $0.0 }
        }
        // Most headroom first (lowest known utilization).
        return qualifying
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }
}
