import Foundation

/// The user's display order for accounts. The accounts tab, the usage tab and
/// the widgets all read `AppState.accounts` as-is, so reordering that one
/// array is what keeps them in step.
enum AccountOrder {
    /// Moves `dragged` into the slot `target` occupies. Dragging down lands it
    /// after `target`, dragging up lands it before — the card you drop on is
    /// the one it takes the place of. Unknown ids leave the order untouched.
    static func moving(_ accounts: [Account], _ dragged: UUID, onto target: UUID) -> [Account] {
        guard let from = accounts.firstIndex(where: { $0.id == dragged }),
              let to = accounts.firstIndex(where: { $0.id == target }) else { return accounts }
        var reordered = accounts
        reordered.insert(reordered.remove(at: from), at: to)
        return reordered
    }
}
