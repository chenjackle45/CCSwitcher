import XCTest
import CryptoKit

/// Continuing a transcript from where the last pass stopped must give exactly
/// what reading it from the start gives — and must actually continue, rather
/// than quietly falling back to a full parse every time (which would pass
/// every equality check here while undoing the whole point).
final class SessionFileParserTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionFileParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func assistant(_ ts: String, msg: String?, req: String?, output: Int,
                           edit: (old: String, new: String)? = nil) -> String {
        var message: [String: Any] = [
            "model": "claude-opus-4-6",
            "usage": ["input_tokens": 100, "output_tokens": output,
                      "cache_creation_input_tokens": 10, "cache_read_input_tokens": 20],
        ]
        if let msg { message["id"] = msg }
        if let edit {
            message["content"] = [["type": "tool_use", "name": "Edit",
                                   "input": ["old_string": edit.old, "new_string": edit.new]]]
        }
        var row: [String: Any] = ["type": "assistant", "timestamp": ts, "sessionId": "s1", "message": message]
        if let req { row["requestId"] = req }
        return json(row)
    }

    private func user(_ ts: String, _ text: String) -> String {
        json(["type": "user", "timestamp": ts, "message": ["content": text]])
    }

    /// Rows chosen to exercise every piece of state that carries across passes:
    /// a message rewritten with more, less and equal output; nil-hash rows;
    /// a requestId seen twice; several days; timestamps out of order; gaps
    /// either side of the 10-minute active-time boundary; plus CRLF, blank
    /// lines, a row that is not JSON and one the schema rejects.
    private func corpus() -> Data {
        let rows: [String] = [
            user("2026-09-01T10:00:00.000Z", "hello — 你好"),
            assistant("2026-09-01T10:00:05.000Z", msg: "m1", req: "r1", output: 5),
            assistant("2026-09-01T10:00:06.000Z", msg: "m1", req: "r1", output: 50),   // same hash, more output
            assistant("2026-09-01T10:00:07.000Z", msg: "m1", req: "r1", output: 20),   // same hash, less
            assistant("2026-09-01T10:00:08.000Z", msg: "m1", req: "r1", output: 50),   // same hash, equal
            assistant("2026-09-01T10:05:00.000Z", msg: nil, req: "r2", output: 7),     // nil hash
            assistant("2026-09-01T10:05:01.000Z", msg: nil, req: "r2", output: 7),     // nil hash again, kept
            "",
            assistant("2026-09-01T10:09:00.000Z", msg: "m3", req: "r3", output: 9, edit: ("a", "a\nb\nc")),
            assistant("2026-09-01T10:30:00.000Z", msg: "m4", req: "r4", output: 11),   // > 10 min gap
            "not json at all",
            #"{"type":"assistant","timestamp":"yesterday","message":{}}"#,             // rejected by schema
            assistant("2026-09-01T09:59:00.000Z", msg: "m5", req: "r5", output: 3),    // out of order
            user("2026-09-03T08:00:00.000Z", "a later day"),
            assistant("2026-09-03T08:00:30.000Z", msg: "m6", req: "r6", output: 13),
        ]
        var text = ""
        for (i, row) in rows.enumerated() {
            text += row + (i % 4 == 3 ? "\r\n" : "\n")
        }
        return Data(text.utf8)
    }

    private func write(_ data: Data, to name: String) -> String {
        let url = dir.appendingPathComponent(name)
        try! data.write(to: url)
        return url.path
    }

    private func append(_ data: Data, to path: String) {
        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(data)
        try! handle.close()
    }

    private func encoded(_ file: CachedFileV2) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(file)
    }

    /// A from-scratch parse of whatever is in `path` now, as the reference.
    private func fullParse(_ path: String, mtime: Double = 1) -> FileParseOutcome {
        parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: mtime, previous: nil)!
    }

    private func committedEnd(_ bytes: Data) -> Int {
        bytes.lastIndex(of: 0x0A).map { $0 - bytes.startIndex + 1 } ?? 0
    }

    private func nonEmptyLines(_ bytes: Data) -> Int {
        bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            .dropLast()   // what follows the last LF is not a complete line
            .filter { !$0.isEmpty }
            .count
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Continuing equals starting over

    /// The main property, checked after every append rather than only at the
    /// end: an intermediate pass that double-counts and a later one that
    /// happens to cancel it out would pass an end-only comparison.
    func testContinuingMatchesFullParseAfterEveryAppend() {
        let bytes = corpus()
        var rng = SplitMix64(state: 42)
        var cuts = Set((0..<14).map { _ in Int.random(in: 1..<bytes.count, using: &rng) })
        // Make sure the awkward places are among the cuts.
        let multibyte = bytes.firstIndex(where: { $0 >= 0xC0 })!           // inside "—"
        let cr = bytes.firstIndex(of: 0x0D)!                                // between CR and LF
        cuts.formUnion([multibyte + 1, cr + 1, bytes.count])
        let path = write(Data(), to: "live.jsonl")

        var state: IncrementalParseState?
        var written = 0
        var previousEnd = 0
        for (i, cut) in cuts.sorted().enumerated() {
            append(bytes[written..<cut], to: path)
            written = cut
            let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: Double(i),
                                     previous: state, chunkSize: 5)!
            let reference = fullParse(path, mtime: Double(i))

            XCTAssertEqual(encoded(out.file), encoded(reference.file), "diverged after appending up to byte \(cut)")
            if state != nil {
                XCTAssertEqual(out.mode, .incremental, "fell back to a full parse at byte \(cut)")
                XCTAssertFalse(out.invalidated)
            }
            let end = committedEnd(bytes[0..<written])
            XCTAssertEqual(out.state.offset, UInt64(end))
            XCTAssertEqual(out.state.prefixDigest, SHA256.hash(data: bytes[0..<end]))
            XCTAssertEqual(out.linesConsumed, nonEmptyLines(bytes[previousEnd..<end]),
                           "consumed something other than the newly finished lines at byte \(cut)")
            state = out.state
            previousEnd = end
        }
    }

    func testChunkSizeDoesNotChangeTheResult() {
        let path = write(corpus(), to: "c.jsonl")
        let reference = fullParse(path)
        for size in [1, 2, 7, 64, 4096] {
            let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 1, previous: nil, chunkSize: size)!
            XCTAssertEqual(encoded(out.file), encoded(reference.file), "chunk size \(size)")
            XCTAssertEqual(out.state.offset, reference.state.offset)
        }
    }

    func testLineLongerThanSeveralChunks() {
        let long = assistant("2026-09-01T10:00:00.000Z", msg: "big", req: "rb", output: 1,
                             edit: ("x", String(repeating: "y\n", count: 500)))
        let path = write(Data((long + "\n").utf8), to: "long.jsonl")
        let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 1, previous: nil, chunkSize: 16)!
        XCTAssertEqual(out.file.entries.count, 1)
        XCTAssertEqual(out.linesConsumed, 1)
        XCTAssertEqual(encoded(out.file), encoded(fullParse(path).file))
    }

    func testFinalizeIsRepeatableAndLeavesLaterPassesIntact() {
        let bytes = corpus()
        let half = committedEnd(bytes[0..<(bytes.count / 2)])
        let path = write(bytes[0..<half], to: "f.jsonl")
        let first = fullParse(path)
        XCTAssertEqual(encoded(first.state.parser.finalize(mtime: 1)), encoded(first.state.parser.finalize(mtime: 1)))

        append(bytes[half...], to: path)
        let second = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 1, previous: first.state)!
        XCTAssertEqual(second.mode, .incremental)
        XCTAssertEqual(encoded(second.file), encoded(fullParse(path).file))
    }

    // MARK: - When the consumed bytes change

    /// What Claude Code does after a streaming error (`performRemoveByUuid`):
    /// truncate at the start of the failed message's line, write what followed
    /// back, same inode. Here the removed line is one the last pass already
    /// consumed, and the file then grows past the old offset again — so the
    /// size check alone would wave it through.
    func testRemovingAConsumedLineForcesAFullParse() throws {
        let rows = (0..<6).map { assistant("2026-09-01T10:0\($0):00.000Z", msg: "m\($0)", req: "r\($0)", output: $0 + 1) }
        let path = write(Data((rows.joined(separator: "\n") + "\n").utf8), to: "t.jsonl")
        let first = fullParse(path)

        // Remove row 4 in place, as the CLI does.
        let lineStart = rows[0..<4].map { $0.utf8.count + 1 }.reduce(0, +)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let rest = original[(lineStart + rows[4].utf8.count + 1)...]
        let handle = FileHandle(forUpdatingAtPath: path)!
        try handle.truncate(atOffset: UInt64(lineStart))
        try handle.seek(toOffset: UInt64(lineStart))
        handle.write(rest)
        try handle.close()
        // Grow past the old offset.
        append(Data((rows[4].replacingOccurrences(of: "m4", with: "m9") + "\n" + rows[5] + "\n").utf8), to: path)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: path)[.size] as! UInt64, first.state.offset)

        let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 2, previous: first.state)!
        XCTAssertTrue(out.invalidated)
        XCTAssertEqual(out.mode, .full)
        XCTAssertEqual(encoded(out.file), encoded(fullParse(path, mtime: 2).file))
    }

    /// Same length, one early byte different: nothing about the size gives it away.
    func testRewritingAnEarlierByteForcesAFullParse() throws {
        let path = write(corpus(), to: "t.jsonl")
        let first = fullParse(path)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let i = bytes.firstIndex(of: UInt8(ascii: "5"))!   // a digit in an early row's timestamp
        bytes[i] = UInt8(ascii: "6")
        try bytes.write(to: URL(fileURLWithPath: path))

        let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 2, previous: first.state)!
        XCTAssertTrue(out.invalidated)
        XCTAssertEqual(out.mode, .full)
        XCTAssertEqual(encoded(out.file), encoded(fullParse(path, mtime: 2).file))
    }

    func testShrinkingBelowTheOffsetForcesAFullParse() throws {
        let bytes = corpus()
        let path = write(bytes, to: "t.jsonl")
        let first = fullParse(path)
        try bytes[0..<committedEnd(bytes[0..<(bytes.count / 3)])].write(to: URL(fileURLWithPath: path))

        let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 2, previous: first.state)!
        XCTAssertTrue(out.invalidated)
        XCTAssertEqual(out.mode, .full)
        XCTAssertEqual(encoded(out.file), encoded(fullParse(path, mtime: 2).file))
    }

    // MARK: - When they do not

    /// A line caught mid-write is neither counted nor hashed; when it is
    /// finished — even if the unfinished part changed in between — the next
    /// pass continues rather than rebuilding, and counts it exactly once.
    func testUnfinishedLineIsCountedOnceWhenFinished() {
        let done = assistant("2026-09-01T10:00:00.000Z", msg: "m1", req: "r1", output: 5) + "\n"
        let next = assistant("2026-09-01T10:01:00.000Z", msg: "m2", req: "r2", output: 6)
        let path = write(Data((done + String(next.prefix(20))).utf8), to: "t.jsonl")

        let first = fullParse(path)
        XCTAssertEqual(first.file.entries.count, 1)
        XCTAssertEqual(first.state.offset, UInt64(done.utf8.count))

        // The tail is rewritten before being finished; only uncommitted bytes change.
        let handle = FileHandle(forUpdatingAtPath: path)!
        try! handle.truncate(atOffset: UInt64(done.utf8.count))
        try! handle.close()
        append(Data((next + "\n").utf8), to: path)

        let second = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 2, previous: first.state)!
        XCTAssertEqual(second.mode, .incremental)
        XCTAssertFalse(second.invalidated)
        XCTAssertEqual(second.linesConsumed, 1)
        XCTAssertEqual(second.file.entries.count, 2)
    }

    /// The documented limit: a row that is complete, valid JSON but has no LF
    /// yet is still not counted. A nil-hash row, so that counting it early and
    /// again once the LF lands would show up as two entries rather than being
    /// absorbed by dedup.
    func testCompleteRowWithoutLFIsNotCountedUntilTerminated() {
        let done = assistant("2026-09-01T10:00:00.000Z", msg: "m1", req: "r1", output: 5) + "\n"
        let pendingRow = assistant("2026-09-01T10:01:00.000Z", msg: nil, req: nil, output: 6)
        let path = write(Data((done + pendingRow).utf8), to: "t.jsonl")

        let first = fullParse(path)
        XCTAssertEqual(first.file.entries.count, 1, "a row with no LF was counted")

        append(Data("\n".utf8), to: path)
        let second = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 2, previous: first.state)!
        XCTAssertEqual(second.mode, .incremental)
        XCTAssertEqual(second.file.entries.count, 2, "the row should be counted exactly once")
    }

    func testTouchWithoutNewBytesContinuesAndConsumesNothing() {
        let path = write(corpus(), to: "t.jsonl")
        let first = fullParse(path)
        let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 2, previous: first.state)!
        XCTAssertEqual(out.mode, .incremental)
        XCTAssertEqual(out.linesConsumed, 0)
        XCTAssertEqual(encoded(out.file), encoded(fullParse(path, mtime: 2).file))
    }

    /// A different inode holding the same bytes is the same prefix; carrying on is correct.
    func testReplacedFileWithTheSamePrefixContinues() throws {
        let bytes = corpus()
        let half = committedEnd(bytes[0..<(bytes.count / 2)])
        let path = write(bytes[0..<half], to: "t.jsonl")
        let first = fullParse(path)

        let replacement = write(bytes, to: "replacement.jsonl")
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: replacement))

        let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 2, previous: first.state)!
        XCTAssertEqual(out.mode, .incremental)
        XCTAssertEqual(encoded(out.file), encoded(fullParse(path, mtime: 2).file))
    }

    func testEmptyFileThenGrowth() {
        let path = write(Data(), to: "t.jsonl")
        let first = fullParse(path)
        XCTAssertEqual(first.state.offset, 0)
        XCTAssertEqual(first.file.entries.count, 0)

        append(corpus(), to: path)
        let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 2, previous: first.state)!
        XCTAssertEqual(out.mode, .incremental)
        XCTAssertEqual(encoded(out.file), encoded(fullParse(path, mtime: 2).file))
    }

    // MARK: - Line splitting

    /// U+2028 inside a JSON string is legal JSON. The old `enumerateLines`
    /// split the row there and lost it; only LF ends a line now.
    func testUnicodeLineSeparatorInsideARowDoesNotSplitIt() {
        let row = assistant("2026-09-01T10:00:00.000Z", msg: "m1", req: "r1", output: 5, edit: ("a", "b\u{2028}c"))
        XCTAssertTrue(row.contains("\u{2028}"), "fixture must carry the raw separator")
        let path = write(Data((row + "\n").utf8), to: "t.jsonl")
        XCTAssertEqual(fullParse(path).file.entries.count, 1)
    }

    func testCRLFAndLFGiveTheSameResult() {
        let rows = (0..<4).map { assistant("2026-09-01T10:0\($0):00.000Z", msg: "m\($0)", req: "r\($0)", output: 1) }
        let lf = write(Data((rows.joined(separator: "\n") + "\n").utf8), to: "lf.jsonl")
        let crlf = write(Data((rows.joined(separator: "\r\n") + "\r\n").utf8), to: "crlf.jsonl")
        XCTAssertEqual(encoded(fullParse(lf).file), encoded(fullParse(crlf).file))
        XCTAssertEqual(fullParse(crlf).file.entries.count, 4)
    }

    /// An unreadable file gives nothing back — with or without a previous
    /// state — rather than falling through to a from-scratch parse that would
    /// hand the caller an empty result to file over the real one.
    ///
    /// Only the open failure is covered. A read that fails part-way is NOT:
    /// it would need a failing reader injected into production code just for
    /// this, and a race-based attempt is flaky evidence rather than a test.
    /// That case rests on the shape instead — state is a value, the function
    /// either returns a finished result or nil, and the caller commits only a
    /// result — which is an argument, not a regression test.
    func testOpeningAnUnreadableFileCommitsNothing() {
        let path = write(corpus(), to: "t.jsonl")
        let previous = fullParse(path).state
        let missing = dir.appendingPathComponent("missing.jsonl").path
        XCTAssertNil(parseJSONLFile(at: missing, relativePath: "proj/t.jsonl", mtime: 1, previous: nil))
        XCTAssertNil(parseJSONLFile(at: missing, relativePath: "proj/t.jsonl", mtime: 2, previous: previous))
    }

    // MARK: - Fixed boundaries across passes
    //
    // The randomised test above cuts in arbitrary places; these put the cut
    // exactly between the rows whose relationship carries across passes.

    private func passes(_ rowsPerPass: [[String]], check: (Int, FileParseOutcome) -> Void) {
        let path = write(Data(), to: "passes.jsonl")
        var state: IncrementalParseState?
        for (i, rows) in rowsPerPass.enumerated() {
            append(Data(rows.map { $0 + "\n" }.joined().utf8), to: path)
            let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: Double(i), previous: state)!
            if state != nil { XCTAssertEqual(out.mode, .incremental, "pass \(i)") }
            XCTAssertEqual(encoded(out.file), encoded(fullParse(path, mtime: Double(i)).file), "pass \(i)")
            check(i, out)
            state = out.state
        }
    }

    /// The later copies of the message carry a tool call the winning copy does
    /// not, so "kept the earlier one" is observable rather than inferred: on
    /// output alone the equal-output pass is indistinguishable from a replace,
    /// since nothing else about those rows reaches the entry.
    func testRewrittenMessageKeepsTheLargestOutputAcrossPasses() {
        let outputs = [5, 50, 20, 50]           // more, then less, then equal
        let expected = [5, 50, 50, 50]
        let edited = [false, false, true, true] // only the copies that must lose
        passes((0..<4).map { i in
            [assistant("2026-09-01T12:00:0\(i).000Z", msg: "m1", req: "r1", output: outputs[i],
                       edit: edited[i] ? ("a", "a\nb\nc") : nil)]
        }) { i, out in
            XCTAssertEqual(out.file.entries.count, 1)
            XCTAssertEqual(out.file.entries.first?.output, expected[i], "pass \(i)")
            XCTAssertEqual(out.file.entries.first?.tools.isEmpty, true,
                           "pass \(i): a losing copy replaced the winner")
            XCTAssertEqual(out.file.entries.first?.linesWritten, 0, "pass \(i)")
        }
    }

    /// Exactly 600 s apart is one stretch of activity, 601 s is two — with
    /// each row arriving in its own pass.
    func testActiveMinutesAtTheTenMinuteBoundaryAcrossPasses() {
        passes([
            [assistant("2026-09-01T12:00:00.000Z", msg: "m1", req: "r1", output: 1)],
            [assistant("2026-09-01T12:10:00.000Z", msg: "m2", req: "r2", output: 1)],   // +600 s
            [assistant("2026-09-01T12:20:01.000Z", msg: "m3", req: "r3", output: 1)],   // +601 s
        ]) { i, out in
            let minutes = out.file.activityByDate.values.map(\.activeMinutes).reduce(0, +)
            XCTAssertEqual(minutes, [2, 12, 14][i], "pass \(i)")   // (600 + 120) s, then + 120 s
        }
    }

    /// Model usage is deduped by requestId across the whole file, not per
    /// day, and that has to survive the second day arriving in a later pass.
    func testRequestIdSeenOnAnEarlierDayIsNotCountedAgain() {
        passes([
            [assistant("2026-09-01T12:00:00.000Z", msg: "m1", req: "r1", output: 1)],
            [assistant("2026-09-03T12:00:00.000Z", msg: "m2", req: "r1", output: 1)],
        ]) { i, out in
            let opus = out.file.activityByDate.values.map { $0.modelCounts["Opus"] ?? 0 }.reduce(0, +)
            XCTAssertEqual(opus, 1, "pass \(i)")
            XCTAssertEqual(out.file.entries.count, i + 1, "different message ids are separate cost entries")
        }
    }

    /// A file whose state was dropped to make room is parsed from the start
    /// next time, through the same store the cache actor uses.
    ///
    /// Small fixed rows, and the expected answer written out here: comparing
    /// against another from-scratch parse of the same path would run the same
    /// code twice and agree even when both are wrong.
    func testFileWhoseStateWasDroppedIsParsedFromTheStart() {
        let opening = [assistant("2026-09-01T12:00:00.000Z", msg: "m1", req: "r1", output: 5),
                       assistant("2026-09-01T12:00:10.000Z", msg: "m2", req: "r2", output: 7)]
        let path = write(Data(opening.map { $0 + "\n" }.joined().utf8), to: "t.jsonl")

        var store = IncrementalStateStore(capacity: 1)
        store.put(fullParse(path, mtime: 1).state, for: path)
        store.put(state(mtime: 2), for: "a-newer-file")
        XCTAssertNil(store[path], "the older file is the one that loses its slot")

        let later = assistant("2026-09-01T12:00:20.000Z", msg: "m3", req: "r3", output: 11)
        append(Data((later + "\n").utf8), to: path)
        let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 3, previous: store[path])!

        XCTAssertEqual(out.mode, .full)
        XCTAssertFalse(out.invalidated, "nothing was offered, so nothing was rejected")
        XCTAssertEqual(out.linesConsumed, 3, "all three rows, not only the appended one")
        XCTAssertEqual(out.file.entries.map(\.output).sorted(), [5, 7, 11])
        XCTAssertEqual(out.file.entries.map(\.input).reduce(0, +), 300)
        XCTAssertEqual(out.file.activityByDate.keys.sorted(), ["2026-09-01"])
        XCTAssertEqual(out.file.activityByDate["2026-09-01"]?.modelCounts, ["Opus": 3])
    }

    // MARK: - Memory

    /// nil when the kernel will not say — which must fail the test rather
    /// than read as zero growth.
    private func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Reading must not hold on to what it has read. Without a pool per
    /// chunk, every chunk buffer and every object the JSON parser makes stays
    /// alive until the call returns — 23 GB on a cold parse of 9.3 GB of real
    /// transcripts, and the whole prefix again on every pass that only checks
    /// it. Rows here are large and few, so the result itself stays small.
    ///
    /// Measured on this 32 MB fixture: with the pools a full parse adds about
    /// 36 MB — the working set of one chunk's JSON objects, which does not grow
    /// with the file (721 MB of real transcripts peaked at 62 MB) — and prefix
    /// checks add nothing; without them, +268 MB and +93 MB.
    func testMemoryDoesNotGrowWithTheBytesRead() throws {
        let payload = String(repeating: "line of edited text\n", count: 800)   // ~16 KB per row
        var text = ""
        for i in 0..<2_000 {
            text += assistant("2026-09-01T10:00:00.000Z", msg: "m\(i)", req: "r\(i)", output: 1,
                              edit: ("x", payload)) + "\n"
        }
        let path = write(Data(text.utf8), to: "big.jsonl")
        text = ""
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as! UInt64
        XCTAssertGreaterThan(size, 30 << 20, "fixture should be large enough to show the growth")

        let start = try XCTUnwrap(footprintBytes())
        var state = fullParse(path).state
        let afterFull = try XCTUnwrap(footprintBytes())
        for _ in 0..<3 {   // passes that only re-check the prefix
            let out = parseJSONLFile(at: path, relativePath: "proj/t.jsonl", mtime: 1, previous: state)!
            XCTAssertEqual(out.mode, .incremental)
            state = out.state
        }
        let afterChecks = try XCTUnwrap(footprintBytes())
        let fullGrowth = afterFull > start ? afterFull - start : 0
        let checkGrowth = afterChecks > afterFull ? afterChecks - afterFull : 0
        XCTAssertLessThan(fullGrowth, size * 2, "a full parse grew memory by \(fullGrowth >> 20) MB for a \(size >> 20) MB file")
        XCTAssertLessThan(checkGrowth, size / 4, "three prefix checks grew memory by \(checkGrowth >> 20) MB")
    }

    // MARK: - Keeping states

    private func state(mtime: Double) -> IncrementalParseState {
        IncrementalParseState(offset: 0, prefixDigest: SHA256.hash(data: Data()),
                              parser: FileParser(relativePath: "proj/t.jsonl"), mtime: mtime)
    }

    func testStoreDropsTheLeastRecentlyModifiedBeyondCapacity() {
        var store = IncrementalStateStore(capacity: 32)
        for i in 0..<32 { store.put(state(mtime: Double(100 + i)), for: "f\(i)") }
        XCTAssertEqual(store.count, 32)

        store.put(state(mtime: 500), for: "f32")
        XCTAssertEqual(store.count, 32)
        XCTAssertNil(store["f0"], "the oldest mtime should have gone")
        XCTAssertNotNil(store["f32"])

        // An old file arriving last is itself the one dropped.
        store.put(state(mtime: 1), for: "ancient")
        XCTAssertNil(store["ancient"])
        XCTAssertEqual(store.count, 32)

        store.remove("f32")
        XCTAssertNil(store["f32"])
        XCTAssertEqual(store.count, 31)
    }
}
