import SwiftUI
import Combine
import WidgetKit

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var activeAccount: Account?
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:]
    /// When each account's usage sample was actually taken. Accounts are polled
    /// round-robin (active + one other per cycle), so a card can be showing a
    /// reading several cycles old; without this the UI would render a stale
    /// percentage exactly like a live one, and auto-switch could not tell
    /// which samples this cycle actually verified.
    @Published var accountUsageSampledAt: [UUID: Date] = [:]
    @Published var usageSummary: UsageSummary = .empty
    @Published var recentActivity: [DailyActivity] = []
    @Published var activeSessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var isLoggingIn = false
    @Published var errorMessage: String?
    @Published var claudeAvailable = false
    @Published var lastUsageRefresh: Date?
    @Published var costSummary: CostSummary = .empty
    @Published var activityStats: ActivityStats = .empty

    // Store errors as special struct to surface in UI
    struct UsageErrorState {
        let isExpired: Bool
        let isRateLimited: Bool
        let message: String
    }
    
    @Published var accountUsageErrors: [UUID: UsageErrorState] = [:]

    // MARK: - Weekly Consumption Summary (all accounts)

    /// Aggregates the 7-day utilization reported by every account into a single
    /// weekly-consumption snapshot: the sum of all accounts' weekly usage
    /// percentages, the average utilization, and how many accounts reported data.
    struct WeeklyConsumptionSummary {
        /// Sum of every account's `seven_day.utilization` (%). Can exceed 100
        /// when several accounts have consumed part of their own weekly quota.
        let totalUtilization: Double
        /// Simple average of the accounts that reported weekly data.
        let averageUtilization: Double
        /// Number of accounts with a usable seven-day sample right now.
        let sampledAccountCount: Int
        /// Total number of configured accounts.
        let accountCount: Int
        /// True when at least one account has reported weekly data.
        var hasData: Bool { sampledAccountCount > 0 }

        static let empty = WeeklyConsumptionSummary(
            totalUtilization: 0, averageUtilization: 0,
            sampledAccountCount: 0, accountCount: 0
        )
    }

    /// Computed from the latest per-account usage samples (`accountUsage`).
    /// The seven-day window is the natural "weekly consumption" metric each
    /// account already exposes; summing it answers "how much have all my
    /// accounts consumed this week?" at a glance.
    var weeklyConsumptionSummary: WeeklyConsumptionSummary {
        let now = Date()
        // Only samples describing the CURRENT weekly window count. Accounts are
        // polled round-robin, so a retained reading can outlive the window it
        // measured — adding it to the total reports quota that has since been
        // given back. A reading with no parseable reset is treated the same way:
        // its window cannot be established, so it cannot be shown as current.
        let samples: [Double] = accounts.compactMap { account in
            guard let window = accountUsage[account.id]?.sevenDay,
                  let utilization = window.utilization,
                  accountUsageSampledAt[account.id] != nil,
                  let resetsAt = window.resetsAtDate,
                  resetsAt > now else {
                return nil
            }
            return utilization
        }
        let total = samples.reduce(0, +)
        // The denominator stays the account count even with zero usable samples:
        // "0/8 in this cycle" is the honest reading, and hiding the badge (what
        // the empty summary did) made a stale card look like a fresh one.
        return WeeklyConsumptionSummary(
            totalUtilization: total,
            averageUtilization: samples.isEmpty ? 0 : total / Double(samples.count),
            sampledAccountCount: samples.count,
            accountCount: accounts.count
        )
    }
    // MARK: - Services

    private let claudeService = ClaudeService.shared
    private let statsParser = StatsParser.shared
    private let costParser = CostParser.shared
    private let activityParser = ActivityParser.shared
    private let keychain = KeychainService.shared

    /// Ties the live keychain credential to the account that owns it, so
    /// neither usage attribution nor a backup has to trust `~/.claude.json`'s
    /// identity block — which any running Claude Code session can rewrite.
    private let credentialAnchor = CredentialAnchorStore()

    /// Serializes every operation that touches live credentials. See
    /// `CredentialGate` for why the per-operation flags were not enough.
    private let credentialGate = CredentialGate()

    /// Which accounts auto-switch may switch to, and in what order.
    private let autoSwitchConfig = AutoSwitchConfig.shared

    private let accountsKey = "com.ccswitcher.accounts"
    private var refreshTimer: Timer?

    // MARK: - Usage polling state

    /// Re-entrancy guard: overlapping refreshes (timer + manual button + post-switch)
    /// would each burst per-account usage requests and trip the endpoint's rate limit.
    private var isRefreshing = false

    /// Who gets sampled each cycle: the active account plus ONE other in
    /// rotation, instead of all of them. The usage endpoint's rate limit is
    /// tight and shared with every running Claude Code session's own polling,
    /// so fewer requests per cycle beats a full sweep — except for the first
    /// cycle after launch, which fills the blank cards once. See the type.
    private var usageFetchRotation = UsageFetchRotation()

    /// Per-account "leave it alone until" timestamps. The usage endpoint enforces a
    /// long-window per-account quota - observed Retry-After values run into tens of
    /// minutes - so once an account is rate-limited, polling it again before the
    /// server-given deadline just burns more quota. Stale samples are kept meanwhile.
    private var usageRetryNotBefore: [UUID: Date] = [:]

    /// When the current/most recent refresh cycle began. Auto-switch uses it to
    /// tell which usage samples were taken by THIS cycle (already fresh — no
    /// verification request needed) versus retained from earlier ones.
    private var lastCycleStart: Date = .distantPast

    /// One switch (manual or automatic) may mutate live credentials at a time.
    /// `switchTo` suspends across subprocess and keychain work while the UI stays
    /// responsive, so without this a second switch — a user click during an
    /// auto-switch verification, or vice versa — could interleave keychain and
    /// ~/.claude.json writes with the first.
    /// True from the moment a switch is requested — including while it waits for
    /// the gate — so the UI can say "working" instead of looking dead. Separate
    /// from `isLoading`, which belongs to the refresh cycle: sharing one flag
    /// meant a refresh finishing mid-switch turned the spinner off.
    @Published private(set) var isSwitching = false

    // MARK: - Auto-switch

    /// Whether proactive auto-switch is on (written by SettingsView via @AppStorage).
    private var autoSwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoSwitchEnabled")
    }

    /// Utilization percentage at which we switch. Defaults to 90 when unset.
    private var autoSwitchThreshold: Double {
        let stored = UserDefaults.standard.double(forKey: "autoSwitchThreshold")
        return stored == 0 ? 90 : stored
    }

    /// A candidate must sit at least this far below the threshold to be eligible,
    /// so two accounts hovering at the line never ping-pong.
    private let autoSwitchHysteresis: Double = 10

    /// Minimum gap between two automatic switches, to avoid rapid flip-flopping.
    private let autoSwitchCooldown: TimeInterval = 300

    private var lastAutoSwitchAt: Date?
    private var isEvaluatingAutoSwitch = false

    // MARK: - Initialization

    init() {
        log.info("[init] Loading accounts from UserDefaults...")
        loadAccounts()
        log.info("[init] Loaded \(self.accounts.count) accounts, active: \(self.activeAccount?.id.uuidString ?? "none")")
    }

    // MARK: - Refresh

    /// Refresh everything, then decide whether to auto-switch.
    ///
    /// The two halves are deliberately separate: `refreshData()` holds the
    /// `isRefreshing` re-entrancy guard for its whole body, so evaluating
    /// auto-switch *inside* it would mean the `switchTo() -> refresh()` that
    /// follows an automatic switch gets swallowed by that guard — leaving the
    /// spinner stuck and the new active account showing pre-switch numbers.
    /// And when `refreshData()` did NOT run (login in progress, another refresh
    /// already running), auto-switch must not be evaluated either: it would act
    /// on state mid-mutation — swapping credentials during a login, or deciding
    /// on samples a concurrent refresh is rewriting.
    func refresh() async {
        guard await refreshData() else { return }
        await evaluateAutoSwitch()
    }

    /// Returns true only when a full refresh actually ran.
    private func refreshData() async -> Bool {
        guard !isLoggingIn else {
            log.info("[refresh] Skipping: login in progress")
            return false
        }
        guard !isRefreshing else {
            log.info("[refresh] Skipping: refresh already in progress")
            return false
        }
        isRefreshing = true
        defer { isRefreshing = false }
        lastCycleStart = Date()
        isLoading = true
        errorMessage = nil

        claudeAvailable = await claudeService.isClaudeAvailable()
        log.info("[refresh] Claude available: \(self.claudeAvailable)")

        // Everything that reads or writes live credentials runs under the gate.
        // The parsing further down deliberately does not: a switch must never
        // have to wait for a filesystem scan of every session log.
        await credentialGate.withGate("refresh") {
            // Resolved ONCE for the whole cycle and handed down. Each of the
            // three steps below used to resolve it for itself: three `security`
            // subprocesses and three full parses of ~/.claude.json per refresh,
            // and — because resolving also PERSISTS state transitions — three
            // chances for the cycle to act on three different answers.
            let liveOwner = await liveCredentialOwner()

            if claudeAvailable {
                do {
                    let status = try await claudeService.getAuthStatus()
                    updateActiveAccount(from: status, liveOwner: liveOwner)
                } catch {
                    log.error("[refresh] getAuthStatus failed: \(error.localizedDescription)")
                    errorMessage = error.localizedDescription
                }
            }

            // Passive health check: reads the backup store, resolves nothing.
            await diagnoseTokenHealth(liveOwner: liveOwner)

            // Fetch usage limits for all accounts
            await fetchAllAccountUsage(liveOwner: liveOwner)
        }
        lastUsageRefresh = Date()

        usageSummary = statsParser.getUsageSummary()
        recentActivity = statsParser.getRecentActivity(days: 7)
        activeSessions = statsParser.getActiveSessions()

        // JSONL parsing: walk filesystem once via the shared cache, then
        // pull aggregated outputs. The actor's executor is off the main
        // thread, so awaiting these does not block the UI.
        await SessionParseCacheV2.shared.refreshFromFilesystem()
        let cost = await costParser.getCostSummary()
        let activity = await activityParser.getTodayStats()
        costSummary = cost
        activityStats = activity

        log.info("[refresh] Usage: weekly=\(self.usageSummary.weeklyMessages) msgs, \(self.activeSessions.count) active sessions, today=$\(String(format: "%.2f", cost.todayCost)) turns=\(activity.conversationTurns)")

        updateWidgetData()
        isLoading = false
        return true
    }

    func startAutoRefresh(interval: TimeInterval = 300) {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Credential ownership

    /// Who the credential currently in the keychain belongs to.
    ///
    /// Every read of the live credential goes through this: `~/.claude.json`
    /// naming an account is not evidence that the token beside it is that
    /// account's, and acting as though it were is what filed one account's
    /// usage on another's card and overwrote its stored token.
    private func liveCredentialOwner() async -> LiveCredentialOwner {
        let accessToken = await keychain.readClaudeTokenAsync().flatMap(ClaudeService.extractAccessToken(from:))
        let claimedEmail = await keychain.readOAuthAccountEmailAsync()
        let claimedId = claimedEmail.flatMap { email in accounts.first(where: { $0.email == email })?.id }
        return credentialAnchor.resolveOwner(accessToken: accessToken, claimedAccountId: claimedId)
    }

    /// Record that the live credential is `accountId`'s. Only for the moments
    /// CCSwitcher established that itself — a completed switch, login, re-auth
    /// or capture — never on the identity block's say-so.
    private func anchorLiveCredential(to accountId: UUID) async {
        guard let tokenJSON = await keychain.readClaudeTokenAsync(),
              let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else { return }
        credentialAnchor.anchor(accountId: accountId, accessToken: accessToken)
    }

    /// Back up the live credential as `account`'s, but only when it really is.
    /// Storing it otherwise overwrites one account's saved token with another's,
    /// which survives every later switch and silently spends the wrong quota.
    ///
    /// Deliberately does NOT anchor afterwards: a successful backup is not
    /// evidence of a new pairing, and re-anchoring here would clear a known
    /// desync the moment the identity block happened to agree again.
    @discardableResult
    private func captureLiveCredential(as account: Account) async -> Bool {
        guard await liveCredentialOwner().credentialAccountId == account.id else {
            log.warning("[capture] Live credential is not confirmed to be \(account.email)'s; skipping backup rather than storing it under the wrong account")
            return false
        }
        // The token is this account's; the identity block travelling with it
        // must be too, or the backup pairs one account's credential with
        // another's identity.
        let claimedEmail = await keychain.readOAuthAccountEmailAsync()
        guard claimedEmail == account.email else {
            log.warning("[capture] Identity block names \(claimedEmail ?? "nobody"), not \(account.email); skipping backup")
            return false
        }
        return await claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
    }

    /// Capture + anchor after CCSwitcher itself completed a login for `account`.
    /// The login is the proof of ownership, so this is one of the only paths
    /// allowed to establish a pairing — but the credential it just minted must
    /// still carry `expectedEmail`, or what completed was a login to someone else.
    @discardableResult
    private func captureAfterLogin(as account: Account, expectedEmail: String) async -> Bool {
        let claimedEmail = await keychain.readOAuthAccountEmailAsync()
        guard claimedEmail == expectedEmail else {
            log.error("[capture] Post-login identity block names \(claimedEmail ?? "nobody"), expected \(expectedEmail); not capturing")
            return false
        }
        let captured = await claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
        if captured { await anchorLiveCredential(to: account.id) }
        return captured
    }

    /// Backup lookups go through the keychain's off-main entry point; the
    /// decode happens here because `AccountBackup` is not `Sendable`.
    private enum BackupLookup {
        case found(AccountBackup)
        case missing
        case storeUnavailable
    }

    private func lookupBackup(forAccountId accountId: String) async -> BackupLookup {
        switch await keychain.lookupAccountBackupDataAsync(forAccountId: accountId) {
        case .found(let data):
            guard let decoded = try? JSONDecoder().decode(AccountBackup.self, from: data) else {
                return .storeUnavailable
            }
            return .found(decoded)
        case .missing:
            return .missing
        case .storeUnavailable:
            return .storeUnavailable
        }
    }

    /// For call sites where "missing" and "unavailable" mean the same thing.
    private func backup(forAccountId accountId: String) async -> AccountBackup? {
        if case .found(let backup) = await lookupBackup(forAccountId: accountId) { return backup }
        return nil
    }

    private func saveBackup(_ backup: AccountBackup, forAccountId accountId: String) async -> Bool {
        guard let data = try? JSONEncoder().encode(backup) else { return false }
        return await keychain.saveAccountBackupDataAsync(data, forAccountId: accountId)
    }

    // MARK: - Account Management

    func loginNewAccount() async {
        log.info("[loginNewAccount] ===== Starting login new account flow =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[loginNewAccount] Aborted: Claude CLI not found")
            return
        }
        // A switch in flight or another login means the user is already in the
        // middle of a credential change: stand down rather than queue.
        guard !isSwitching, !isLoggingIn else {
            log.warning("[loginNewAccount] Skipped: a switch or another login is in progress")
            return
        }

        isLoggingIn = true
        errorMessage = nil

        let shouldRefresh = await credentialGate.withGate("login") {
            await performLoginNewAccount()
        }
        isLoggingIn = false

        if shouldRefresh {
            await refresh()
            log.info("[loginNewAccount] ===== Login completed =====")
        }
    }

    /// The login itself. **The caller must hold `credentialGate`** and owns the
    /// follow-up `refresh()`. Returns whether the caller should refresh.
    private func performLoginNewAccount() async -> Bool {
        do {
            // 1. Back up current account (token + oauthAccount) before login overwrites them
            if let current = activeAccount {
                log.info("[loginNewAccount] Step 1: Backing up current account (\(current.email))...")
                let backed = await captureLiveCredential(as: current)
                log.info("[loginNewAccount] Step 1: Backup result: \(backed)")
            } else {
                log.info("[loginNewAccount] Step 1: No active account, skipping backup")
            }

            // 2. Run `claude auth login` — this overwrites both keychain and ~/.claude.json
            log.info("[loginNewAccount] Step 2: Running `claude auth login`...")
            try await claudeService.login()
            log.info("[loginNewAccount] Step 2: Login process completed")

            // 3. Read the new identity from ~/.claude.json
            log.info("[loginNewAccount] Step 3: Reading post-login state...")
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 3: Not logged in after login!")
                return false
            }
            guard let email = status.email else {
                errorMessage = shadowedIdentityMessage(status)
                log.error("[loginNewAccount] Step 3: CLI reports authMethod=\(status.authMethod ?? "nil") without an account identity")
                return false
            }
            log.info("[loginNewAccount] Step 3: Logged in as \(email)")

            // 4. Check for duplicate — if exists, refresh its backup and make it
            // the active account. The login DID change what the CLI is
            // authenticated as; returning without updating our model left the
            // menu bar and switcher presenting an account the CLI was no longer
            // using. The capture CAN also fail (e.g. the backup store refuses
            // writes while unreadable); claiming "credentials refreshed" then
            // would leave a stale backup behind an explicit success message.
            if let existing = accounts.firstIndex(where: { $0.email == email }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup and marking it active")
                // A just-completed login is itself the proof of ownership — the
                // CLI minted this credential for this account — so capture and
                // anchor directly instead of asking the (now superseded) anchor.
                let captured = await captureAfterLogin(as: accounts[existing], expectedEmail: email)
                for i in accounts.indices {
                    accounts[i].isActive = (i == existing)
                }
                accounts[existing].lastUsed = Date()
                activeAccount = accounts[existing]
                // A login is a deliberate account choice; grant it the same
                // auto-switch grace period a manual switch gets.
                lastAutoSwitchAt = Date()
                saveAccounts()
                if captured {
                    errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                } else {
                    log.error("[loginNewAccount] Step 4: Backup capture FAILED for existing account")
                    errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                }
                return false
            }

            // 5. Create new account and capture credentials (token + oauthAccount)
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            log.info("[loginNewAccount] Step 5: Created account, id=\(account.id)")

            let captured = await captureAfterLogin(as: account, expectedEmail: email)
            if !captured {
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 5: Capture failed!")
                return false
            }

            // 6. Mark new account as active
            for i in accounts.indices {
                accounts[i].isActive = false
            }
            accounts.append(account)
            activeAccount = account
            // A login is a deliberate account choice; grant it the same
            // auto-switch grace period a manual switch gets.
            lastAutoSwitchAt = Date()
            saveAccounts()
            log.info("[loginNewAccount] Step 6: New account active. Total: \(self.accounts.count)")

            return true
        } catch {
            errorMessage = error.localizedDescription
            log.error("[loginNewAccount] Error: \(error.localizedDescription)")
            return false
        }
    }

    func updateAccountLabel(_ account: Account, label: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        accounts[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        if accounts[index].isActive {
            activeAccount = accounts[index]
        }
        saveAccounts()
        updateWidgetData()
        log.info("[updateAccountLabel] Set label for \(account.email): \(trimmed ?? "nil")")
    }

    func removeAccount(_ account: Account) async {
        log.info("[removeAccount] Removing account \(account.id)")
        // Same stand-down rule the other credential operations use: a removal
        // clicked during a switch or a login would otherwise queue behind it and
        // then act on what the list looked like before.
        guard !isSwitching, !isLoggingIn else {
            log.warning("[removeAccount] Skipped: a switch or a login is in progress")
            errorMessage = String(localized: "A switch or a login is in progress; try removing the account again in a moment.", bundle: L10n.bundle)
            return
        }
        isSwitching = true
        defer { isSwitching = false }

        // Removing drops the stored backup and marks the anchor unknown, both of
        // which a concurrent switch or refresh would otherwise read half-done.
        let removed = await credentialGate.withGate("remove") { () -> Bool in
            // Waiting for the gate can span another switch, so "was this the
            // active account?" is answered now, not from the copy the view
            // handed over.
            guard accounts.contains(where: { $0.id == account.id }) else {
                log.info("[removeAccount] Account is already gone; nothing to do")
                return false
            }
            let wasActive = activeAccount?.id == account.id

            await keychain.removeAccountBackupAsync(forAccountId: account.id.uuidString)
            credentialAnchor.forget(accountId: account.id)
            accounts.removeAll { $0.id == account.id }
            // Drop every per-account cache too, or a re-added account inherits
            // the removed one's readings, error banner and rate-limit park.
            accountUsage[account.id] = nil
            accountUsageSampledAt[account.id] = nil
            accountUsageErrors[account.id] = nil
            usageRetryNotBefore[account.id] = nil
            autoSwitchConfig.prune(existingAccountIds: Set(accounts.map(\.id)))
            saveAccounts()

            // The removed account is still the one the CLI is signed in to, so
            // hand over for real. The old code marked the successor active FIRST
            // and then called `switchTo`, which saw "target is already active"
            // and returned — so the credentials were never swapped: the UI moved
            // on while every API call still went to the deleted account.
            //
            // Order matters: `forget` above already made the live credential's
            // owner unknown, so the switch's own "back up the outgoing account
            // first" step sees no confirmed owner and skips — which is what
            // stops it from re-creating the backup just deleted.
            if wasActive {
                if let successor = accounts.first {
                    log.info("[removeAccount] Removed the active account; switching to \(successor.id)")
                    if await performSwitch(to: successor) == nil {
                        // Leaving `activeAccount` pointing at the account just
                        // deleted would keep it in the menu bar and stop the
                        // usage cycle from sampling anything (it targets whoever
                        // is active). Better to show nothing than a ghost.
                        log.error("[removeAccount] Could not switch to \(successor.id)")
                        // `performSwitch` already put the reason — and the right
                        // remedy — in `errorMessage`; which remedy applies
                        // depends on how far the switch got, so only the part
                        // that is true in every case is added here.
                        let reason = errorMessage.map { " \($0)" } ?? ""
                        errorMessage = String(localized: "Removed \(account.email), but the switch to \(successor.email) did not complete.", bundle: L10n.bundle) + reason
                        activeAccount = nil
                    }
                } else {
                    // Last account removed: nothing to hand over to.
                    activeAccount = nil
                }
            }
            log.info("[removeAccount] Done. Remaining accounts: \(self.accounts.count)")
            return true
        }

        // Outside the gate: the widget snapshot and the cards still describe the
        // account that was just removed, and nothing else would rewrite them
        // until the next timer tick five minutes later.
        if removed {
            let carriedError = errorMessage
            await refresh()
            // `refresh()` clears errorMessage; a removal that failed its
            // hand-over has something to say that outlives it.
            if let carriedError { errorMessage = carriedError }
        }
    }

    func switchTo(_ account: Account) async {
        // No active account is a legitimate state to switch FROM: it is what is
        // left after removing the account in use when the hand-over could not
        // complete, and the message shown there tells the user to switch
        // manually. Returning here would make that instruction a lie.
        guard activeAccount?.id != account.id else {
            log.info("[switchTo] No switch needed (already the active account)")
            return
        }

        log.info("[switchTo] ===== Switching from \(self.activeAccount?.email ?? "no active account") to \(account.email) =====")

        // A switch already in flight or a running login means the user clicked
        // twice or clicked during a login: stand down rather than queue, so the
        // second click cannot fire a switch the user has since stopped wanting.
        guard !isSwitching, !isLoggingIn else {
            log.warning("[switchTo] Skipped: another switch or a login is in progress")
            return
        }

        isSwitching = true
        defer { isSwitching = false }
        let outcome = await credentialGate.withGate("switch") {
            await performSwitch(to: account)
        }

        guard let outcome else { return }

        await refresh()
        // `refresh()` clears errorMessage, so surface the warning afterwards.
        if let shadowedBy = outcome.shadowedBy {
            errorMessage = String(localized: "Switched to \(account.email), but the Claude CLI is authenticating via \(shadowedBy) instead of the stored login, so it will not use this account.", bundle: L10n.bundle)
        }
        log.info("[switchTo] ===== Switch completed =====")
    }

    /// The switch itself. **The caller must hold `credentialGate`**; it also owns
    /// the follow-up `refresh()`, which must happen after the gate is released or
    /// the refresh would wait for a gate its own caller is holding.
    ///
    /// Returns nil when no switch happened (state moved while waiting, or the
    /// switch failed) — the caller then skips the refresh.
    private func performSwitch(to account: Account) async -> ClaudeService.SwitchOutcome? {
        // State is re-read here, not in the caller: waiting for the gate can
        // span a login, another switch, or an account removal, any of which
        // makes the decision taken before the wait stale.
        let currentActive = activeAccount
        guard currentActive?.id != account.id else {
            log.info("[switchTo] Nothing left to do after waiting for the gate")
            return nil
        }
        // `removeAccount` calls this with the removed account still marked
        // active, which is what makes the hand-over work: the credential being
        // replaced is that account's.
        guard accounts.contains(where: { $0.id == account.id }) else {
            log.warning("[switchTo] Target account no longer exists; standing down")
            return nil
        }

        // Pre-switch: resolve the target's backup ONCE and hand it down.
        // "The store is briefly unreadable" and "no backup exists" are
        // different problems with different fixes — don't send the user to
        // re-authenticate over a locked keychain. Passing the resolved backup
        // into switchAccount also removes its second lookup, which collapsed
        // exactly this distinction one layer down.
        // Decoded here, right before the call that hands it off: a value
        // produced inside a helper is in that helper's isolation region, and
        // Swift 6 will not let it cross into `switchAccount` (which runs off the
        // main actor). `AccountBackup` cannot be `Sendable` — it carries
        // `AnyCodable` — so the encoded form travels and the decode stays local.
        let targetBackupData: Data
        switch await keychain.lookupAccountBackupDataAsync(forAccountId: account.id.uuidString) {
        case .found(let data):
            targetBackupData = data
        case .missing:
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            return nil
        case .storeUnavailable:
            log.error("[switchTo] ABORT: backup store unreadable right now")
            errorMessage = String(localized: "Credential storage is temporarily unavailable. Try again shortly.", bundle: L10n.bundle)
            return nil
        }

        guard let targetBackup = try? JSONDecoder().decode(AccountBackup.self, from: targetBackupData) else {
            log.error("[switchTo] ABORT: stored backup for target account did not decode")
            errorMessage = String(localized: "Credential storage is temporarily unavailable. Try again shortly.", bundle: L10n.bundle)
            return nil
        }

        // "A backup exists" and "a backup that can log anyone in exists" are
        // different facts. A capture taken while the CLI held no live login
        // stores an intact envelope around two empty secrets, and it reads as
        // present everywhere else in the app. Writing it would trade a working
        // session for a dead one.
        guard targetBackup.hasUsableCredentials else {
            log.error("[switchTo] ABORT: backup for target account carries no OAuth secret")
            errorMessage = String(localized: "The stored credentials for \(account.email) are empty. Use re-authenticate to sign in again.", bundle: L10n.bundle)
            return nil
        }

        // Any switch, deliberate or automatic, restarts the auto-switch cooldown:
        // a user who knowingly picks an account sitting at 95% must not be
        // auto-switched away from it seconds later by the refresh that follows.
        lastAutoSwitchAt = Date()

        // Whether the credential about to be backed up really is the outgoing
        // account's. Resolved here, where the account list lives, and handed
        // down for the same reason `targetBackup` is: the switch must not
        // re-derive it from the identity block one layer lower.
        let liveCredentialIsSource: Bool
        if let currentActive {
            liveCredentialIsSource = await liveCredentialOwner().credentialAccountId == currentActive.id
        } else {
            // Nothing to back up, so nothing to confirm ownership of.
            liveCredentialIsSource = false
        }

        do {
            let outcome = try await claudeService.switchAccount(from: currentActive, to: account, targetBackup: targetBackup, liveCredentialIsSource: liveCredentialIsSource)

            // CCSwitcher just wrote this credential for this account — the one
            // moment the pairing is known first-hand rather than inferred.
            await anchorLiveCredential(to: account.id)

            for i in accounts.indices {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = Date()
                }
            }
            activeAccount = account
            saveAccounts()
            return outcome
        } catch {
            errorMessage = error.localizedDescription
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Auto-switch

    /// Evaluate whether the active account has reached the threshold and, if so,
    /// switch to the same-provider account with the most quota left.
    /// Called after every completed refresh. Safe to call repeatedly.
    ///
    /// Candidates are ranked from whatever samples we hold, then the chosen one
    /// is VERIFIED before committing: round-robin polling can leave a candidate's
    /// sample several cycles old, and quota may have been consumed on it from
    /// another device meanwhile. A sample taken by this very cycle counts as
    /// verified; otherwise one fresh reading is taken — a single request per
    /// (rare, threshold-gated, cooldown-gated) switch attempt, not the per-cycle
    /// burst the round-robin exists to prevent.
    private func evaluateAutoSwitch() async {
        guard autoSwitchEnabled, !isEvaluatingAutoSwitch else { return }
        guard !isLoggingIn, !isSwitching, let active = activeAccount else { return }

        // Cooldown: never auto-switch more than once per window.
        if let last = lastAutoSwitchAt, Date().timeIntervalSince(last) < autoSwitchCooldown {
            return
        }

        // Cheap pre-check, outside the gate: reading samples already in memory
        // costs nothing, and almost every refresh stops right here. Only once
        // the threshold is actually reached is it worth queueing behind whatever
        // else is touching credentials.
        let activeSampledThisCycle = (accountUsageSampledAt[active.id] ?? .distantPast) >= lastCycleStart
        guard let activeUtil = AutoSwitchEngine.bindingUtilization(
                accountUsage[active.id],
                requireKnownWindow: !activeSampledThisCycle
              ),
              activeUtil >= autoSwitchThreshold else {
            return
        }

        isEvaluatingAutoSwitch = true
        defer { isEvaluatingAutoSwitch = false }

        let switched = await credentialGate.withGate("autoSwitch") {
            await performAutoSwitch()
        }

        if switched { await refresh() }
    }

    /// Candidate verification and the switch itself. **The caller must hold
    /// `credentialGate`**: verification refreshes a candidate's stored
    /// credential and writes it back, which is exactly the work a manual switch
    /// or a re-authentication must not interleave with.
    ///
    /// Returns whether a switch actually happened.
    private func performAutoSwitch() async -> Bool {
        // Everything decided before the wait is re-checked here.
        guard !isLoggingIn, !isSwitching, let active = activeAccount else {
            log.info("[autoSwitch] State changed while waiting for the gate; standing down")
            return false
        }
        if let last = lastAutoSwitchAt, Date().timeIntervalSince(last) < autoSwitchCooldown {
            log.info("[autoSwitch] Cooldown started while waiting for the gate; standing down")
            return false
        }

        // Only consider same-provider accounts (a Claude switch never touches Codex/Gemini).
        let candidates = accounts.filter { $0.provider == active.provider && $0.id != active.id }
        let activeSampledThisCycle = (accountUsageSampledAt[active.id] ?? .distantPast) >= lastCycleStart

        // The settings this evaluation is based on. Verification below suspends
        // on the network, and a list edited during that wait must not be acted
        // on with the old one — the user could have just unselected the very
        // account we are about to switch to.
        let selectedTargetIds = autoSwitchConfig.targetIds
        let selectedPolicy = autoSwitchConfig.policy

        // Reading the stored backups hits the keychain, which is now off the
        // main thread — so resolve the whole set in ONE store read and hand the
        // ranking engine a plain lookup. The engine stays a pure function.
        guard let usableBackupIds = await keychain.usableBackupIdsAsync() else {
            // The store is unreadable right now; every candidate would look
            // unswitchable, which is not the same as being unswitchable.
            log.warning("[autoSwitch] Backup store unreadable; standing down this cycle")
            return false
        }
        let switchableIds = Set(candidates.filter {
            usableBackupIds.contains($0.id.uuidString) && accountUsageErrors[$0.id]?.isExpired != true
        }.map(\.id))

        let ranked = AutoSwitchEngine.rankedTargets(
            active: active,
            candidates: candidates,
            usageByAccount: accountUsage,
            isSwitchable: { switchableIds.contains($0.id) },
            activeSampledThisCycle: activeSampledThisCycle,
            targetIds: selectedTargetIds,
            policy: selectedPolicy,
            threshold: autoSwitchThreshold,
            hysteresisPct: autoSwitchHysteresis
        )
        guard !ranked.isEmpty else {
            if !selectedTargetIds.isEmpty {
                log.info("[autoSwitch] Threshold reached but none of the selected accounts qualify; staying put")
            }
            return false
        }

        let activeUtil = AutoSwitchEngine.bindingUtilization(accountUsage[active.id]) ?? -1
        let ceiling = autoSwitchThreshold - autoSwitchHysteresis
        log.info("[autoSwitch] Active \(active.id) at \(String(format: "%.0f", activeUtil))% (threshold \(String(format: "%.0f", self.autoSwitchThreshold))%); candidates in order: \(ranked.map { $0.id.uuidString })")

        // At most ONE fresh verification request per evaluation. Later ranked
        // candidates only qualify via samples this cycle already took.
        var freshRequestBudget = 1
        for target in ranked {
            let usage: UsageAPIResponse?
            if let sampledAt = accountUsageSampledAt[target.id], sampledAt >= lastCycleStart {
                // Sampled by this very cycle — that IS a fresh reading.
                usage = accountUsage[target.id]
            } else if freshRequestBudget > 0 {
                freshRequestBudget -= 1
                usage = await fetchUsageNow(for: target)
                if let usage {
                    accountUsage[target.id] = usage
                    accountUsageSampledAt[target.id] = Date()
                    accountUsageErrors[target.id] = nil
                }
            } else {
                continue
            }

            guard let verifiedUtil = AutoSwitchEngine.bindingUtilization(usage),
                  verifiedUtil <= ceiling else {
                log.info("[autoSwitch] Candidate \(target.id) failed verification (\(AutoSwitchEngine.bindingUtilization(usage).map { String(format: "%.0f%%", $0) } ?? "no reading")); trying next")
                continue
            }

            // The verification above is a network round trip. Holding the gate
            // keeps other credential work out, but a user click that set
            // `isSwitching` while queueing still wins over an automatic switch.
            guard !isLoggingIn, !isSwitching, activeAccount?.id == active.id else {
                log.info("[autoSwitch] State changed during verification; standing down")
                return false
            }
            guard autoSwitchConfig.targetIds == selectedTargetIds,
                  autoSwitchConfig.policy == selectedPolicy else {
                log.info("[autoSwitch] Auto-switch settings changed during verification; standing down")
                return false
            }

            log.info("[autoSwitch] Switching to \(target.id), verified at \(String(format: "%.0f", verifiedUtil))%")
            lastAutoSwitchAt = Date()
            isSwitching = true
            defer { isSwitching = false }
            return await performSwitch(to: target) != nil
        }
        log.info("[autoSwitch] Threshold reached but no candidate verified; staying put")
        return false
    }

    /// Take one fresh usage reading for an account right now, refreshing its
    /// stored credential in place first if the access token has expired.
    /// Returns nil when no reading could be taken. 429s are parked with the same
    /// scheme the polling loop uses, so verification can never leak around it.
    private func fetchUsageNow(for account: Account) async -> UsageAPIResponse? {
        if let notBefore = usageRetryNotBefore[account.id], notBefore > Date() {
            log.info("[fetchUsageNow] \(account.id) is rate-limit parked; no fresh reading available")
            return nil
        }

        // Same rule as the polling loop: the live credential may only stand in
        // for the account it actually belongs to. Auto-switch verifies against
        // this reading, so a misattributed one would swap on the wrong quota.
        if account.isActive, await liveCredentialOwner().credentialAccountId != account.id {
            log.warning("[fetchUsageNow] Live credential is not confirmed to be \(account.email)'s; no reading available")
            return nil
        }

        let tokenJSON = account.isActive
            ? await keychain.readClaudeTokenAsync()
            : await backup(forAccountId: account.id.uuidString)?.token
        guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
            return nil
        }

        do {
            return try await claudeService.getUsageLimits(accessToken: accessToken)
        } catch ClaudeService.UsageError.expired where !account.isActive {
            // Handle every refresh outcome, not just success: collapsing a dead
            // grant (or a lost rotation) to a plain nil here would leave the
            // account looking healthy — stale usage still shown, still eligible
            // for auto-switch — until a later polling pass happened to notice.
            switch await refreshBackupInPlace(for: account) {
            case .refreshed(let refreshed):
                guard let newToken = ClaudeService.extractAccessToken(from: refreshed) else { return nil }
                return await usageRespectingParking(accessToken: newToken, account: account)
            case .grantRejected, .noBackup, .rotationLost:
                accountUsage[account.id] = nil
                accountUsageSampledAt[account.id] = nil
                accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Session expired. Re-authenticate (↻) to fix.", bundle: L10n.bundle))
                return nil
            case .storeUnavailable:
                // Nothing spent, nothing lost; keep the stale sample and retry
                // on a later cycle.
                return nil
            }
        } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
            park(account, retryAfter: retryAfter)
            return nil
        } catch {
            log.warning("[fetchUsageNow] \(account.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            return
        }
        guard !isSwitching, !isLoggingIn else {
            log.warning("[reauth] Skipped: a switch or another login is in progress")
            return
        }

        isLoggingIn = true
        errorMessage = nil

        let result = await credentialGate.withGate("reauth") {
            await performReauth(account)
        }
        isLoggingIn = false

        guard case .completed(let captured) = result else { return }
        await refresh()
        if captured {
            log.info("[reauth] ===== Re-authentication completed =====")
        } else {
            // Set AFTER refresh() — refresh clears errorMessage.
            errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
            log.error("[reauth] ===== Re-authentication finished, but the backup capture FAILED =====")
        }
    }

    private enum ReauthResult {
        case stopped
        /// The CLI is on the target account now; `captured` says whether the
        /// stored backup was updated to match.
        case completed(captured: Bool)
    }

    /// The re-authentication itself. **The caller must hold `credentialGate`**
    /// and owns the follow-up `refresh()`.
    private func performReauth(_ account: Account) async -> ReauthResult {
        // Waiting for the gate can span a removal of this very account.
        guard accounts.contains(where: { $0.id == account.id }) else {
            log.warning("[reauth] Target account no longer exists; standing down")
            return .stopped
        }
        do {
            // 1. Back up current active account before login overwrites it
            if let current = activeAccount, current.id != account.id {
                log.info("[reauth] Backing up current account before login...")
                await captureLiveCredential(as: current)
            }

            // 2. Run login
            log.info("[reauth] Running `claude auth login`...")
            try await claudeService.login()

            // 3. Verify the login result matches the target account
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                return .stopped
            }
            guard let email = status.email else {
                errorMessage = shadowedIdentityMessage(status)
                log.error("[reauth] CLI reports authMethod=\(status.authMethod ?? "nil") without an account identity")
                return .stopped
            }

            guard email == account.email else {
                errorMessage = String(localized: "Logged in as \(email), but expected \(account.email). Credentials not updated.", bundle: L10n.bundle)
                log.error("[reauth] Email mismatch: got \(email), expected \(account.email)")
                return .stopped
            }

            // 4. Capture the fresh token. The login just proved this credential
            // is this account's, so it also anchors — this is the way out of
            // a desync the user is told to take.
            let captured = await captureAfterLogin(as: account, expectedEmail: account.email)
            log.info("[reauth] Token capture result: \(captured)")

            // 5. Update account metadata. Done even when the capture failed —
            // the CLI really is on this account now — but a failed capture must
            // be surfaced, not folded into "completed": the stored backup is
            // still the OLD credential, so a later switch away and back would
            // fail while the UI claimed everything was refreshed.
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = status.orgName
                accounts[index].subscriptionType = status.subscriptionType

                // Mark this account as active (it's what the CLI is now using)
                for i in accounts.indices {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
                // A re-authentication is a deliberate account choice; grant it
                // the same auto-switch grace period a manual switch gets.
                lastAutoSwitchAt = Date()
                saveAccounts()
            }

            return .completed(captured: captured)
        } catch {
            errorMessage = error.localizedDescription
            log.error("[reauth] Error: \(error.localizedDescription)")
            return .stopped
        }
    }

    // MARK: - Usage

    /// Fetch usage with a single retry on 429 - but only when Retry-After is short.
    /// Observed Retry-After values run into tens of minutes (long-window per-account
    /// quota); retrying against those just burns more quota, so we rethrow instead
    /// and let the caller park the account until the deadline.
    /// `retryOn429: false` for the launch sweep. Every request in this loop is
    /// made while holding the credential gate, which switching accounts also
    /// needs; eight accounts each waiting out a Retry-After would hold it for
    /// minutes. The 429 still parks the account, so the next cycle picks it up.
    private func fetchUsageWithRetry(accessToken: String, retryOn429: Bool) async throws -> UsageAPIResponse {
        do {
            return try await claudeService.getUsageLimits(accessToken: accessToken)
        } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
            let delay = retryAfter ?? 15
            guard retryOn429, delay <= 30 else {
                throw ClaudeService.UsageError.rateLimited(retryAfter: retryAfter)
            }
            // Floor of 3s: "Retry-After: 0" is a momentary burst limiter, and an
            // immediate (~1s) retry was observed to fail again.
            log.warning("[fetchUsage] Rate-limited, retrying in \(String(format: "%.0f", max(delay, 3)))s...")
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 3) * 1_000_000_000))
            return try await claudeService.getUsageLimits(accessToken: accessToken)
        }
    }

    /// Park an account until the server-given deadline (floor 60s — "Retry-After:
    /// 0" burst rejections must still park; cap 1h; default 2min when no
    /// Retry-After was sent). Every path that observes a 429 goes through here.
    private func park(_ account: Account, retryAfter: TimeInterval?) {
        let parkFor = min(max(retryAfter ?? 120, 60), 3600)
        usageRetryNotBefore[account.id] = Date().addingTimeInterval(parkFor)
        log.warning("[fetchUsage] \(account.id) rate-limited; parked for \(String(format: "%.0f", parkFor))s")
    }

    /// Fetch usage, honouring a 429 by parking the account. The post-refresh
    /// recovery paths previously wrapped this call in `try?`, which swallowed a
    /// 429 without parking it — leaking around the parking scheme and re-hitting
    /// a rate-limited account every cycle.
    private func usageRespectingParking(accessToken: String, account: Account) async -> UsageAPIResponse? {
        do {
            return try await claudeService.getUsageLimits(accessToken: accessToken)
        } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
            park(account, retryAfter: retryAfter)
            return nil
        } catch {
            log.warning("[fetchUsage] Post-refresh retry failed for \(account.id): \(error.localizedDescription)")
            return nil
        }
    }

    private enum BackupRefreshOutcome {
        /// New credential JSON, persisted to the store.
        case refreshed(String)
        /// The endpoint decided the grant is invalid: the refresh token is dead
        /// (rotated elsewhere or revoked). Only re-authentication fixes this.
        case grantRejected
        /// No stored backup exists for this account at all.
        case noBackup
        /// The store cannot be read or written right now. Nothing was spent;
        /// heals by itself on a later cycle.
        case storeUnavailable
        /// Worst case: the rotation succeeded but the result could not be
        /// persisted even after a retry. The old refresh token is spent and the
        /// new credential is gone — only re-authentication brings this account
        /// back. Deliberately NOT held in memory: a credential that exists only
        /// in volatile state while some paths read the (dead) stored one is the
        /// split-brain that broke the previous attempt at this feature.
        case rotationLost
    }

    /// Refresh a non-active account's stored credential in place via the OAuth
    /// token endpoint — no keychain swap, so no race with running Claude Code
    /// sessions.
    private func refreshBackupInPlace(for account: Account) async -> BackupRefreshOutcome {
        let accountId = account.id.uuidString

        let backup: AccountBackup
        switch await lookupBackup(forAccountId: accountId) {
        case .found(let found):
            backup = found
        case .missing:
            log.warning("[refreshBackup] No stored backup for \(account.id)")
            return .noBackup
        case .storeUnavailable:
            log.warning("[refreshBackup] Store unreadable for \(account.id); trying again next cycle")
            return .storeUnavailable
        }

        // Prove the store is writable BEFORE spending the refresh token: the
        // endpoint can rotate it, and a rotation that cannot be persisted kills
        // the account (old token dead server-side, new one lost, manual re-login
        // the only way back). Re-saving what was just read is idempotent, and
        // the failures that matter here (locked keychain, denied prompt) are
        // conditions rather than blips, so this turns them into a harmless
        // "try again next cycle".
        guard await saveBackup(backup, forAccountId: accountId) else {
            log.error("[refreshBackup] Store not writable; skipping refresh for \(account.id) so its refresh token stays valid")
            return .storeUnavailable
        }

        switch await claudeService.refreshOAuthCredentials(backup.token) {
        case .success(let refreshed):
            if await saveBackup(AccountBackup(token: refreshed, oauthAccount: backup.oauthAccount), forAccountId: accountId) {
                return .refreshed(refreshed)
            }
            // The probe passed moments ago, so this is likely a blip — one retry.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await saveBackup(AccountBackup(token: refreshed, oauthAccount: backup.oauthAccount), forAccountId: accountId) {
                return .refreshed(refreshed)
            }
            log.error("[refreshBackup] Rotation succeeded but the store write failed twice for \(account.id); the account needs re-authentication")
            return .rotationLost

        case .rejected:
            log.warning("[refreshBackup] Refresh grant rejected for \(account.id); the refresh token is dead")
            return .grantRejected

        case .transient:
            log.warning("[refreshBackup] Refresh attempt for \(account.id) failed transiently (network/server); will retry")
            return .storeUnavailable
        }
    }

    private func fetchAllAccountUsage(liveOwner: LiveCredentialOwner) async {
        // Stale samples for the accounts not picked are kept; accounts parked
        // by a server-given Retry-After deadline never reach the rotation.
        let now = Date()
        let eligible = accounts.filter { (usageRetryNotBefore[$0.id] ?? .distantPast) <= now }
        let (targets, isLaunchSweep) = usageFetchRotation.next(eligible: eligible)

        // Only clear error state for the accounts we are about to sample;
        // the others keep both their stale usage and their error flags.
        for target in targets {
            accountUsageErrors[target.id] = nil
        }

        // For active account: use live keychain token (with delegated refresh on expiry)
        // For other accounts: use backup token (refreshed in place when expired)
        //
        // Resolved once per cycle: the live credential belongs to exactly one
        // account, and only that account's card may be filled from it. Reading
        // it for whoever the identity block currently names is what put one
        // account's percentages on the other's card for hours.
        let liveCredentialOwnerId = liveOwner.credentialAccountId

        var isFirstRequest = true
        for account in targets {
            // Stagger requests: a back-to-back burst (one request per account within
            // ~100ms) reliably gets all but one of them 429'd by the usage endpoint.
            if !isFirstRequest {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            isFirstRequest = false

            let tokenJSON: String?
            if account.isActive {
                guard liveCredentialOwnerId == account.id else {
                    log.warning("[fetchUsage] Live credential is not confirmed to be \(account.email)'s; taking no reading rather than filing someone else's")
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Can't tell which account the current sign-in belongs to. Switch accounts once to re-sync.", bundle: L10n.bundle))
                    continue
                }
                tokenJSON = await keychain.readClaudeTokenAsync()
            } else {
                tokenJSON = await backup(forAccountId: account.id.uuidString)?.token
            }
            guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
                // Say so on the card. Skipping silently leaves the "waiting for
                // usage data" hourglass up, and for an account whose backup has
                // no secret left that wait never ends — the health check names
                // it, but only in the log.
                log.warning("[fetchUsage] No token for \(account.email), skipping")
                accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Session expired. Re-authenticate (↻) to fix.", bundle: L10n.bundle))
                continue
            }
            do {
                let usage = try await fetchUsageWithRetry(accessToken: accessToken, retryOn429: !isLaunchSweep)
                accountUsage[account.id] = usage
                accountUsageSampledAt[account.id] = Date()
                accountUsageErrors[account.id] = nil
                // The binding number too: session and weekly alone cannot
                // explain an auto-switch decision once model-scoped limits
                // count, and this log is the only record of what was decided on.
                let binding = AutoSwitchEngine.bindingUtilization(usage).map { String(format: "%.0f", $0) } ?? "?"
                log.info("[fetchUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%, binding=\(binding)%")
            } catch ClaudeService.UsageError.forbidden {
                // No active Pro/Max subscription on this account (e.g. the plan
                // lapsed) - usage is meaningless until it recovers. Observed as:
                // {"error":{"type":"permission_error","message":"OAuth
                // authentication is currently not allowed for this organization."}}
                log.warning("[fetchUsage] \(account.email) forbidden (no active subscription?)")
                accountUsage[account.id] = nil
                accountUsageSampledAt[account.id] = nil
                accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "No active subscription on this account (OAuth not allowed).", bundle: L10n.bundle))
            } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
                // Rate-limited: park the account until the server-given deadline
                // and keep the last known sample - a stale percentage carrying
                // its "Updated Xm ago" label beats an error banner. The sample
                // timestamp is deliberately NOT bumped, so the UI keeps telling
                // the truth about how old the number is.
                park(account, retryAfter: retryAfter)
                if accountUsage[account.id] == nil {
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: true, message: String(localized: "API Rate Limited. Try again later.", bundle: L10n.bundle))
                }
            } catch ClaudeService.UsageError.expired {
                log.warning("[fetchUsage] Token expired for \(account.email)")
                if account.isActive {
                    // Active account: delegated refresh via `claude auth status` is safe (no keychain swap)
                    do {
                        _ = try await claudeService.getAuthStatus()
                        log.info("[fetchUsage] Delegated refresh completed for active account.")
                        // Re-read refreshed token and retry. A refresh rotates the
                        // credential in place without changing whose it is, so
                        // re-anchor to the same account — otherwise the anchor
                        // goes stale and the next cycle falls back to believing
                        // the identity block again.
                        if let refreshedJSON = await keychain.readClaudeTokenAsync(),
                           let refreshedToken = ClaudeService.extractAccessToken(from: refreshedJSON) {
                            // Only when the pairing was sound to begin with. A
                            // desynced credential that rotates must fall through
                            // to "owner unknown"; re-anchoring here would quietly
                            // undo that, which is the misfiling this all exists
                            // to stop.
                            if case .owned = liveOwner {
                                credentialAnchor.anchor(accountId: account.id, accessToken: refreshedToken)
                            }
                            if let usage = await usageRespectingParking(accessToken: refreshedToken, account: account) {
                                accountUsage[account.id] = usage
                                accountUsageSampledAt[account.id] = Date()
                                accountUsageErrors[account.id] = nil
                                log.info("[fetchUsage] Recovered \(account.email) via delegated refresh.")
                            }
                        }
                    } catch {
                        log.error("[fetchUsage] Delegated refresh failed for active account: \(error.localizedDescription)")
                        accountUsage[account.id] = nil
                        accountUsageSampledAt[account.id] = nil
                        accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle))
                    }
                } else {
                    // Non-active account: refresh the backup credential in place via
                    // the OAuth token endpoint - no keychain swap, so no race with
                    // running Claude Code sessions. Access tokens only live a few
                    // hours, so without this every non-active account would sit in
                    // a permanent "Token expired" state between switches.
                    switch await refreshBackupInPlace(for: account) {
                    case .refreshed(let refreshed):
                        log.info("[fetchUsage] Silently refreshed backup for \(account.email); retrying usage")
                        if let newToken = ClaudeService.extractAccessToken(from: refreshed),
                           let usage = await usageRespectingParking(accessToken: newToken, account: account) {
                            accountUsage[account.id] = usage
                            accountUsageSampledAt[account.id] = Date()
                            accountUsageErrors[account.id] = nil
                            // The binding number too: session and weekly alone cannot
                // explain an auto-switch decision once model-scoped limits
                // count, and this log is the only record of what was decided on.
                let binding = AutoSwitchEngine.bindingUtilization(usage).map { String(format: "%.0f", $0) } ?? "?"
                log.info("[fetchUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%, binding=\(binding)%")
                        }
                    case .grantRejected, .noBackup, .rotationLost:
                        // Only re-authentication mints a new refresh token or a
                        // new backup — an honest dead end until the user acts.
                        // (.rotationLost is the loudest of the three; its log
                        // line already says exactly what was lost and why.)
                        accountUsage[account.id] = nil
                        accountUsageSampledAt[account.id] = nil
                        accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Session expired. Re-authenticate (↻) to fix.", bundle: L10n.bundle))
                    case .storeUnavailable:
                        // Nothing was spent and nothing is lost; this heals by
                        // itself on a later cycle. Keep the stale sample.
                        accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not save the refreshed sign-in; will retry automatically.", bundle: L10n.bundle))
                    }
                }
            } catch {
                log.error("[fetchUsage] Failed to get usage for \(account.email): \(error.localizedDescription)")
                accountUsage[account.id] = nil
                accountUsageSampledAt[account.id] = nil
                accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not fetch usage: \(error.localizedDescription)", bundle: L10n.bundle))
            }
        }
    }

    // MARK: - Diagnostics

    /// Message for the case where the CLI *is* authenticated but reports no
    /// account, because a credential source outranking the stored claude.ai login
    /// is in play. Without this the user only saw "Not logged in" / "Login did not
    /// complete" and re-authorized in a loop that could never help (issue #18).
    private func shadowedIdentityMessage(_ status: AuthStatus) -> String {
        let method = status.shadowingAuthMethod ?? "unknown"
        return String(localized: "Claude CLI is authenticating via \(method) instead of a stored claude.ai login, so it reports no account. Unset ANTHROPIC_AUTH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_PROFILE and remove any apiKeyHelper, then try again.", bundle: L10n.bundle)
    }

    /// Passive health check — verifies backup existence and identity consistency.
    private func diagnoseTokenHealth(liveOwner: LiveCredentialOwner) async {
        guard !accounts.isEmpty else { return }

        log.info("[diagnose] === Health Check ===")
        log.info("[diagnose] Accounts: \(self.accounts.count), active: \(self.activeAccount?.email ?? "none")")

        // Check live oauthAccount identity
        if let liveEmail = await keychain.readOAuthAccountEmailAsync() {
            log.info("[diagnose] Live oauthAccount: \(liveEmail)")
        } else {
            log.warning("[diagnose] Live oauthAccount: MISSING")
        }

        // The identity block above says who is signed in; this says whose
        // credential is actually sitting next to it. When they disagree, every
        // number on the cards is suspect — say so here rather than leaving it
        // to be reconstructed from percentages later.
        switch liveOwner {
        case .owned(let id):
            log.info("[diagnose] Live credential belongs to: \(self.accounts.first(where: { $0.id == id })?.email ?? id.uuidString)")
        case .desynced(_, let credential):
            log.warning("[diagnose] DESYNCED: identity block and live credential disagree; credential is \(self.accounts.first(where: { $0.id == credential })?.email ?? credential.uuidString)'s")
        case .unknown:
            log.warning("[diagnose] Live credential owner: UNKNOWN")
        }

        // Which accounts have a backup that could actually log someone in.
        // One pass over the store for all of them: asking per account decoded
        // the whole store once per account, on every refresh cycle, to produce
        // these log lines.
        //
        // "Missing" and "present but empty" are collapsed here: the distinction
        // only ever reached the log, and both mean the same thing to the user —
        // a switch to that account will fail until it is re-authenticated.
        guard let usable = await keychain.usableBackupIdsAsync() else {
            log.warning("[diagnose] Backup store could not be read right now; no per-account verdict this cycle")
            log.info("[diagnose] === End Health Check ===")
            return
        }
        for account in accounts where !usable.contains(account.id.uuidString) {
            log.warning("[diagnose] Backup [\(account.email)]: MISSING or EMPTY — switch will fail until re-authenticated")
        }
        log.info("[diagnose] Backups usable: \(usable.count)/\(self.accounts.count)")

        log.info("[diagnose] === End Health Check ===")
    }

    // MARK: - Widget

    func updateWidgetData() {
        let widgetAccounts = accounts.map { account in
            let usage = accountUsage[account.id]
            let error = accountUsageErrors[account.id]
            let fable = usage?.displayWindows.first { !$0.isSession && $0.scopeName == "Fable" }
            return WidgetAccountData(
                email: account.displayEmail(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                displayName: account.effectiveDisplayName(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                subscriptionType: account.displaySubscriptionType,
                isActive: account.isActive,
                sessionUtilization: usage?.fiveHour?.utilization,
                sessionResetTime: usage?.fiveHour?.resetTimeString,
                weeklyUtilization: usage?.sevenDay?.utilization,
                weeklyResetTime: usage?.sevenDay?.resetTimeString,
                fableWeeklyUtilization: fable?.utilization,
                fableWeeklyResetTime: fable?.window.resetTimeString,
                extraUsageEnabled: usage?.extraUsage?.isEnabled,
                hasError: error != nil,
                errorMessage: error?.message
            )
        }

        let data = WidgetData(
            accounts: widgetAccounts,
            todayCost: costSummary.todayCost,
            conversationTurns: activityStats.conversationTurns,
            activeCodingTime: activityStats.activeCodingTimeString,
            linesWritten: activityStats.linesWritten,
            modelUsage: activityStats.modelUsage,
            lastUpdated: Date(),
            showsRemaining: UserDefaults.standard.bool(forKey: UsageDisplaySetting.showsRemainingKey)
        )
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("[updateWidgetData] Widget data saved and timelines reloaded")
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            log.info("[loadAccounts] No saved accounts found")
            return
        }
        accounts = decoded
        activeAccount = accounts.first(where: \.isActive)
        autoSwitchConfig.prune(existingAccountIds: Set(accounts.map(\.id)))
        log.info("[loadAccounts] Loaded \(decoded.count) accounts")
    }

    private func saveAccounts(refreshWidget: Bool = false) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
            log.debug("[saveAccounts] Saved \(self.accounts.count) accounts to UserDefaults")
        }
        if refreshWidget {
            updateWidgetData()
        }
    }

    private func updateActiveAccount(from status: AuthStatus, liveOwner: LiveCredentialOwner) {
        guard status.loggedIn, let email = status.email else { return }

        // The CLI reports the identity block, so when that block has been
        // rewritten out from under the credential it names the wrong account.
        // Every API call is billed against the credential, so the active badge
        // belongs to its owner — following the block here is what made the app
        // claim the other account was in use while its quota sat untouched.
        if case .desynced(_, let credentialOwner) = liveOwner,
           let index = accounts.firstIndex(where: { $0.id == credentialOwner }) {
            for i in accounts.indices {
                accounts[i].isActive = (i == index)
            }
            activeAccount = accounts[index]
            saveAccounts()
            log.warning("[updateActiveAccount] Claude reports \(email) but the live credential is \(self.accounts[index].email)'s; keeping the credential's owner active")
            errorMessage = String(localized: "Claude reports \(email), but the stored sign-in is still \(accounts[index].email)'s — another Claude Code session rewrote the identity. Switch accounts once to re-sync.", bundle: L10n.bundle)
            return
        }

        if let index = accounts.firstIndex(where: { $0.email == email }) {
            for i in accounts.indices {
                accounts[i].isActive = (i == index)
            }
            accounts[index].orgName = status.orgName
            accounts[index].subscriptionType = status.subscriptionType
            activeAccount = accounts[index]
            saveAccounts()
            log.info("[updateActiveAccount] Matched existing account at index \(index)")
        } else {
            log.info("[updateActiveAccount] Logged-in account not in our list (might be new)")
        }
    }
}
