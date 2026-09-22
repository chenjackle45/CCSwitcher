import XCTest

/// Usage samples are not kept across launches, so a fresh launch used to show
/// the active account plus one other and leave the rest on "waiting for usage
/// data" for up to half an hour. One sweep fixes that; a sweep that repeats
/// would be a rate-limit storm — so these drive consecutive cycles rather
/// than asking for one cycle at a time.
final class UsageFetchRotationTests: XCTestCase {

    private func accounts(_ count: Int, activeIndex: Int? = 0) -> [Account] {
        (0..<count).map { i in
            Account(email: "a\(i)@example.com", displayName: "A\(i)", isActive: i == activeIndex)
        }
    }

    func testTheFirstCycleTakesEveryEligibleAccountOnce() {
        let all = accounts(8)
        var rotation = UsageFetchRotation()
        let first = rotation.next(eligible: all)

        XCTAssertTrue(first.isSweep)
        XCTAssertEqual(first.targets.count, 8)
        XCTAssertEqual(Set(first.targets.map(\.id)).count, 8, "no account asked twice in one cycle")
        XCTAssertEqual(first.targets.first?.id, all[0].id, "the active account goes first")
    }

    /// The point of the one-shot flag: cycle two onwards is the old behaviour,
    /// no matter what happened in cycle one.
    func testEveryCycleAfterTheFirstIsTheActiveAccountPlusOne() {
        let all = accounts(8)
        var rotation = UsageFetchRotation()
        _ = rotation.next(eligible: all)

        for cycle in 1...5 {
            let plan = rotation.next(eligible: all)
            XCTAssertFalse(plan.isSweep, "cycle \(cycle) swept again")
            XCTAssertEqual(plan.targets.count, 2, "cycle \(cycle)")
            XCTAssertEqual(plan.targets[0].id, all[0].id)
            XCTAssertFalse(plan.targets[1].isActive)
        }
    }

    /// The sweep sampled everyone, so it must not also skip the account the
    /// cursor was pointing at — the cycle after a sweep starts from the top.
    func testTheRotationStartsFromTheTopAfterTheSweep() {
        let all = accounts(4)
        var rotation = UsageFetchRotation()
        _ = rotation.next(eligible: all)
        XCTAssertEqual(rotation.next(eligible: all).targets[1].id, all[1].id)
    }

    func testTheRotationVisitsEveryOtherAccountBeforeRepeating() {
        let all = accounts(4)   // one active, three others
        var rotation = UsageFetchRotation()
        _ = rotation.next(eligible: all)

        let seen = (0..<4).map { _ in rotation.next(eligible: all).targets[1].id }
        XCTAssertEqual(seen, [all[1].id, all[2].id, all[3].id, all[1].id],
                       "three others in order, then back to the first")
    }

    /// Parked accounts never reach the rotation, so a sweep during a partial
    /// outage fills what it can and the rest come back through the rotation.
    func testASweepOnlyCoversWhatItWasGiven() {
        let all = accounts(8)
        var rotation = UsageFetchRotation()
        let plan = rotation.next(eligible: Array(all.prefix(3)))
        XCTAssertEqual(plan.targets.count, 3)
    }

    func testASingleAccountIsNotAskedTwice() {
        let only = accounts(1)
        var rotation = UsageFetchRotation()
        XCTAssertEqual(rotation.next(eligible: only).targets.count, 1)
        XCTAssertEqual(rotation.next(eligible: only).targets.count, 1)
    }

    /// Right after a switch the new account may not be flagged active yet;
    /// the cycle must still produce work rather than an empty request list.
    func testNoActiveAccountStillSamplesOneOther() {
        let all = accounts(4, activeIndex: nil)
        var rotation = UsageFetchRotation()
        _ = rotation.next(eligible: all)
        let plan = rotation.next(eligible: all)
        XCTAssertEqual(plan.targets.count, 1)
        XCTAssertEqual(plan.targets[0].id, all[0].id)
    }

    /// A second rotation is a second launch: the sweep belongs to the
    /// instance, not to the account list.
    func testEachRotationSweepsOnceOnItsOwn() {
        let all = accounts(3)
        var first = UsageFetchRotation()
        _ = first.next(eligible: all)
        XCTAssertFalse(first.next(eligible: all).isSweep)

        var second = UsageFetchRotation()
        XCTAssertTrue(second.next(eligible: all).isSweep)
    }
}
