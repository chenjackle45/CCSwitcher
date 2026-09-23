import XCTest

/// Drag-to-reorder: the card you drop on is the one the dragged card replaces.
final class AccountOrderTests: XCTestCase {

    private let a = Account(email: "a@example.com", displayName: "A")
    private let b = Account(email: "b@example.com", displayName: "B")
    private let c = Account(email: "c@example.com", displayName: "C")
    private let d = Account(email: "d@example.com", displayName: "D")

    private func emails(_ accounts: [Account]) -> [String] { accounts.map(\.email) }

    /// Dropping A on C must land A after C. `move(fromOffsets: [0], toOffset: 2)`
    /// — the List-style off-by-one — would give B, A, C, D instead.
    func testDraggingDownLandsAfterTheTarget() {
        let moved = AccountOrder.moving([a, b, c, d], a.id, onto: c.id)
        XCTAssertEqual(emails(moved), emails([b, c, a, d]))
    }

    func testDraggingUpLandsBeforeTheTarget() {
        let moved = AccountOrder.moving([a, b, c, d], d.id, onto: b.id)
        XCTAssertEqual(emails(moved), emails([a, d, b, c]))
    }

    func testDroppingOnItselfChangesNothing() {
        let moved = AccountOrder.moving([a, b, c, d], b.id, onto: b.id)
        XCTAssertEqual(emails(moved), emails([a, b, c, d]))
    }

    /// A drag whose account was removed mid-drag, or a stray UUID, is ignored.
    func testUnknownIdsLeaveTheOrderAlone() {
        let stranger = UUID()
        XCTAssertEqual(emails(AccountOrder.moving([a, b, c], stranger, onto: b.id)), emails([a, b, c]))
        XCTAssertEqual(emails(AccountOrder.moving([a, b, c], a.id, onto: stranger)), emails([a, b, c]))
    }
}
