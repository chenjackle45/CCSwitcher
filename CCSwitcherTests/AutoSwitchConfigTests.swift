import XCTest

/// The stored account list is the only thing standing between "the user ticked
/// three accounts" and "auto-switch picks whoever it likes", so its editing
/// rules get tests even though they look trivial.
@MainActor
final class AutoSwitchConfigTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()
    private var defaults: UserDefaults!
    private var suiteName: String!

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

    /// Built on its own defaults suite, so these tests neither read nor write
    /// the real preferences.
    private func makeConfig(_ ids: [UUID] = []) -> AutoSwitchConfig {
        let config = AutoSwitchConfig(defaults: defaults)
        config.targetIds = ids
        return config
    }

    func testTickingAppendsToTheEndAndUntickingRemoves() {
        let config = makeConfig()
        config.setSelected(true, for: a)
        config.setSelected(true, for: b)
        XCTAssertEqual(config.targetIds, [a, b])

        config.setSelected(true, for: a)  // already ticked, must not duplicate
        XCTAssertEqual(config.targetIds, [a, b])

        config.setSelected(false, for: a)
        XCTAssertEqual(config.targetIds, [b])
    }

    func testReorderKeepsOnlySelectedAccountsAndTheirNewOrder() {
        let config = makeConfig([a, b])
        // The screen shows every account; only the ticked ones carry priority.
        config.applyOrder([c, b, a])
        XCTAssertEqual(config.targetIds, [b, a])
    }

    func testAReorderThatCannotSeeEverySelectedAccountIsIgnored() {
        let config = makeConfig([a, b])
        // A view missing `b` must not be allowed to drop it.
        config.applyOrder([a, c])
        XCTAssertEqual(config.targetIds, [a, b])
    }

    func testPruneDropsOnlyAccountsThatNoLongerExist() {
        let config = makeConfig([a, b, c])
        config.prune(existingAccountIds: [a, c])
        XCTAssertEqual(config.targetIds, [a, c])
    }

    func testPruneKeepsOrderAndIsANoOpWhenEverythingStillExists() {
        let config = makeConfig([c, a])
        config.prune(existingAccountIds: [a, b, c])
        XCTAssertEqual(config.targetIds, [c, a])
    }

    func testClearingSelectionMeansEveryAccountIsAllowedAgain() {
        let config = makeConfig([a, b])
        config.clearSelection()
        XCTAssertTrue(config.targetIds.isEmpty, "empty is what 'no restriction' looks like to the engine")
    }

    // MARK: - What is read back from disk

    func testDuplicateIdsInStoredDefaultsAreDroppedOnLoad() {
        // Stored defaults are the one input this type does not control, so the
        // defence sits where they enter: a duplicate would otherwise count
        // twice and make every reorder fail `applyOrder`'s count guard.
        defaults.set([a.uuidString, b.uuidString, a.uuidString], forKey: "autoSwitchTargets")
        XCTAssertEqual(AutoSwitchConfig(defaults: defaults).targetIds, [a, b])
    }

    func testUnparseableIdsInStoredDefaultsAreIgnored() {
        defaults.set(["not-a-uuid", a.uuidString], forKey: "autoSwitchTargets")
        XCTAssertEqual(AutoSwitchConfig(defaults: defaults).targetIds, [a])
    }

    func testSelectionAndPolicySurviveAReload() {
        let config = makeConfig([b, a])
        config.policy = .listOrder

        let reloaded = AutoSwitchConfig(defaults: defaults)
        XCTAssertEqual(reloaded.targetIds, [b, a], "priority order must survive a restart")
        XCTAssertEqual(reloaded.policy, .listOrder)
    }

    func testAnUnknownStoredPolicyFallsBackToMostHeadroom() {
        defaults.set("something-else", forKey: "autoSwitchPolicy")
        XCTAssertEqual(AutoSwitchConfig(defaults: defaults).policy, .mostHeadroom)
    }
}
