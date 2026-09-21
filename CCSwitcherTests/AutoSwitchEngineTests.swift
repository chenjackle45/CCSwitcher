import XCTest

/// The ranking rules the user's account list introduces. None of these are
/// visible to a compiler or to "the app still builds": they are decisions about
/// which account gets switched to.
final class AutoSwitchEngineTests: XCTestCase {

    private let active = Account(email: "active@example.com", displayName: "Active", provider: .claudeCode, isActive: true)
    private let b = Account(email: "b@example.com", displayName: "B", provider: .claudeCode)
    private let c = Account(email: "c@example.com", displayName: "C", provider: .claudeCode)
    private let d = Account(email: "d@example.com", displayName: "D", provider: .claudeCode)

    /// A response shaped like the real one: the `limits` array, carrying the
    /// session window, the account-wide week, and a Fable-scoped week.
    private func usageWithFable(session: Double, weekly: Double, fable: Double) -> UsageAPIResponse {
        let resetsAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let json = """
        {"limits":[
          {"kind":"session","percent":\(session),"resets_at":"\(resetsAt)"},
          {"kind":"weekly_all","percent":\(weekly),"resets_at":"\(resetsAt)"},
          {"kind":"weekly_scoped","percent":\(fable),"resets_at":"\(resetsAt)",
           "scope":{"model":{"display_name":"Fable"}}}
        ]}
        """
        return try! JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
    }

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

    // MARK: - Model-scoped limits count

    /// The account that is actually blocked: session and week look fine, but
    /// its Fable week is spent. Watching only the top-level windows made this
    /// account look idle and it never switched away.
    func testAModelScopedLimitTriggersASwitch() {
        let usageByAccount: [UUID: UsageAPIResponse] = [
            active.id: usageWithFable(session: 2, weekly: 66, fable: 92),
            b.id: usage(20)
        ]
        let ranked = rank(targetIds: [], policy: .mostHeadroom, usageByAccount: usageByAccount)
        XCTAssertEqual(ranked.map(\.id), [b.id], "a spent Fable week must count as reaching the threshold")
    }

    /// The mirror case: a candidate whose Fable week is gone is not headroom,
    /// however idle its other windows look. Switching to it would land on an
    /// account that cannot run the model being used.
    ///
    /// Note: this one passed before the fix too, but for the wrong reason — the
    /// old code could not read a `limits`-only response at all, so the account
    /// was excluded as "no reading" rather than as "no headroom". It is here to
    /// pin the right reason.
    func testACandidateWithASpentModelLimitIsNotEligible() {
        let usageByAccount: [UUID: UsageAPIResponse] = [
            active.id: usage(95),
            b.id: usageWithFable(session: 0, weekly: 10, fable: 100),
            c.id: usage(20)
        ]
        // Pin the REASON, not just the outcome: the old code also left b out,
        // but because it could not read a limits-only response at all. This
        // asserts b is excluded for having no headroom.
        XCTAssertEqual(AutoSwitchEngine.bindingUtilization(usageWithFable(session: 0, weekly: 10, fable: 100)), 100)
        let ranked = rank(targetIds: [], policy: .mostHeadroom, usageByAccount: usageByAccount)
        XCTAssertEqual(ranked.map(\.id), [c.id], "b is blocked on Fable and must not be offered as the roomiest")
    }

    /// Below the ceiling on every window, including the scoped one: still eligible.
    func testAModelScopedLimitWithHeadroomDoesNotExcludeACandidate() {
        let usageByAccount: [UUID: UsageAPIResponse] = [
            active.id: usage(95),
            b.id: usageWithFable(session: 5, weekly: 40, fable: 55)
        ]
        let ranked = rank(targetIds: [], policy: .mostHeadroom, usageByAccount: usageByAccount)
        XCTAssertEqual(ranked.map(\.id), [b.id])
    }

    // MARK: - Trigger still applies

    func testNothingIsRankedUntilTheActiveAccountReachesTheThreshold() {
        let ranked = rank(targetIds: [b.id], policy: .listOrder,
                          usageByAccount: usageMap(activeUtil: 50, b: 10, c: 10, d: 10))
        XCTAssertTrue(ranked.isEmpty)
    }
}
