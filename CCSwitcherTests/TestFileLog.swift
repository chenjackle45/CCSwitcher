import Foundation

/// Stand-in for the app's `FileLog`.
///
/// The real one (`Services/FileLogger.swift`) opens and rotates the user's log
/// file under ~/Library/Logs — a unit test bundle must not touch it, so that
/// file is excluded from this target and this no-op takes its place. Same
/// shape, so the code under test compiles unchanged.
struct FileLog: Sendable {
    private let category: String
    init(_ category: String) { self.category = category }
    func info(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
    func debug(_ message: String) {}
}
