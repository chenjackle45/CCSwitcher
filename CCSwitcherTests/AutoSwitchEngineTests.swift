import XCTest

/// The ranking rules the user's account list introduces. None of these are
/// visible to a compiler or to "the app still builds": they are decisions about
/// which account gets switched to.
final class AutoSwitchEngineTests: XCTestCase {

    private let active = Account(email: "active@example.com", displayName: "Active", provider: .claudeCode, isActive: true)
    private let b = Account(email: "b@example.com", displayName: "B", provider: .claudeCode)
    private let c = Account(email: "c@example.com", displayName: "C", provider: .claudeCode)
    private let d = Account(email: "d@example.com", displayName: "D", provider: .claudeCode)

    /// A reading that is current (resets an hour from now).
    private func usage(_ utilization: Double) -> UsageAPIResponse {
        let resetsAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let json = """
        {"five_hour":{"utilization":\(utilization),"resets_at":"\(resetsAt)"},
         "seven_day":{"utilization":\(utilization),"resets_at":"\(resetsAt)"}}
        """
        return try! JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
    }

    private func rank(
        targetIds: [UUID],
        policy: AutoSwitchPolicy,
        usageByAccount: [UUID: UsageAPIResponse]
    ) -> [Account] {
        AutoSwitchEngine.rankedTargets(
            active: active,
            candidates: [b, c, d],
            usageByAccount: usageByAccount,
            isSwitchable: { _ in true },
            activeSampledThisCycle: true,
            targetIds: targetIds,
            policy: policy,
            threshold: 90,
            hysteresisPct: 10
        )
    }

    private func usageMap(activeUtil: Double = 95, b: Double, c: Double, d: Double) -> [UUID: UsageAPIResponse] {
        [
            active.id: usage(activeUtil),
            self.b.id: usage(b),
            self.c.id: usage(c),
            self.d.id: usage(d)
        ]
    }

    // MARK: - The two policies

    func testMostHeadroomPicksTheLowestUsageAmongSelected() {
        let ranked = rank(targetIds: [b.id, c.id], policy: .mostHeadroom,
                          usageByAccount: usageMap(b: 70, c: 20, d: 0))
        XCTAssertEqual(ranked.map(\.id), [c.id, b.id])
    }

    func testListOrderPicksTheFirstSelectedThatQualifies() {
        let ranked = rank(targetIds: [b.id, c.id], policy: .listOrder,
                          usageByAccount: usageMap(b: 70, c: 20, d: 0))
        XCTAssertEqual(ranked.map(\.id), [b.id, c.id])
    }

    func testListOrderSkipsASelectedAccountThatIsTooHigh() {
        // B is above the ceiling (90 - 10), so the user's first choice cannot
        // be taken and C — still selected — comes first.
        let ranked = rank(targetIds: [b.id, c.id], policy: .listOrder,
                          usageByAccount: usageMap(b: 85, c: 20, d: 0))
        XCTAssertEqual(ranked.map(\.id), [c.id])
    }

    // MARK: - The list is a restriction

    func testAnUnselectedAccountIsNeverChosenEvenAtZeroUsage() {
        let ranked = rank(targetIds: [b.id, c.id], policy: .mostHeadroom,
                          usageByAccount: usageMap(b: 70, c: 20, d: 0))
        XCTAssertFalse(ranked.contains { $0.id == d.id })
    }

    func testANonEmptyListWithNoQualifyingMemberStaysPut() {
        // Both selected accounts are too high; D is idle but not selected.
        // Falling back to "everyone" here would be the bug.
        let ranked = rank(targetIds: [b.id, c.id], policy: .mostHeadroom,
                          usageByAccount: usageMap(b: 95, c: 92, d: 0))
        XCTAssertTrue(ranked.isEmpty)
    }

    // MARK: - Empty list means "no restriction"

    func testEmptyListBehavesLikeBefore() {
        for policy in AutoSwitchPolicy.allCases {
            let ranked = rank(targetIds: [], policy: policy,
                              usageByAccount: usageMap(b: 70, c: 20, d: 5))
            XCTAssertEqual(ranked.map(\.id), [d.id, c.id, b.id], "policy \(policy) changed the unrestricted ordering")
        }
    }

    // MARK: - Trigger still applies

    func testNothingIsRankedUntilTheActiveAccountReachesTheThreshold() {
        let ranked = rank(targetIds: [b.id], policy: .listOrder,
                          usageByAccount: usageMap(activeUtil: 50, b: 10, c: 10, d: 10))
        XCTAssertTrue(ranked.isEmpty)
    }
}
