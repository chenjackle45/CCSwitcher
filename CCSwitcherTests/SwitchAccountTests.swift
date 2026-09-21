import XCTest

/// What a failed switch must leave behind. Every case here ends with the same
/// question: is the user still signed in to the account they started on?
final class SwitchAccountTests: XCTestCase {

    // MARK: - Fake store

    /// Records every write and can be told to fail any of them.
    private final class FakeStore: ClaudeService.CredentialStore, @unchecked Sendable {
        var liveToken: String?
        var liveOAuth: [String: AnyCodable]?

        var failTokenWrites = false
        var failOAuthWrites = false
        /// Token writes that must fail (counted), so "fails once, then works"
        /// and "always fails" are both expressible.
        var tokenWriteFailures = 0
        var oauthWriteFailures = 0

        private(set) var savedBackups: [String: (token: String, email: String?)] = [:]
        private(set) var tokenWrites: [String] = []

        init(token: String?, email: String?) {
            liveToken = token
            liveOAuth = email.map { ["emailAddress": AnyCodable($0)] }
        }

        func readClaudeToken() -> String? { liveToken }
        func readOAuthAccount() -> [String: AnyCodable]? { liveOAuth }

        func writeClaudeToken(_ tokenJSON: String) -> Bool {
            if failTokenWrites || tokenWriteFailures > 0 {
                tokenWriteFailures = max(0, tokenWriteFailures - 1)
                // The real one deletes before it adds, so a failed write can
                // leave the keychain with no token at all.
                liveToken = nil
                return false
            }
            liveToken = tokenJSON
            tokenWrites.append(tokenJSON)
            return true
        }

        func writeOAuthAccount(_ oauthAccount: [String: AnyCodable]) -> Bool {
            if failOAuthWrites || oauthWriteFailures > 0 {
                oauthWriteFailures = max(0, oauthWriteFailures - 1)
                return false
            }
            liveOAuth = oauthAccount
            return true
        }

        func saveAccountBackup(token: String, oauthAccount: [String: AnyCodable], forAccountId accountId: String) -> Bool {
            savedBackups[accountId] = (token, oauthAccount["emailAddress"]?.value as? String)
            return true
        }

        var liveEmail: String? { liveOAuth?["emailAddress"]?.value as? String }
    }

    // MARK: - Fixtures

    private let source = Account(email: "source@example.com", displayName: "Source", provider: .claudeCode, isActive: true)
    private let target = Account(email: "target@example.com", displayName: "Target", provider: .claudeCode)

    private func targetBackup() -> AccountBackup {
        AccountBackup(
            token: #"{"claudeAiOauth":{"accessToken":"target-access","refreshToken":"target-refresh"}}"#,
            oauthAccount: ["emailAddress": AnyCodable("target@example.com")]
        )
    }

    private func sourceToken() -> String {
        #"{"claudeAiOauth":{"accessToken":"source-access","refreshToken":"source-refresh"}}"#
    }

    private func makeStore(email: String? = "source@example.com") -> FakeStore {
        FakeStore(token: sourceToken(), email: email)
    }

    private func loggedIn(as email: String) -> AuthStatus {
        AuthStatus(loggedIn: true, authMethod: nil, apiProvider: nil, email: email, orgId: nil, orgName: nil, subscriptionType: nil)
    }

    private func switchAccount(
        store: FakeStore,
        from: Account? = nil,
        liveCredentialIsSource: Bool = true,
        verify: @escaping () async throws -> AuthStatus
    ) async throws -> ClaudeService.SwitchOutcome {
        // Built inline so the value is created in this call's isolation region:
        // `AccountBackup` is not Sendable, so one produced by a helper cannot be
        // handed to `switchAccount`, which runs off the main actor.
        let backup = AccountBackup(
            token: #"{"claudeAiOauth":{"accessToken":"target-access","refreshToken":"target-refresh"}}"#,
            oauthAccount: ["emailAddress": AnyCodable("target@example.com")]
        )
        return try await ClaudeService.shared.switchAccount(
            from: from ?? source,
            to: target,
            targetBackup: backup,
            liveCredentialIsSource: liveCredentialIsSource,
            store: store,
            verify: verify
        )
    }

    // MARK: - Snapshot

    func testRefusesToStartWithoutAReadableSnapshot() async {
        let store = FakeStore(token: nil, email: "source@example.com")
        do {
            _ = try await switchAccount(store: store) { self.loggedIn(as: "target@example.com") }
            XCTFail("expected the switch to be refused")
        } catch ClaudeServiceError.liveCredentialsUnreadable {
            XCTAssertTrue(store.tokenWrites.isEmpty, "nothing may be written when there is no way back")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Backup gating

    func testBacksUpTheSourceWhenTokenAndIdentityBothMatch() async throws {
        let store = makeStore()
        _ = try await switchAccount(store: store) { self.loggedIn(as: "target@example.com") }
        XCTAssertEqual(store.savedBackups[source.id.uuidString]?.token, sourceToken())
    }

    func testSkipsTheBackupWhenTheLiveCredentialIsNotTheSourceAccounts() async throws {
        let store = makeStore()
        _ = try await switchAccount(store: store, liveCredentialIsSource: false) { self.loggedIn(as: "target@example.com") }
        XCTAssertNil(store.savedBackups[source.id.uuidString], "stored one account's token under another's id")
    }

    func testSkipsTheBackupWhenTheIdentityBlockNamesSomeoneElse() async throws {
        let store = makeStore(email: "somebody-else@example.com")
        _ = try await switchAccount(store: store) { self.loggedIn(as: "target@example.com") }
        XCTAssertNil(store.savedBackups[source.id.uuidString])
    }

    // MARK: - Nothing signed in

    /// `claude auth logout`, or a first run: there is no live sign-in to back up
    /// and nothing to roll back to. Restoring "signed out" is not a service
    /// anyone wants, so the switch goes ahead — refusing here would make the app
    /// unable to do its one job exactly when the user needs it.
    ///
    /// This one pins behaviour that already worked; the regression it guards
    /// against is a future "refuse when anything is unreadable" tightening.
    func testSwitchProceedsWhenThereIsNoLiveSignIn() async throws {
        let store = FakeStore(token: nil, email: nil)
        let outcome = try await switchAccount(store: store) { self.loggedIn(as: "target@example.com") }
        XCTAssertNil(outcome.shadowedBy)
        XCTAssertEqual(store.liveToken, targetBackup().token)
        XCTAssertTrue(store.savedBackups.isEmpty, "there was no source account to back up")
    }

    /// The same path when verification then fails: the target's credentials are
    /// already live and there is nothing to put back, so the error has to say
    /// that rather than reporting a plain "switch failed" the app cannot undo.
    func testSwitchWithNoLiveSignInReportsWhenItLandsUnverified() async {
        let store = FakeStore(token: nil, email: nil)
        do {
            _ = try await switchAccount(store: store) { self.loggedIn(as: "someone-else@example.com") }
            XCTFail("expected an error")
        } catch ClaudeServiceError.switchLandedUnverified(let email, let cause) {
            XCTAssertEqual(email, target.email)
            XCTAssertNotNil(cause)
            XCTAssertEqual(store.liveToken, targetBackup().token, "the target credentials really are live")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The service layer of "no account to switch away from". The AppState side
    /// of that path (`switchTo` / `performSwitch` / `removeAccount`) is not in
    /// this test target, so it is covered by review and by the manual check,
    /// not here.
    func testSwitchWorksWithNoSourceAccount() async throws {
        let store = makeStore()
        let outcome = try await switchAccount(store: store, from: Account?.none, liveCredentialIsSource: false) {
            self.loggedIn(as: "target@example.com")
        }
        XCTAssertNil(outcome.shadowedBy)
        XCTAssertEqual(store.liveToken, targetBackup().token)
        XCTAssertTrue(store.savedBackups.isEmpty, "there is no account to file the outgoing credential under")
    }

    // MARK: - Rollback

    func testTokenWriteFailureRollsBack() async {
        let store = makeStore()
        store.tokenWriteFailures = 1
        do {
            _ = try await switchAccount(store: store) { self.loggedIn(as: "target@example.com") }
            XCTFail("expected the switch to fail")
        } catch ClaudeServiceError.keychainWriteFailed {
            XCTAssertEqual(store.liveToken, sourceToken(), "the source token was not restored")
            XCTAssertEqual(store.liveEmail, "source@example.com")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOAuthWriteFailureRollsBack() async {
        let store = makeStore()
        // Only the switch's own write fails; the rollback's write works, which
        // is the case this test is about. (Both failing is the next test.)
        store.oauthWriteFailures = 1
        do {
            _ = try await switchAccount(store: store) { self.loggedIn(as: "target@example.com") }
            XCTFail("expected the switch to fail")
        } catch ClaudeServiceError.oauthAccountWriteFailed {
            XCTAssertEqual(store.liveToken, sourceToken())
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testVerificationThrowRollsBack() async {
        struct Boom: Error {}
        let store = makeStore()
        do {
            _ = try await switchAccount(store: store) { throw Boom() }
            XCTFail("expected the switch to fail")
        } catch is Boom {
            XCTAssertEqual(store.liveToken, sourceToken())
            XCTAssertEqual(store.liveEmail, "source@example.com")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCliReportingNoLoginRollsBack() async {
        let store = makeStore()
        do {
            _ = try await switchAccount(store: store) {
                AuthStatus(loggedIn: false, authMethod: nil, apiProvider: nil, email: nil, orgId: nil, orgName: nil, subscriptionType: nil)
            }
            XCTFail("expected the switch to fail")
        } catch ClaudeServiceError.switchVerificationFailed {
            XCTAssertEqual(store.liveToken, sourceToken())
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCliReportingADifferentAccountRollsBack() async {
        let store = makeStore()
        do {
            _ = try await switchAccount(store: store) { self.loggedIn(as: "someone-else@example.com") }
            XCTFail("expected the switch to fail")
        } catch ClaudeServiceError.switchWrongAccount {
            XCTAssertEqual(store.liveToken, sourceToken())
            XCTAssertEqual(store.liveEmail, "source@example.com")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A keychain that refuses writes refuses them for the rollback too — the
    /// realistic failure (locked keychain, denied ACL) is persistent, not a
    /// one-off. The user ends up signed in to neither account, and that has to
    /// be said out loud.
    func testPersistentTokenWriteFailureReportsTheLockout() async {
        let store = makeStore()
        store.failTokenWrites = true
        do {
            _ = try await switchAccount(store: store) { self.loggedIn(as: "target@example.com") }
            XCTFail("expected an error")
        } catch ClaudeServiceError.rollbackFailed(let email, let tokenRestored, let oauthRestored, let cause) {
            XCTAssertEqual(email, source.email)
            XCTAssertFalse(tokenRestored)
            XCTAssertTrue(oauthRestored)
            // The lockout is the headline, but the reason the switch failed is
            // what tells the user what to do differently.
            XCTAssertNotNil(cause, "the original failure was dropped")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The CLI can hide the identity block entirely (env token, apiKeyHelper…),
    /// in which case the switch is verified against the credential store. That
    /// branch has its own rollback.
    func testCredentialStoreMismatchRollsBack() async {
        let store = makeStore()
        do {
            _ = try await switchAccount(store: store) {
                // Logged in, but no email — so the comparison against the
                // credential store decides. Another process rewriting
                // ~/.claude.json back to the source account between our write
                // and our check is exactly the situation the anchor exists for,
                // so that is what is simulated here.
                store.liveOAuth = ["emailAddress": AnyCodable("source@example.com")]
                return AuthStatus(loggedIn: true, authMethod: "ANTHROPIC_API_KEY", apiProvider: nil, email: nil, orgId: nil, orgName: nil, subscriptionType: nil)
            }
            XCTFail("expected the switch to fail")
        } catch ClaudeServiceError.credentialStoreMismatch {
            // Its own error, not the generic "verification failed": what
            // happened is that something rewrote the store behind us, and the
            // message the user sees should say so.
            XCTAssertEqual(store.liveToken, sourceToken(), "the source token was not restored")
            XCTAssertEqual(store.liveEmail, "source@example.com")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The worst case: the switch failed AND the rollback could not put the
    /// previous sign-in back. That must be an error the user sees, not a log line.
    func testRollbackFailureIsReported() async {
        let store = makeStore()
        store.failOAuthWrites = true   // fails the switch, then fails the rollback
        do {
            _ = try await switchAccount(store: store) { self.loggedIn(as: "target@example.com") }
            XCTFail("expected an error")
        } catch ClaudeServiceError.rollbackFailed(let email, let tokenRestored, let oauthRestored, let cause) {
            XCTAssertEqual(email, source.email)
            XCTAssertTrue(tokenRestored)
            XCTAssertFalse(oauthRestored)
            XCTAssertNotNil(cause, "the original failure was dropped")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSuccessfulSwitchLeavesTheTargetLive() async throws {
        let store = makeStore()
        let outcome = try await switchAccount(store: store) { self.loggedIn(as: "target@example.com") }
        XCTAssertNil(outcome.shadowedBy)
        XCTAssertEqual(store.liveToken, targetBackup().token)
        XCTAssertEqual(store.liveEmail, "target@example.com")
    }
}
