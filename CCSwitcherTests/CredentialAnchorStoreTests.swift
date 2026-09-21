import XCTest

/// Rules the anchor store must hold, in the order they bite in practice.
final class CredentialAnchorStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    private let tokenA = "token-A"
    private let tokenB = "token-B"
    private let accountA = UUID()
    private let accountB = UUID()

    override func setUp() {
        super.setUp()
        suiteName = "ccswitcher.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> CredentialAnchorStore {
        CredentialAnchorStore(defaults: defaults)
    }

    // MARK: - First trust

    func testAdoptsTheIdentityBlockOnceWhenNothingHasEverBeenAnchored() {
        let store = makeStore()
        XCTAssertEqual(store.resolveOwner(accessToken: tokenA, claimedAccountId: accountA), .owned(accountA))
        // ...and the record it wrote is what answers next time, not the block.
        XCTAssertEqual(store.resolveOwner(accessToken: tokenA, claimedAccountId: accountB), .desynced(claimed: accountB, credential: accountA))
    }

    func testNoIdentityAndNoRecordIsUnknown() {
        let store = makeStore()
        XCTAssertEqual(store.resolveOwner(accessToken: tokenA, claimedAccountId: nil), .unknown)
    }

    // MARK: - Removal must not reopen the first-trust door

    func testForgettingTheAnchoredAccountLeavesTheOwnerUnknownForever() {
        let store = makeStore()
        store.anchor(accountId: accountA, accessToken: tokenA)

        store.forget(accountId: accountA)

        // The record is still there — as "unknown" — so the identity block
        // cannot be adopted a second time.
        XCTAssertEqual(store.resolveOwner(accessToken: tokenA, claimedAccountId: accountB), .unknown)
        XCTAssertEqual(store.resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .unknown)
        // A fresh instance reads the same persisted record.
        XCTAssertEqual(makeStore().resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .unknown)
    }

    func testForgettingSomeOtherAccountLeavesTheAnchorAlone() {
        let store = makeStore()
        store.anchor(accountId: accountA, accessToken: tokenA)
        store.forget(accountId: accountB)
        XCTAssertEqual(store.resolveOwner(accessToken: tokenA, claimedAccountId: accountA), .owned(accountA))
    }

    // MARK: - Desync

    func testIdentityFlipOnAnUnchangedCredentialIsADesync() {
        let store = makeStore()
        store.anchor(accountId: accountA, accessToken: tokenA)
        XCTAssertEqual(store.resolveOwner(accessToken: tokenA, claimedAccountId: accountB), .desynced(claimed: accountB, credential: accountA))
        // Sticky: the block agreeing again does not clear it.
        XCTAssertEqual(store.resolveOwner(accessToken: tokenA, claimedAccountId: accountA), .desynced(claimed: accountA, credential: accountA))
    }

    func testRotationWhileDesyncedMakesTheOwnerUnknownAndKeepsItThatWay() {
        let store = makeStore()
        store.anchor(accountId: accountA, accessToken: tokenA)
        _ = store.resolveOwner(accessToken: tokenA, claimedAccountId: accountB)  // desync

        XCTAssertEqual(store.resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .unknown)
        // Asked twice, and from a rebuilt store: still unknown.
        XCTAssertEqual(store.resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .unknown)
        XCTAssertEqual(makeStore().resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .unknown)
    }

    func testAnchoringIsTheWayOutOfUnknown() {
        let store = makeStore()
        store.anchor(accountId: accountA, accessToken: tokenA)
        _ = store.resolveOwner(accessToken: tokenA, claimedAccountId: accountB)
        _ = store.resolveOwner(accessToken: tokenB, claimedAccountId: accountB)
        XCTAssertEqual(store.resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .unknown)

        store.anchor(accountId: accountB, accessToken: tokenB)
        XCTAssertEqual(store.resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .owned(accountB))
    }

    // MARK: - Ordinary rotation

    func testOrdinaryRotationFollowsTheIdentityBlock() {
        let store = makeStore()
        store.anchor(accountId: accountA, accessToken: tokenA)
        XCTAssertEqual(store.resolveOwner(accessToken: tokenB, claimedAccountId: accountA), .owned(accountA))
    }

    /// The dangerous shape of a rotation: the token changed AND the identity
    /// block now names a different account. Those two only have to land between
    /// two observations — a night's sleep is enough — so believing the block
    /// here is how one account's token gets adopted as another's.
    func testRotationWithADifferentIdentityMakesTheOwnerUnknown() {
        let store = makeStore()
        store.anchor(accountId: accountA, accessToken: tokenA)

        XCTAssertEqual(store.resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .unknown)
        // Sticky, and survives a rebuilt store.
        XCTAssertEqual(store.resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .unknown)
        XCTAssertEqual(makeStore().resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .unknown)
        // Re-authenticating is the way back.
        store.anchor(accountId: accountB, accessToken: tokenB)
        XCTAssertEqual(store.resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .owned(accountB))
    }

    // MARK: - Old records

    func testARecordWrittenBeforeTheFlagsExistedStillDecodes() throws {
        let legacy = try JSONSerialization.data(withJSONObject: [
            "accountId": accountA.uuidString,
            "fingerprint": CredentialAnchorStore.fingerprint(of: tokenA)
        ])
        defaults.set(legacy, forKey: "com.ccswitcher.credentialAnchor")

        let store = makeStore()
        XCTAssertEqual(store.resolveOwner(accessToken: tokenA, claimedAccountId: accountA), .owned(accountA))
        // And it counts as "something has been anchored": removing it must not
        // hand the next identity block a fresh first-trust.
        store.forget(accountId: accountA)
        XCTAssertEqual(store.resolveOwner(accessToken: tokenB, claimedAccountId: accountB), .unknown)
    }
}
