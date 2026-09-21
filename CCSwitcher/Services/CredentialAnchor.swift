import Foundation
import CryptoKit

private let log = FileLog("Anchor")

/// Who the credential currently sitting in the keychain actually belongs to.
enum LiveCredentialOwner: Equatable {
    /// The live credential is known to be this account's.
    case owned(UUID)
    /// The live credential belongs to `credential`, but `~/.claude.json` names
    /// someone else. Usage still attributes to `credential` — that is the token
    /// every API call is billed against — while the identity block is wrong.
    case desynced(claimed: UUID?, credential: UUID)
    /// No credential, or nothing left tying it to a known account.
    case unknown

    /// The account the live credential belongs to, if that is knowable at all.
    var credentialAccountId: UUID? {
        switch self {
        case .owned(let id): return id
        case .desynced(_, let id): return id
        case .unknown: return nil
        }
    }
}

/// Tracks which account the live keychain credential belongs to.
///
/// The obvious answer — `~/.claude.json`'s identity block — is not trustworthy:
/// every running Claude Code session rewrites that block from its own cached
/// profile, so it can name account B seconds after a switch while the keychain
/// still holds account A's token. Everything downstream then misfiles A as B:
/// A's usage reading lands on B's card, and the next switch backs A's token up
/// as B's stored credential, permanently swapping the two accounts.
///
/// So pair the account with a fingerprint of the credential instead, taken at
/// the one moment the two halves are known to agree: when CCSwitcher itself
/// wrote them. An unchanged fingerprint proves the credential did not change,
/// whatever the identity block now claims.
///
/// A rotation the identity block follows (same account, new token) keeps the
/// pairing. A rotation it does NOT follow makes the owner unknown rather than
/// adopting whoever the block now names: the two events only have to land
/// between two observations to look simultaneous, and with the app closed or
/// the Mac asleep that gap has no bound. The cost is that signing in to a
/// different account outside CCSwitcher needs one switch or re-authentication
/// here before usage is attributed again.
final class CredentialAnchorStore {
    private struct Anchor: Codable {
        var accountId: UUID
        var fingerprint: String
        /// Set once the identity block has been seen disagreeing with a
        /// credential that did not change. Sticky on purpose: clearing it on the
        /// next rotation would let the desync resume misfiling the moment the
        /// token rolls, which is exactly how the original swap went unnoticed.
        var isDesynced: Bool
        /// Nothing ties the live credential to an account any more. Also sticky,
        /// and also only `anchor()` clears it: every other way out would let a
        /// rewritten identity block re-establish a pairing it cannot prove.
        var ownerUnknown: Bool

        init(accountId: UUID, fingerprint: String, isDesynced: Bool, ownerUnknown: Bool = false) {
            self.accountId = accountId
            self.fingerprint = fingerprint
            self.isDesynced = isDesynced
            self.ownerUnknown = ownerUnknown
        }

        /// Hand-written so a record saved by an older build — which has neither
        /// flag — still decodes instead of being discarded as corrupt.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accountId = try c.decode(UUID.self, forKey: .accountId)
            fingerprint = try c.decode(String.self, forKey: .fingerprint)
            isDesynced = try c.decodeIfPresent(Bool.self, forKey: .isDesynced) ?? false
            ownerUnknown = try c.decodeIfPresent(Bool.self, forKey: .ownerUnknown) ?? false
        }
    }

    private let defaults: UserDefaults
    private let key = "com.ccswitcher.credentialAnchor"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Hash rather than the token itself: this lands in UserDefaults, which is
    /// not a credential store.
    static func fingerprint(of accessToken: String) -> String {
        SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Record that `accountId` owns the live credential.
    ///
    /// Call this only where CCSwitcher established the pairing itself — a
    /// switch, a login, a re-authentication — never from something the identity
    /// block merely asserts. This is also the only way out of a desync.
    func anchor(accountId: UUID, accessToken: String) {
        let anchor = Anchor(accountId: accountId, fingerprint: Self.fingerprint(of: accessToken), isDesynced: false)
        save(anchor)
        log.info("[anchor] Live credential anchored to \(accountId) (\(short(anchor.fingerprint)))")
    }

    /// The anchored account was removed: the pairing is gone, but the RECORD
    /// stays. Deleting it would put the store back in its "nothing has ever been
    /// anchored" state, which is the one state that trusts the identity block —
    /// so a desynced credential could be re-adopted under whichever account the
    /// block happens to name next.
    func forget(accountId: UUID) {
        guard var stored = load(), stored.accountId == accountId, !stored.ownerUnknown else { return }
        stored.ownerUnknown = true
        save(stored)
        log.info("[anchor] Anchored account \(accountId) was removed; live credential owner is now unknown")
    }

    /// Resolve who the live credential belongs to.
    ///
    /// - Parameters:
    ///   - accessToken: the access token currently in the keychain, if any.
    ///   - claimedAccountId: the account `~/.claude.json` says is signed in.
    func resolveOwner(accessToken: String?, claimedAccountId: UUID?) -> LiveCredentialOwner {
        guard let accessToken else { return .unknown }
        let fingerprint = Self.fingerprint(of: accessToken)

        guard var stored = load() else {
            // No record has EVER been written: a fresh install, or the first
            // launch after upgrading from a build without anchoring. Adopting
            // the identity block once is the only way to take over an existing
            // login without making the user sign in again — and it is the only
            // place that trust is granted. `forget()` keeps the record around
            // precisely so this state cannot recur later.
            guard let claimedAccountId else { return .unknown }
            save(Anchor(accountId: claimedAccountId, fingerprint: fingerprint, isDesynced: false))
            log.info("[anchor] No record yet; adopting the identity block's \(claimedAccountId) once")
            return .owned(claimedAccountId)
        }

        if stored.ownerUnknown {
            // Sticky. No fingerprint update, no write: only `anchor()` — a
            // switch, login or re-authentication CCSwitcher performed itself —
            // can establish a pairing again.
            return .unknown
        }

        if stored.fingerprint == fingerprint {
            // The credential has not moved since it was anchored, so it still
            // belongs to the anchored account no matter what the file says.
            if stored.isDesynced {
                return .desynced(claimed: claimedAccountId, credential: stored.accountId)
            }
            if let claimedAccountId, claimedAccountId != stored.accountId {
                stored.isDesynced = true
                save(stored)
                log.warning("[anchor] Identity block flipped to \(claimedAccountId) while the credential stayed \(stored.accountId)'s")
                return .desynced(claimed: claimedAccountId, credential: stored.accountId)
            }
            return .owned(stored.accountId)
        }

        // The credential itself changed.
        if stored.isDesynced {
            // It rolled while the identity block was already untrustworthy, so
            // nothing ties it to an account any more. Only a CCSwitcher-performed
            // write can re-establish the pairing.
            stored.fingerprint = fingerprint
            stored.ownerUnknown = true
            save(stored)
            log.warning("[anchor] Credential rotated while desynced; owner is now unknown")
            return .unknown
        }

        // The credential rotated. A running Claude Code session refreshing the
        // token it already had is the common case, and the identity block still
        // naming the anchored account is what says so — refresh the fingerprint
        // and keep the pairing.
        //
        // The block naming someone ELSE is not evidence of anything: the two
        // changes only have to land between two of our observations to look
        // simultaneous, and that gap is unbounded (app closed, Mac asleep).
        // Believing it there is how A's token gets adopted as B's — the exact
        // swap this store exists to prevent — so the owner becomes unknown
        // until CCSwitcher itself writes a pairing again.
        guard let claimedAccountId, claimedAccountId == stored.accountId else {
            stored.fingerprint = fingerprint
            stored.ownerUnknown = true
            save(stored)
            if let claimedAccountId {
                log.warning("[anchor] Credential rotated and the identity block moved to \(claimedAccountId); owner is now unknown")
            } else {
                // No claim at all: the identity block could not be read, or it
                // names an account this app does not know about.
                log.warning("[anchor] Credential rotated and the identity block names nobody this app knows (unreadable, or an account not in the list); owner is now unknown")
            }
            return .unknown
        }
        save(Anchor(accountId: claimedAccountId, fingerprint: fingerprint, isDesynced: false))
        return .owned(claimedAccountId)
    }

    // MARK: - Persistence

    private func load() -> Anchor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Anchor.self, from: data)
    }

    private func save(_ anchor: Anchor) {
        guard let data = try? JSONEncoder().encode(anchor) else { return }
        defaults.set(data, forKey: key)
    }

    private func short(_ fingerprint: String) -> String {
        String(fingerprint.prefix(8))
    }
}
