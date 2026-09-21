import Foundation

private let log = FileLog("Gate")

/// Serializes every operation that mutates live credentials.
///
/// It works alongside `isSwitching` / `isLoggingIn` / `isRefreshing`, which are
/// still there and do a different job: those make a repeated user action stand
/// down ("a switch is already running, ignore this click") while the gate makes
/// unrelated operations take turns. Before it, the combinations nobody wrote a
/// flag for ran concurrently: a refresh reading the keychain while a switch was
/// halfway through swapping it, an auto-switch verifying a candidate while a
/// re-authentication rewrote the store underneath it. Both interleavings end the
/// same way — one account's credential filed under another's id.
///
/// Non-reentrant on purpose. A holder that calls another gated operation would
/// wait for itself forever, and that deadlock is a bug in the caller: the
/// convention is to release before calling `refresh()`.
///
/// Waiters are resumed first-in-first-out, and the gate is handed straight to
/// the next waiter rather than released and re-acquired, so a queued operation
/// cannot be overtaken by one that arrives later.
@MainActor
final class CredentialGate {
    private var isHeld = false
    private var waiters: [(label: String, continuation: CheckedContinuation<Void, Never>)] = []

    func acquire(_ label: String) async {
        if !isHeld {
            isHeld = true
            log.info("[gate] \(label) acquired")
            return
        }
        log.info("[gate] \(label) waiting, \(waiters.count + 1) queued")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append((label, continuation))
        }
        log.info("[gate] \(label) acquired after waiting")
    }

    func release(_ label: String) {
        guard isHeld else {
            log.warning("[gate] \(label) released a gate it did not hold")
            return
        }
        guard !waiters.isEmpty else {
            isHeld = false
            log.info("[gate] \(label) released")
            return
        }
        let next = waiters.removeFirst()
        log.info("[gate] \(label) released, handing off to \(next.label)")
        next.continuation.resume()
    }

    /// Runs `body` while holding the gate, releasing it even when `body` throws.
    func withGate<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        await acquire(label)
        defer { release(label) }
        return try await body()
    }
}
