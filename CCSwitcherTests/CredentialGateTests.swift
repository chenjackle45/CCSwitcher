import XCTest

@MainActor
final class CredentialGateTests: XCTestCase {

    func testSecondHolderWaitsForTheFirstToRelease() async {
        let gate = CredentialGate()
        var order: [String] = []

        await gate.acquire("first")
        let second = Task { @MainActor in
            await gate.acquire("second")
            order.append("second-in")
            gate.release("second")
        }

        // Give the waiting task a chance to run; it must still be blocked.
        await Task.yield()
        XCTAssertEqual(order, [], "second got in while first still held the gate")

        order.append("first-out")
        gate.release("first")
        await second.value

        XCTAssertEqual(order, ["first-out", "second-in"])
    }

    func testWaitersAreResumedInOrder() async {
        let gate = CredentialGate()
        var order: [Int] = []

        await gate.acquire("holder")
        var tasks: [Task<Void, Never>] = []
        for i in 1...3 {
            tasks.append(Task { @MainActor in
                await gate.acquire("waiter-\(i)")
                order.append(i)
                gate.release("waiter-\(i)")
            })
            // Each waiter must be queued before the next one is created,
            // otherwise the test would be asserting on scheduling luck.
            await Task.yield()
        }

        gate.release("holder")
        for task in tasks { await task.value }

        XCTAssertEqual(order, [1, 2, 3])
    }

    func testGateIsReleasedWhenTheBodyThrows() async {
        let gate = CredentialGate()
        struct Boom: Error {}

        do {
            try await gate.withGate("throwing") { throw Boom() }
            XCTFail("expected the error to propagate")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        await gate.acquire("after")   // would hang if the gate were still held
        gate.release("after")
    }
}
