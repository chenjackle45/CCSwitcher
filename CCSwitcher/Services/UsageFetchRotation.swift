import Foundation

/// Which accounts a refresh cycle asks the usage endpoint about, and the
/// bookkeeping that decides it.
///
/// A value type rather than two loose properties on `AppState` so the sequence
/// can be driven in a test: "the sweep happens on the first cycle and never
/// again" is a statement about consecutive cycles, and a function that is told
/// which kind of cycle it is cannot check it.
///
/// Parked accounts are filtered out before they get here; parking is decided
/// elsewhere and stays there.
struct UsageFetchRotation {
    /// Round-robin position over the non-active accounts.
    private var cursor = 0
    /// Cleared by the first cycle, whether or not that cycle succeeded: a
    /// sweep that failed must not repeat itself every five minutes.
    private var sweepPending = true

    init() {}

    /// The accounts to sample this cycle, in request order.
    ///
    /// The first cycle of a launch takes every eligible account once. Usage
    /// samples are not persisted, so otherwise a fresh launch shows the active
    /// account plus one other and leaves the rest blank for up to half an hour.
    /// Every later cycle is the active account plus one other in rotation,
    /// which is what keeps the usage endpoint from rate-limiting us.
    mutating func next(eligible: [Account]) -> (targets: [Account], isSweep: Bool) {
        let others = eligible.filter { !$0.isActive }
        var targets = eligible.filter { $0.isActive }

        if sweepPending {
            sweepPending = false
            targets.append(contentsOf: others)
            // The cursor is left alone: this cycle sampled everyone, so there
            // is no "next one" to advance past.
            return (targets, true)
        }
        guard !others.isEmpty else { return (targets, false) }
        targets.append(others[cursor % others.count])
        cursor += 1
        return (targets, false)
    }
}
