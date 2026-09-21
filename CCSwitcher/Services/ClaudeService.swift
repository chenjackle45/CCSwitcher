import Foundation

private let log = FileLog("Claude")

/// UserDefaults key holding the user's preferred Claude CLI path (empty = auto).
let kClaudeBinaryPathPreferenceKey = "claudeBinaryPathPreference"

/// A claude binary discovered on this Mac.
struct DetectedClaudePath: Hashable, Identifiable {
    let path: String
    let label: String
    var id: String { path }
}

/// Interacts with the Claude CLI to get auth status and manage accounts.
extension KeychainService: ClaudeService.CredentialStore {}

final class ClaudeService: @unchecked Sendable {
    static let shared = ClaudeService()

    private let lock = NSLock()
    private var _claudePath: String
    /// Monotonic counter to detect out-of-order setPath completions.
    private var _setPathGeneration: UInt64 = 0

    /// Currently active path. Thread-safe.
    var claudePath: String {
        lock.lock(); defer { lock.unlock() }
        return _claudePath
    }

    private init() {
        let preference = UserDefaults.standard.string(forKey: kClaudeBinaryPathPreferenceKey) ?? ""
        if !preference.isEmpty, FileManager.default.isExecutableFile(atPath: preference) {
            self._claudePath = preference
            log.info("Claude binary path: \(preference) (user preference)")
        } else {
            let auto = Self.autoSelectedPath()
            self._claudePath = auto.path
            log.info("Claude binary path: \(auto.path) (\(auto.source))")
            if !preference.isEmpty {
                log.warning("Saved preference \(preference) is no longer valid; falling back to auto")
            }
        }
    }

    /// Update the runtime claude path. Pass nil or empty to revert to auto-detection.
    /// Does NOT validate — caller (Settings UI) is expected to validate before calling.
    /// Auto-resolution happens outside the lock (can take ~3s via shell PATH lookup);
    /// a generation counter ensures a slower call cannot overwrite a faster, later one.
    func setPath(_ override: String?) {
        lock.lock()
        _setPathGeneration &+= 1
        let myGen = _setPathGeneration
        lock.unlock()

        let resolved: (String, String)
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            resolved = (override, "override")
        } else {
            let auto = Self.autoSelectedPath()
            resolved = (auto.path, "auto/\(auto.source)")
        }

        lock.lock()
        guard myGen == _setPathGeneration else {
            lock.unlock()
            log.info("[setPath] superseded by newer call, discarding \(resolved.0)")
            return
        }
        _claudePath = resolved.0
        lock.unlock()
        log.info("[setPath] \(resolved.1): \(resolved.0)")
    }

    // MARK: - Detection

    /// Today's 3-tier fallback: curated → shell PATH → bare "claude".
    static func autoSelectedPath() -> (path: String, source: String) {
        for candidate in curatedPathCandidates() where FileManager.default.fileExists(atPath: candidate) {
            return (candidate, "curated")
        }
        if let shellPath = shellPathLookup() {
            return (shellPath, "shell PATH")
        }
        return ("claude", "fallback")
    }

    /// All claude binaries that actually exist on this Mac, deduplicated by
    /// resolved symlink target, ordered by discovery source.
    static func detectedPaths() -> [DetectedClaudePath] {
        var result: [DetectedClaudePath] = []
        var seenResolved = Set<String>()

        func add(_ path: String, _ label: String) {
            guard FileManager.default.fileExists(atPath: path) else { return }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard !seenResolved.contains(resolved) else { return }
            seenResolved.insert(resolved)
            result.append(DetectedClaudePath(path: path, label: label))
        }

        for (path, label) in curatedLabeledCandidates() {
            add(path, label)
        }
        for (path, label) in nvmLabeledCandidates() {
            add(path, label)
        }
        if let shellPath = shellPathLookup() {
            add(shellPath, "From shell PATH")
        }

        return result
    }

    private static func curatedPathCandidates() -> [String] {
        curatedLabeledCandidates().map { $0.0 } + nvmLabeledCandidates().map { $0.0 }
    }

    private static func curatedLabeledCandidates() -> [(String, String)] {
        let home = NSHomeDirectory()
        return [
            ("/usr/local/bin/claude", "/usr/local/bin"),
            ("/opt/homebrew/bin/claude", "Homebrew"),
            ("/opt/local/bin/claude", "MacPorts"),
            ("\(home)/.local/bin/claude", "Anthropic native installer"),
            ("\(home)/.claude/local/claude", "Anthropic migrate installer"),
            ("\(home)/.npm-global/bin/claude", "npm global"),
            ("\(home)/.volta/bin/claude", "Volta"),
            ("\(home)/Library/pnpm/claude", "pnpm"),
            ("\(home)/.bun/bin/claude", "Bun"),
            ("\(home)/.yarn/bin/claude", "Yarn"),
        ]
    }

    /// Discover Claude binaries installed via NVM (Node Version Manager).
    /// NVM stores node versions at ~/.nvm/versions/node/<version>/bin/.
    private static func nvmLabeledCandidates() -> [(String, String)] {
        let nvmDir = "\(NSHomeDirectory())/.nvm/versions/node"
        guard FileManager.default.fileExists(atPath: nvmDir) else { return [] }
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) else {
            log.warning("[nvmLabeledCandidates] NVM directory exists but could not be read: \(nvmDir)")
            return []
        }
        return versions
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { ("\(nvmDir)/\($0)/bin/claude", "NVM \($0)") }
    }

    /// Last-resort lookup: ask the user's interactive login shell where `claude` lives.
    /// Catches install layouts the curated list doesn't enumerate (asdf shims, fnm, n,
    /// pnpm/yarn/bun/Volta with non-default prefixes, custom npm prefixes, etc.).
    /// Bounded by a short timeout so a slow .zshrc can't block app launch.
    private static func shellPathLookup() -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v claude"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            log.warning("[shellPathLookup] Failed to launch /bin/zsh: \(error.localizedDescription)")
            return nil
        }

        // Hard timeout — don't let a heavy shell rc file block forever.
        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            log.warning("[shellPathLookup] zsh exceeded 3s timeout; aborting")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        // `command -v` may emit multiple lines if claude is shadowed; take the first.
        let candidate = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard candidate.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: candidate) else {
            return nil
        }
        return candidate
    }

    // MARK: - Auth Status

    func getAuthStatus() async throws -> AuthStatus {
        log.info("[getAuthStatus] Fetching auth status...")
        let output = try await runClaude(args: ["auth", "status"])
        guard let data = output.data(using: .utf8) else {
            log.error("[getAuthStatus] Invalid output (not UTF-8)")
            throw ClaudeServiceError.invalidOutput
        }
        let status = try JSONDecoder().decode(AuthStatus.self, from: data)
        log.info("[getAuthStatus] loggedIn=\(status.loggedIn), provider=\(status.apiProvider ?? "nil"), sub=\(status.subscriptionType ?? "nil")")
        return status
    }

    func isClaudeAvailable() async -> Bool {
        do {
            let version = try await runClaude(args: ["--version"])
            log.info("[isClaudeAvailable] YES, version: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
            return true
        } catch {
            log.error("[isClaudeAvailable] NO, error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Usage API

    enum UsageError: Error {
        case expired
        case network(String)
        case decode(String)
        case rateLimited(retryAfter: TimeInterval?)
        /// 403 permission_error - e.g. "OAuth authentication is currently not
        /// allowed for this organization" (no active Pro/Max subscription).
        case forbidden(String)
    }

    /// Fetch usage for a specific access token
    func getUsageLimits(accessToken: String) async throws -> UsageAPIResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { throw UsageError.network("invalid url") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        log.debug("[getUsageLimits] REQUEST URL: \(url.absoluteString)")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard httpResponse?.statusCode == 200 else {
            let responseString = String(data: responseData, encoding: .utf8) ?? ""
            log.error("[getUsageLimits] HTTP \(httpResponse?.statusCode ?? 0)")

            if httpResponse?.statusCode == 401 || responseString.contains("token_expired") {
                throw UsageError.expired
            }
            if httpResponse?.statusCode == 429 {
                let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                log.warning("[getUsageLimits] 429, Retry-After: \(retryAfter.map { String(format: "%.0f", $0) } ?? "none")s")
                throw UsageError.rateLimited(retryAfter: retryAfter)
            }
            if httpResponse?.statusCode == 403 {
                // Typically: no active Pro/Max subscription on the account.
                log.warning("[getUsageLimits] 403 permission error: \(responseString.prefix(200))")
                throw UsageError.forbidden(responseString)
            }
            throw UsageError.network("HTTP \(httpResponse?.statusCode ?? 0)")
        }
        
        do {
            let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: responseData)
            log.info("[getUsageLimits] session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
            return usage
        } catch {
            log.error("[getUsageLimits] Decode Error: \(error.localizedDescription)")
            throw UsageError.decode(error.localizedDescription)
        }
    }

    // MARK: - OAuth refresh (direct token endpoint, no keychain swap)

    /// Claude Code's public OAuth client id (PKCE public client - not a secret).
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let oauthTokenURL = "https://console.anthropic.com/v1/oauth/token"

    /// Outcome of an OAuth refresh attempt. The `rejected`/`transient`
    /// distinction is load-bearing for the caller: `rejected` means the refresh
    /// token is dead and only re-authentication helps, while `transient` says
    /// nothing about the token at all — showing "re-authenticate" for a network
    /// blip would send the user through a pointless login.
    enum OAuthRefreshResult {
        case success(String)
        /// The endpoint (or the stored credential itself) says this grant can
        /// never work: no refresh token stored, or a 4xx rejection.
        case rejected
        /// Network trouble or a server-side error; the token's validity is unknown.
        case transient
    }

    /// Silently refresh a credential JSON using its refresh token, via a direct
    /// POST to the OAuth token endpoint. Never touches the keychain - safe to run
    /// for non-active accounts while Claude Code sessions are working, because
    /// only CCSwitcher holds these backups (rotation cannot race anyone).
    func refreshOAuthCredentials(_ credentialsJSON: String) async -> OAuthRefreshResult {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(credentialsJSON.utf8))) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty,
              let url = URL(string: Self.oauthTokenURL)
        else {
            log.warning("[refreshOAuth] Stored credential has no refresh token")
            return .rejected
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientID,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let resp = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let accessToken = resp["access_token"] as? String,
                  let expiresIn = resp["expires_in"] as? Double
            else {
                // NEVER log the response body. This guard also fires when the
                // status IS 200 but a field failed to parse (schema change) —
                // in that case the body is a *successful* token response whose
                // first bytes are a live access token, headed for a log file
                // that outlives rotation and gets attached to bug reports.
                // Log the status plus an allowlisted OAuth error code only.
                let oauthError = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                let knownCodes = ["invalid_grant", "invalid_request", "invalid_client", "unauthorized_client", "unsupported_grant_type", "invalid_scope"]
                let loggedCode = oauthError.map { knownCodes.contains($0) ? $0 : "unrecognized" } ?? "none"
                log.warning("[refreshOAuth] Refresh not applied (HTTP \(status), error=\(loggedCode), \(data.count) bytes)")

                // A 200 that failed OUR parse is a schema change, not a dead
                // grant. Otherwise only a grant-terminal OAuth error means the
                // refresh token is dead (RFC 6749 §5.2: `invalid_grant` covers
                // expired/revoked/invalid refresh tokens). Everything else —
                // 5xx, 429, 408, an `invalid_request` from a request-shape
                // mismatch — says nothing about the token, and demanding
                // re-authentication for it would be a pointless login.
                if status == 200 { return .transient }
                return oauthError == "invalid_grant" ? .rejected : .transient
            }

            oauth["accessToken"] = accessToken
            oauth["expiresAt"] = Int64(Date().timeIntervalSince1970 * 1000) + Int64(expiresIn * 1000)
            if let newRefresh = resp["refresh_token"] as? String, !newRefresh.isEmpty {
                oauth["refreshToken"] = newRefresh
            }
            // `scopes` is deliberately NOT rewritten from the refresh response.
            // The CLI (verified against claude 2.1.220) decides whether it
            // recognises a stored login by checking that `scopes` contains
            // "user:inference"; a refresh response carrying a narrower scope
            // string would make this credential invisible to `claude auth
            // status`, and the account would read as not-logged-in with no
            // visible cause. The login-time value is the one to keep.
            root["claudeAiOauth"] = oauth
            let out = try JSONSerialization.data(withJSONObject: root)
            log.info("[refreshOAuth] Access token refreshed, valid for \(Int(expiresIn / 3600))h \(Int(expiresIn.truncatingRemainder(dividingBy: 3600) / 60))m")
            guard let json = String(data: out, encoding: .utf8) else { return .transient }
            return .success(json)
        } catch {
            log.warning("[refreshOAuth] Refresh failed: \(error.localizedDescription)")
            return .transient
        }
    }

    /// Extract access token string from a token JSON (keychain format)
    static func extractAccessToken(from tokenJSON: String) -> String? {
        guard let data = tokenJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            return nil
        }
        return accessToken
    }

    // MARK: - Account Switching

    /// The credential-store operations a switch performs, so the switch can be
    /// tested without a keychain. `KeychainService` is the only implementation
    /// that ships; the tests substitute a fake that can fail on demand.
    protocol CredentialStore: AnyObject, Sendable {
        func readClaudeToken() -> String?
        func readOAuthAccount() -> [String: AnyCodable]?
        func writeClaudeToken(_ tokenJSON: String) -> Bool
        func writeOAuthAccount(_ oauthAccount: [String: AnyCodable]) -> Bool
        func saveAccountBackup(token: String, oauthAccount: [String: AnyCodable], forAccountId accountId: String) -> Bool
    }

    /// Result of a completed switch.
    struct SwitchOutcome {
        /// Set when the swap succeeded but `claude auth status` could not confirm
        /// it, because this credential source shadows the stored claude.ai login.
        let shadowedBy: String?
    }

    /// `targetBackup` and `liveCredentialIsSource` are resolved by the caller
    /// (which can distinguish a missing backup from a briefly unreadable store,
    /// and holds the credential anchor) and handed down so no second,
    /// ambiguity-collapsing lookup happens here.
    @discardableResult
    /// `store` and `verify` exist for the tests: the real switch talks to the
    /// keychain and to `claude auth status`, neither of which a unit test may
    /// touch. Production callers use the defaults.
    func switchAccount(
        from currentAccount: Account?,
        to targetAccount: Account,
        targetBackup: sending AccountBackup,
        liveCredentialIsSource: Bool,
        store: CredentialStore = KeychainService.shared,
        verify: (() async throws -> AuthStatus)? = nil
    ) async throws -> SwitchOutcome {
        let keychain = store

        log.info("[switchAccount] Switching from \(currentAccount?.id.uuidString ?? "no active account") to \(targetAccount.id)")

        // A backup with both OAuth secrets blanked cannot authenticate, and
        // Step 4 is far too late to find that out: by then the target's dead
        // credentials are already live and the source account is gone with
        // them. Refuse before anything is written.
        guard targetBackup.hasUsableCredentials else {
            log.error("[switchAccount] ABORT: stored backup for \(targetAccount.id) carries no OAuth secret")
            throw ClaudeServiceError.backupCredentialsUnusable(email: targetAccount.email)
        }

        // 1. Back up current account (token + oauthAccount)
        //
        // Gated on BOTH the anchor and the `oauthAccount` email. The anchor
        // catches an identity block rewritten by another Claude Code session;
        // the email check catches the mirror case, where the token is the
        // source account's but the identity block now names someone else —
        // saving that pair would store one account's identity in another's
        // backup.
        //
        // The two values are also kept past the backup write: Step 3
        // overwrites the live credentials before Step 4 can judge them, so
        // they are the only remaining copy of what the CLI was authenticated
        // with if the switch is rejected.
        // Read the whole snapshot FIRST. Step 3 overwrites both halves, and a
        // rollback can only put back what was captured here — so a switch that
        // starts without a complete snapshot is a switch with no way home. Fail
        // before anything is written instead of after.
        log.info("[switchAccount] Step 1: Backing up current account...")
        let previousToken = keychain.readClaudeToken()
        let previousOAuthAccount = keychain.readOAuthAccount()

        // Both halves missing is the logged-out state: `claude auth logout` was
        // run, or there simply is no sign-in yet. There is nothing to roll back
        // TO, and restoring "signed out" is not a service anyone wants — so the
        // switch proceeds. Refusing here would have made the app unable to do
        // the one thing it exists for, exactly when the user needs it.
        //
        // Exactly ONE half readable is the dangerous case: the two are supposed
        // to travel together, so this is either a partial write or a store that
        // is failing intermittently, and a rollback could only put half of it
        // back. Refuse before anything is written.
        if (previousToken == nil) != (previousOAuthAccount == nil) {
            log.error("[switchAccount] ABORT: only half of the current sign-in could be read (token=\(previousToken != nil), identity=\(previousOAuthAccount != nil)); refusing to switch on a partial snapshot")
            throw ClaudeServiceError.liveCredentialsUnreadable
        }
        if previousToken == nil {
            log.info("[switchAccount] Step 1: No live sign-in to back up (logged out); the switch will not have a rollback target")
        }

        let previousEmail = (previousOAuthAccount?["emailAddress"]?.value as? String) ?? "?"
        if previousToken == nil {
            // nothing to back up
        } else if let currentAccount, !liveCredentialIsSource {
            log.warning("[switchAccount] Step 1: Live credential is not confirmed to be \(currentAccount.email)'s; skipping backup rather than storing it under the wrong account")
        } else if let currentAccount, previousEmail != currentAccount.email {
            log.warning("[switchAccount] Step 1: oauthAccount email (\(previousEmail)) != source (\(currentAccount.email)), skipping backup")
        } else if currentAccount == nil {
            // No account to file it under — this is the hand-over after the
            // active account was removed, or a first switch with nothing signed
            // in. The live credential is still restored on failure; it just has
            // nowhere to be stored as a backup.
            log.info("[switchAccount] Step 1: No source account to back up to")
        } else if let currentAccount, let previousToken, let previousOAuthAccount {
            // F4: a failed save here used to be logged and ignored, and then
            // Step 3 overwrote the live credential anyway — leaving the outgoing
            // account with a stale or absent backup and no way back to it. The
            // switch has written nothing yet, so refusing now is free.
            guard keychain.saveAccountBackup(token: previousToken, oauthAccount: previousOAuthAccount, forAccountId: currentAccount.id.uuidString) else {
                log.error("[switchAccount] ABORT: could not save \(currentAccount.email)'s backup; switching now would strand it")
                throw ClaudeServiceError.sourceBackupFailed(email: currentAccount.email)
            }
            log.info("[switchAccount] Step 1: Backup saved")
        }

        /// Restores the credentials the CLI held before Step 3 ran.
        ///
        /// Steps 3 and 4 are not one operation. Step 3 has already replaced the
        /// live token and `~/.claude.json` by the time Step 4 gets to reject
        /// them, so a failure that returns without this leaves the user signed
        /// out of the account they were on as well as the one they asked for,
        /// with no obvious way back other than a browser re-login.
        /// Both halves are attempted independently: stopping at the first
        /// failure would leave the other half holding the target account's
        /// credential, which is a worse mix than either single failure.
        /// Set once Step 3 has written anything: after that point a failure
        /// cannot simply be reported, because the live credentials are no longer
        /// the ones the user started with.
        var targetCredentialsWritten = false

        func rollback(after reason: String, cause: Error?) throws {
            guard let previousToken, let previousOAuthAccount else {
                log.info("[switchAccount] Nothing to roll back to after \(reason): there was no live sign-in when the switch started")
                guard targetCredentialsWritten else { return }
                // The target's credentials ARE live now, and there is no previous
                // sign-in to put back. Saying "the switch failed" and stopping
                // would leave the app's model and the CLI's reality disagreeing
                // silently — the exact class of bug this batch exists to remove.
                log.error("[switchAccount] \(reason), and there was no previous sign-in to restore: \(targetAccount.email)'s credentials are now live but unverified")
                throw ClaudeServiceError.switchLandedUnverified(email: targetAccount.email, cause: cause)
            }
            let tokenRestored = keychain.writeClaudeToken(previousToken)
            let oauthRestored = keychain.writeOAuthAccount(previousOAuthAccount)
            log.info("[switchAccount] Rolled back to \(currentAccount?.id.uuidString ?? "the previous sign-in") after \(reason): token=\(tokenRestored), oauthAccount=\(oauthRestored)")
            guard tokenRestored, oauthRestored else {
                // The user is now signed in to neither account. Saying so is the
                // whole point: a log line here is a silent lockout.
                log.error("[switchAccount] ROLLBACK FAILED after \(reason): token=\(tokenRestored), oauthAccount=\(oauthRestored)")
                throw ClaudeServiceError.rollbackFailed(
                    email: currentAccount?.email ?? targetAccount.email,
                    tokenRestored: tokenRestored,
                    oauthRestored: oauthRestored,
                    cause: cause
                )
            }
        }

        // 2. Target backup was resolved and validated by the caller.
        log.info("[switchAccount] Step 2: Using caller-resolved backup for target account")

        // 3. Write target token to keychain + target oauthAccount to ~/.claude.json
        log.info("[switchAccount] Step 3: Writing target credentials...")
        guard keychain.writeClaudeToken(targetBackup.token) else {
            // `writeClaudeToken` deletes before it adds, so a failure here can
            // have already removed the live token: restore, don't just report.
            log.error("[switchAccount] Step 3: Failed to write token to keychain!")
            try rollback(after: "the token write failed", cause: ClaudeServiceError.keychainWriteFailed)
            throw ClaudeServiceError.keychainWriteFailed
        }
        guard keychain.writeOAuthAccount(targetBackup.oauthAccount) else {
            log.error("[switchAccount] Step 3: Failed to write oauthAccount to ~/.claude.json!")
            targetCredentialsWritten = true   // the token half is already live
            try rollback(after: "the oauthAccount write failed", cause: ClaudeServiceError.oauthAccountWriteFailed)
            throw ClaudeServiceError.oauthAccountWriteFailed
        }
        targetCredentialsWritten = true
        log.info("[switchAccount] Step 3: Both token and oauthAccount written")

        // 4. Verify
        log.info("[switchAccount] Step 4: Verifying with `claude auth status`...")
        let status: AuthStatus
        do {
            if let verify {
                status = try await verify()
            } else {
                status = try await getAuthStatus()
            }
        } catch {
            log.error("[switchAccount] Step 4: Could not read auth status: \(error.localizedDescription)")
            try rollback(after: "the verification call failed", cause: error)
            throw error
        }
        guard status.loggedIn else {
            log.error("[switchAccount] Step 4: Not logged in after switch!")
            try rollback(after: "the CLI reported no login", cause: ClaudeServiceError.switchVerificationFailed)
            throw ClaudeServiceError.switchVerificationFailed
        }

        if let email = status.email {
            guard email == targetAccount.email else {
                log.error("[switchAccount] Step 4: Logged in as \(email) instead of \(targetAccount.email)")
                try rollback(after: "the CLI reported a different account", cause: ClaudeServiceError.switchWrongAccount(expected: targetAccount.email, actual: email))
                throw ClaudeServiceError.switchWrongAccount(expected: targetAccount.email, actual: email)
            }
            log.info("[switchAccount] Step 4: Switch verified — logged in as \(email)")
            return SwitchOutcome(shadowedBy: nil)
        }

        // No `email` in the status output. The CLI is logged in, but resolves to a
        // credential source that outranks the stored claude.ai login (env token,
        // apiKeyHelper, OAuth token file, Anthropic profile, third-party provider),
        // so it omits the identity block entirely. That says nothing about whether
        // our swap worked, so verify against the credentials we just wrote instead
        // of reporting the target account as "wrong" (issue #18).
        let shadowedBy = status.shadowingAuthMethod ?? "unknown"
        log.warning("[switchAccount] Step 4: CLI reports authMethod=\(shadowedBy) and omits the account identity; verifying against the credential store instead")
        guard credentialsOnDiskMatch(backup: targetBackup, email: targetAccount.email, store: store) else {
            try rollback(after: "the credential store did not match what we wrote", cause: ClaudeServiceError.credentialStoreMismatch)
            throw ClaudeServiceError.credentialStoreMismatch
        }
        log.info("[switchAccount] Step 4: Switch verified against the credential store (CLI identity hidden by \(shadowedBy))")
        return SwitchOutcome(shadowedBy: shadowedBy)
    }

    /// Ground-truth check that does not depend on `claude auth status`: both
    /// halves of a switch — the keychain token and the `~/.claude.json` identity —
    /// must hold the target account.
    private func credentialsOnDiskMatch(backup: AccountBackup, email: String, store: CredentialStore) -> Bool {
        let keychain = store

        guard let liveToken = keychain.readClaudeToken(),
              let liveAccessToken = Self.extractAccessToken(from: liveToken),
              let expectedAccessToken = Self.extractAccessToken(from: backup.token),
              liveAccessToken == expectedAccessToken else {
            log.error("[switchAccount] Keychain token does not match the target account's backup")
            return false
        }

        guard let liveOAuth = keychain.readOAuthAccount(),
              (liveOAuth["emailAddress"]?.value as? String) == email else {
            log.error("[switchAccount] ~/.claude.json identity does not match \(email)")
            return false
        }

        return true
    }

    /// Capture the current Claude auth token + oauthAccount and associate with
    /// an account. The keychain work runs off the main thread.
    func captureCurrentCredentials(forAccountId accountId: String) async -> Bool {
        log.info("[capture] Capturing credentials for account \(accountId)...")
        let keychain = KeychainService.shared
        guard let token = await keychain.readClaudeTokenAsync() else {
            log.error("[capture] Failed: no token found in keychain")
            return false
        }
        guard let oauthAccount = keychain.readOAuthAccount() else {
            log.error("[capture] Failed: no oauthAccount found in ~/.claude.json")
            return false
        }
        let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
        log.info("[capture] Token + oauthAccount found (email=\(email)), saving backup...")
        guard let encoded = try? JSONEncoder().encode(AccountBackup(token: token, oauthAccount: oauthAccount)) else {
            log.error("[capture] Failed: could not encode the captured backup")
            return false
        }
        let result = await keychain.saveAccountBackupDataAsync(encoded, forAccountId: accountId)
        log.info("[capture] Save result: \(result)")
        return result
    }

    /// Run `claude auth login` which opens browser for OAuth.
    func login() async throws {
        log.info("[login] Starting `claude auth login`... (will open browser)")
        _ = try await runClaude(args: ["auth", "login"])
        log.info("[login] `claude auth login` process exited")

        // Give keychain a moment to sync after CLI writes
        try await Task.sleep(for: .seconds(1))
        log.info("[login] Post-login delay complete, ready for token capture")
    }

    /// Run `claude auth logout`
    func logout() async throws {
        log.info("[logout] Running `claude auth logout`...")
        _ = try await runClaude(args: ["auth", "logout"])
        log.info("[logout] Logout complete")
    }

    // MARK: - Version

    /// Run `<path> --version` and return the first semver-looking token.
    /// Returns nil on launch failure, non-zero exit, or no version found.
    static func readVersion(at path: String) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["--version"]
                process.standardOutput = stdout
                process.standardError = Pipe()

                // Inject same PATH augmentation as runClaude so NVM-installed
                // claude can find `node` when invoked here.
                var env = ProcessInfo.processInfo.environment
                let homeDir = NSHomeDirectory()
                var extraPaths = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "\(homeDir)/.local/bin",
                    "\(homeDir)/.npm-global/bin"
                ]
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                let resolvedBinDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
                extraPaths.insert(resolvedBinDir, at: 0)
                let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                env["HOME"] = homeDir
                process.environment = env

                do {
                    try process.run()
                } catch {
                    log.warning("[readVersion] launch failed for \(path): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }

                let deadline = Date().addingTimeInterval(5.0)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    log.warning("[readVersion] timed out for \(path)")
                    continuation.resume(returning: nil)
                    return
                }

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: Self.extractSemver(from: raw))
            }
        }
    }

    /// Fetch the latest published claude-code version. Returns nil on any failure.
    static func fetchLatestVersion() async -> String? {
        guard let url = URL(string: "https://downloads.claude.ai/claude-code-releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log.warning("[fetchLatestVersion] non-200 response")
                return nil
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strict: the entire body must BE a semver. Protects against the CDN
            // returning an HTML error page with 200 status that happens to contain
            // dotted numbers (CSS dimensions, version strings in copy, etc.).
            return Self.isPureSemver(trimmed) ? trimmed : nil
        } catch {
            log.warning("[fetchLatestVersion] error: \(error.localizedDescription)")
            return nil
        }
    }

    /// True if the whole string is ASCII digits separated by dots (e.g. "1.0.42", "2.1.139").
    private static func isPureSemver(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 32 else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for p in parts {
            guard !p.isEmpty else { return false }
            for ch in p {
                guard ch.isASCII, ch.isNumber else { return false }
            }
        }
        return true
    }

    /// Extract the first dotted-ASCII-numeric token from a string (e.g. "1.0.42" out of "1.0.42 (Claude Code)").
    private static func extractSemver(from text: String) -> String? {
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isNumber || $0 == ".") }
        for token in text.split(whereSeparator: { !allowed($0) }) {
            let s = String(token)
            guard isPureSemver(s) else { continue }
            return s
        }
        return nil
    }

    // MARK: - CLI Runner

    private func runClaude(args: [String]) async throws -> String {
        let claudePath = self.claudePath
        log.debug("[runClaude] Running: \(claudePath) \(args.joined(separator: " "))")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [claudePath] in
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe

                var env = ProcessInfo.processInfo.environment
                let homeDir = NSHomeDirectory()
                // Include the parent directory of the discovered claude binary
                // so that `node` is on PATH for NVM-installed scripts.
                // Only add it when claudePath is absolute (skip the bare "claude" fallback).
                var extraPaths = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "\(homeDir)/.local/bin",
                    "\(homeDir)/.npm-global/bin"
                ]
                if claudePath.contains("/") {
                    // Resolve symlinks so that e.g. /usr/local/bin/claude -> ~/.nvm/.../bin/claude
                    // yields the NVM bin dir where `node` actually lives
                    let resolved = URL(fileURLWithPath: claudePath).resolvingSymlinksInPath().path
                    let resolvedBinDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
                    extraPaths.insert(resolvedBinDir, at: 0)
                }
                let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                env["HOME"] = homeDir
                process.environment = env

                do {
                    try process.run()
                    // Drain before waiting, same reason as
                    // KeychainService.runSecurity: a child blocked writing more
                    // than the pipe buffer never exits.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        log.debug("[runClaude] Success (exit 0), output length: \(output.count)")
                        continuation.resume(returning: output)
                    } else {
                        log.error("[runClaude] Failed (exit \(process.terminationStatus))")
                        continuation.resume(throwing: ClaudeServiceError.cliError("exit \(process.terminationStatus)"))
                    }
                } catch {
                    log.error("[runClaude] Process launch failed: \(error.localizedDescription)")
                    continuation.resume(throwing: ClaudeServiceError.processLaunchFailed(error))
                }
            }
        }
    }
}

// MARK: - Errors

enum ClaudeServiceError: LocalizedError {
    case invalidOutput
    case cliError(String)
    case processLaunchFailed(Error)
    case noTokenForAccount(String)
    case keychainWriteFailed
    case oauthAccountWriteFailed
    case switchVerificationFailed
    case switchWrongAccount(expected: String, actual: String)
    case backupCredentialsUnusable(email: String)
    case liveCredentialsUnreadable
    case sourceBackupFailed(email: String)
    case credentialStoreMismatch
    case switchLandedUnverified(email: String, cause: Error?)
    case rollbackFailed(email: String, tokenRestored: Bool, oauthRestored: Bool, cause: Error?)

    var errorDescription: String? {
        switch self {
        case .invalidOutput:
            return "Invalid output from Claude CLI"
        case .cliError(let msg):
            return "Claude CLI error: \(msg)"
        case .processLaunchFailed(let error):
            return "Failed to launch Claude: \(error.localizedDescription)"
        case .noTokenForAccount:
            return "No stored backup for target account"
        case .keychainWriteFailed:
            return "Failed to write token to keychain"
        case .oauthAccountWriteFailed:
            return "Failed to write oauthAccount to ~/.claude.json"
        case .switchVerificationFailed:
            return "Account switch verification failed"
        case .switchWrongAccount(let expected, let actual):
            return "Switch failed: expected \(expected) but got \(actual). Try removing and re-adding the account."
        case .backupCredentialsUnusable(let email):
            return "The stored credentials for \(email) are empty. Use re-authenticate to sign in again."
        case .liveCredentialsUnreadable:
            return "Only part of the current sign-in could be read, so the switch was cancelled. Nothing was changed; try again in a moment."
        case .sourceBackupFailed(let email):
            return "Could not save \(email)'s credentials before switching, so the switch was cancelled. Nothing was changed."
        case .credentialStoreMismatch:
            return "The credential store does not hold what the switch just wrote — something else changed it."
        case .switchLandedUnverified(let email, let cause):
            let why = cause.map { " (\($0.localizedDescription))" } ?? ""
            return "\(email)'s credentials are now live but the switch could not be verified\(why), and there was no previous sign-in to restore. Check which account the Claude CLI is on."
        case .rollbackFailed(let email, let tokenRestored, let oauthRestored, let cause):
            let parts = [tokenRestored ? nil : "token", oauthRestored ? nil : "identity"].compactMap { $0 }
            // The lockout is the urgent fact, but the reason the switch failed
            // in the first place is what tells the user what to do differently.
            let why = cause.map { " The switch failed because: \($0.localizedDescription)" } ?? ""
            return "The switch failed and the previous sign-in could not be restored (\(parts.joined(separator: " + "))). Re-authenticate \(email) to recover.\(why)"
        }
    }
}
