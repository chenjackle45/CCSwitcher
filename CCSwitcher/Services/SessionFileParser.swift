import Foundation
import CryptoKit

// MARK: - V2 Cache Models
//
// v2 differs from v1 in three structural ways:
//
//   1. We store deduped *entries* per file (not just pre-aggregated day
//      buckets) so we can dedup globally at query time. v1 baked the dedup
//      into per-file aggregates, which made global dedup across resume/fork
//      duplicates impossible to add later.
//
//   2. Each entry carries enough metadata (date, hour, model, speed, hash,
//      4 token types, tools, lines) that future per-project / per-hour /
//      per-sidechain slices need no schema change. File-level metadata
//      (project, sessionId, isSidechain) is hoisted to avoid per-entry
//      redundancy.
//
//   3. The pricing data the entries are valued against is tracked in the
//      envelope so divergent answers between users can be traced to the
//      specific snapshot in play.

/// One assistant row after per-file `(message.id, requestId)` dedup.
/// Multiple of these may share a `hash`, but only across files; at query
/// time they get deduped globally max-output-wins (matches ccusage 20.x).
struct CachedEntryV2: Codable, Sendable {
    /// "messageId:requestId", or nil if either id was missing.
    /// nil-hash entries are NEVER deduped — every occurrence is kept.
    let hash: String?
    let date: String        // local "yyyy-MM-dd"
    let hour: Int           // local 0–23
    let model: String       // raw model id from JSONL, including dated suffixes
    let speed: String?      // nil / "standard" / "fast"
    let input: Int
    let output: Int
    let cw: Int             // cache_creation_input_tokens (total)
    let cw1h: Int           // cache_creation.ephemeral_1h_input_tokens (1-hour TTL portion)
    let cr: Int             // cache_read_input_tokens
    let costUSDRow: Double? // value of `costUSD` if present in the JSONL row
    let tools: [String: Int]
    let linesWritten: Int
}

/// One JSONL file's parse result.
///
/// Cost data lives in `entries` (subject to global dedup).
/// Activity data lives in `activityByDate` as already-summed per-day
/// totals — activity counts (turns, active-minutes, tool counts, lines)
/// don't have the cross-file resume-duplicate problem cost has, so
/// per-file aggregation is correct and cheap.
struct CachedFileV2: Codable, Sendable {
    let mtimeUnix: Double               // bit-equal-comparable with FS mtime
    let earliestTimestampUnix: Double   // for cross-file sort order; .greatestFiniteMagnitude = "no timestamp, sorts last" (must stay finite — see save())
    let project: String                 // dir name under ~/.claude/projects/
    let sessionId: String?              // from the file's first row, if present
    let isSidechain: Bool               // true if path contains /subagents/
    let entries: [CachedEntryV2]
    let activityByDate: [String: ActivityDayContributionV2]
}

struct ActivityDayContributionV2: Codable, Sendable {
    let turns: Int
    let activeMinutes: Int
    let toolCounts: [String: Int]
    let linesWritten: Int
    let modelCounts: [String: Int]  // short name (Opus/Sonnet/Haiku)
}

/// "claude-opus-4-6" → "Opus", "claude-fable-5" → "Fable"
///
/// Lives here rather than on `CostParser` so the parser below does not drag
/// the cost facade — and through it the cache actor and pricing service —
/// into everything that compiles this file.
func modelFamilyName(_ model: String) -> String {
    if model.contains("fable") { return "Fable" }
    if model.contains("opus") { return "Opus" }
    if model.contains("sonnet") { return "Sonnet" }
    if model.contains("haiku") { return "Haiku" }
    return model
}

// MARK: - Per-file parser
//
// Accumulates one JSONL file line by line and produces (a) deduped per-file
// cost entries and (b) per-date activity contributions. Holding the state in
// a value, rather than in locals of one read-everything function, is what
// lets a file that only grew be continued from where the last pass stopped.

struct FileParser {
    // File-level metadata (project, sessionId, isSidechain) is determined
    // by path shape; we infer it without scanning the JSON.
    let project: String
    let isSidechain: Bool
    private var sessionId: String?
    private var earliest: Date?

    // Per-file cost dedup state.
    private var perFileBest: [String: Int] = [:]   // hash -> index of current max-output winner in costEntries
    private var costEntries: [CachedEntryV2] = []

    // Per-date activity bookkeeping.
    private var perDayTurns: [String: Int] = [:]
    private var perDayTools: [String: [String: Int]] = [:]
    private var perDayModels: [String: [String: Int]] = [:]
    private var perDayLines: [String: Int] = [:]
    private var perDayTimestamps: [String: [Date]] = [:]
    private var perDayActivityRequestSeen: Set<String> = []

    // Built once per file rather than once per line.
    private let isoMain: ISO8601DateFormatter
    private let isoAlt: ISO8601DateFormatter
    private let dateFmt: DateFormatter
    private let hourFmt: DateFormatter

    // Strict schema regexes — originally lifted from ccusage 18.0.11's JS parser;
    // the row-acceptance schema is unchanged in 20.x (token columns still reconcile).
    // Bare patterns; ranges checked with `.regularExpression`.
    private static let timestampPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$"#
    private static let versionPattern   = #"^\d+\.\d+\.\d+"#

    init(relativePath: String) {
        let parts = relativePath.split(separator: "/")
        project = parts.first.map(String.init) ?? "unknown"
        isSidechain = relativePath.contains("/subagents/")

        isoMain = ISO8601DateFormatter()
        isoMain.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoAlt = ISO8601DateFormatter()
        isoAlt.formatOptions = [.withInternetDateTime]

        dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        hourFmt = DateFormatter()
        hourFmt.dateFormat = "H"
        hourFmt.locale = Locale(identifier: "en_US_POSIX")
    }

    /// Feeds one line — without its terminating LF or CR — into the running totals.
    mutating func consume(line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }

        guard let timestampStr = obj["timestamp"] as? String,
              timestampStr.range(of: Self.timestampPattern, options: .regularExpression) != nil,
              let timestamp = isoMain.date(from: timestampStr) ?? isoAlt.date(from: timestampStr)
        else { return }

        // `version`: if present, must match `^\d+\.\d+\.\d+`. Stale Claude
        // Code writes occasionally produce non-version strings here.
        if let v = obj["version"] {
            guard let vs = v as? String,
                  vs.range(of: Self.versionPattern, options: .regularExpression) != nil else { return }
        }

        if earliest == nil || timestamp < earliest! { earliest = timestamp }
        if sessionId == nil, let s = obj["sessionId"] as? String, !s.isEmpty { sessionId = s }

        let dateStr = dateFmt.string(from: timestamp)
        let hour = Int(hourFmt.string(from: timestamp)) ?? 0
        let type = obj["type"] as? String ?? ""

        perDayTimestamps[dateStr, default: []].append(timestamp)

        switch type {
        case "user":
            let message = obj["message"] as? [String: Any]
            let rawContent = message?["content"]
            if let s = rawContent as? String, !s.isEmpty {
                perDayTurns[dateStr, default: 0] += 1
            } else if let arr = rawContent as? [[String: Any]] {
                let hasToolResult = arr.contains { $0["type"] as? String == "tool_result" }
                if !hasToolResult { perDayTurns[dateStr, default: 0] += 1 }
            }

        case "assistant":
            guard let message = obj["message"] as? [String: Any] else { return }

            // === Cost entry path (ccusage parity) ===
            // Match ccusage: any row with numeric input/output_tokens
            // gets its own entry. Schema is loose; rows with `<synthetic>` model
            // contribute zero-token entries, which is intentional — they're filtered
            // out from cost breakdowns at presentation time.
            if let usage = message["usage"] as? [String: Any],
               let input = usage["input_tokens"] as? Int,
               let output = usage["output_tokens"] as? Int {
                let cw = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                // 1-hour-TTL portion of the cache write (billed higher than 5m).
                let cw1h = ((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int) ?? 0
                let cr = (usage["cache_read_input_tokens"] as? Int) ?? 0
                // `speed`: ccusage rejects values other than nil/"standard"/"fast".
                let rawSpeed = usage["speed"]
                let speed: String?
                if rawSpeed is NSNull || rawSpeed == nil {
                    speed = nil
                } else if let s = rawSpeed as? String, s == "standard" || s == "fast" {
                    speed = s
                } else {
                    return  // unsupported value -> reject row (matches reference)
                }
                // Non-empty-string requirements for id-like fields. An empty
                // string would collapse hash buckets like `":req_xxx"` → false dedup.
                let modelRaw = (message["model"] as? String) ?? ""
                guard !modelRaw.isEmpty else { return }
                let model = modelRaw

                let messageId: String? = {
                    guard let s = message["id"] as? String, !s.isEmpty else { return nil }
                    return s
                }()
                let requestId: String? = {
                    guard let s = obj["requestId"] as? String, !s.isEmpty else { return nil }
                    return s
                }()
                let costUSD = obj["costUSD"] as? Double
                let hash: String? = {
                    if let m = messageId, let r = requestId { return "\(m):\(r)" }
                    return nil
                }()

                // Tool counts + linesWritten for THIS row, attached at entry
                // level so we can slice cost-by-tool later if needed.
                var rowTools: [String: Int] = [:]
                var rowLines = 0
                if let arr = message["content"] as? [[String: Any]] {
                    for block in arr where (block["type"] as? String) == "tool_use" {
                        guard let toolName = block["name"] as? String else { continue }
                        rowTools[toolName, default: 0] += 1
                        if let input = block["input"] as? [String: Any] {
                            rowLines += estimateLines(tool: toolName, input: input)
                        }
                    }
                }
                let entry = CachedEntryV2(
                    hash: hash,
                    date: dateStr,
                    hour: hour,
                    model: model,
                    speed: speed,
                    input: input, output: output, cw: cw, cw1h: cw1h, cr: cr,
                    costUSDRow: costUSD,
                    tools: rowTools,
                    linesWritten: rowLines
                )
                // Per-file max-output-wins dedup. A message written more than once
                // (partial stream snapshot + final copy) shares a hash; input/cache
                // are identical across copies, only output_tokens grows, so keep the
                // largest-output copy. Global dedup happens later in costSummary.
                // nil-hash rows are never deduped — every occurrence is kept.
                if let h = hash {
                    if let idx = perFileBest[h] {
                        if output > costEntries[idx].output { costEntries[idx] = entry }
                    } else {
                        perFileBest[h] = costEntries.count
                        costEntries.append(entry)
                    }
                } else {
                    costEntries.append(entry)
                }
            }

            // === Activity-data path (file-level aggregation) ===
            // Matches v1 semantics: model usage deduped by requestId within file,
            // tool counts and linesWritten summed across all assistant rows
            // (not just deduped winners).
            if let model = message["model"] as? String,
               let requestId = obj["requestId"] as? String,
               !perDayActivityRequestSeen.contains(requestId) {
                perDayActivityRequestSeen.insert(requestId)
                let short = modelFamilyName(model)
                perDayModels[dateStr, default: [:]][short, default: 0] += 1
            }
            if let arr = message["content"] as? [[String: Any]] {
                for block in arr where (block["type"] as? String) == "tool_use" {
                    guard let toolName = block["name"] as? String else { continue }
                    perDayTools[dateStr, default: [:]][toolName, default: 0] += 1
                    if let input = block["input"] as? [String: Any] {
                        perDayLines[dateStr, default: 0] += estimateLines(tool: toolName, input: input)
                    }
                }
            }

        default: break
        }
    }

    /// The file's result as of the lines consumed so far. Reads the running
    /// totals without changing them, so it can be called after every pass.
    func finalize(mtime: Double) -> CachedFileV2 {
        // Reduce activity per-day.
        var activityOut: [String: ActivityDayContributionV2] = [:]
        let allDates = Set(perDayTurns.keys)
            .union(perDayTools.keys)
            .union(perDayModels.keys)
            .union(perDayLines.keys)
            .union(perDayTimestamps.keys)
        for date in allDates {
            let active = calculateActiveMinutes(perDayTimestamps[date] ?? [])
            let c = ActivityDayContributionV2(
                turns: perDayTurns[date] ?? 0,
                activeMinutes: active,
                toolCounts: perDayTools[date] ?? [:],
                linesWritten: perDayLines[date] ?? 0,
                modelCounts: perDayModels[date] ?? [:]
            )
            if c.turns > 0 || c.activeMinutes > 0 || !c.toolCounts.isEmpty
                || c.linesWritten > 0 || !c.modelCounts.isEmpty {
                activityOut[date] = c
            }
        }

        return CachedFileV2(
            mtimeUnix: mtime,
            // Must stay FINITE: JSONEncoder rejects non-finite floats by default, so a
            // single timestamp-less file with .infinity here made save() throw and the
            // whole cache silently never persisted (forcing a full re-parse every
            // cycle). .greatestFiniteMagnitude still sorts after every real timestamp.
            earliestTimestampUnix: earliest?.timeIntervalSince1970 ?? .greatestFiniteMagnitude,
            project: project,
            sessionId: sessionId,
            isSidechain: isSidechain,
            entries: costEntries,
            activityByDate: activityOut
        )
    }
}

// MARK: - Continuing a file across passes
//
// Claude Code transcripts are append-only in practice (a 29-minute probe of
// 26 live files saw 405 changes, every one of them leaving the earlier bytes
// untouched) — but not by contract: after a streaming error Claude Code
// removes the failed message by truncating the file at that line and writing
// the rest back, same inode. So continuing from where the last pass stopped
// is only safe once the bytes already consumed are shown to be unchanged.
// That is checked by hashing them again, every time: it covers that removal
// path and any other rewrite without having to know what they look like, and
// hashing is cheap next to parsing (a measured 287 MB of live transcripts in
// about 0.25 s, against about 14 s to parse them).

/// Where the last pass over one file stopped, and what it had accumulated.
struct IncrementalParseState {
    /// Every byte before this position has been consumed. It always sits
    /// just after a LF: a trailing line with no LF yet is left for a later pass.
    let offset: UInt64
    /// SHA-256 of bytes `[0, offset)` exactly as they were on disk — CRs,
    /// blank lines, and lines the parser rejected included.
    let prefixDigest: SHA256.Digest
    let parser: FileParser
    /// The file's mtime when this state was produced. Used to decide which
    /// states to keep; the file most recently written is the one most likely
    /// to be written again.
    let mtime: Double
}

struct FileParseOutcome {
    enum Mode { case full, incremental }

    let file: CachedFileV2
    let state: IncrementalParseState
    let mode: Mode
    /// A previous state was offered but could not be used: the file had
    /// shrunk below it, or the bytes it had already consumed had changed.
    let invalidated: Bool
    let bytesRead: Int
    /// Non-empty complete lines handed to the parser this pass.
    let linesConsumed: Int
}

/// Parses `path`, continuing from `previous` when the bytes it covers are
/// still on disk unchanged, and starting over from the beginning otherwise.
///
/// Only lines terminated by a LF are consumed. A complete JSON row that is
/// never followed by a LF is therefore never counted — no transcript on the
/// machines this was measured on ends that way (0 of 11,811 idle files), but
/// that is an observation, not a guarantee.
///
/// Returns nil when the file cannot be read; nothing is committed in that
/// case and the caller keeps whatever it had.
func parseJSONLFile(
    at path: String,
    relativePath: String,
    mtime: Double,
    previous: IncrementalParseState?,
    chunkSize: Int = 4 << 20
) -> FileParseOutcome? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }

    do {
        var bytesRead = 0
        var invalidated = false

        if let previous {
            // Hash exactly the bytes the previous pass consumed. The handle
            // then sits at `previous.offset`, so the same read continues from
            // there with no gap between checking and reading on. A file that
            // has shrunk below `offset` runs out before `remaining` reaches 0.
            var hasher = SHA256()
            var remaining = previous.offset
            // One pool per chunk, as below: each chunk read is an autoreleased
            // buffer, and nothing drains them until the whole refresh returns.
            while remaining > 0, try autoreleasepool(invoking: { () -> Bool in
                guard let chunk = try handle.read(upToCount: Int(min(UInt64(chunkSize), remaining))),
                      !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                remaining -= UInt64(chunk.count)
                bytesRead += chunk.count
                return true
            }) {}
            if remaining == 0, hasher.finalize() == previous.prefixDigest {
                var parser = previous.parser
                let pass = try consumeCompleteLines(from: handle, startingAt: previous.offset,
                                                    parser: &parser, hasher: &hasher, chunkSize: chunkSize)
                return FileParseOutcome(
                    file: parser.finalize(mtime: mtime),
                    state: IncrementalParseState(offset: pass.offset, prefixDigest: hasher.finalize(),
                                                 parser: parser, mtime: mtime),
                    mode: .incremental,
                    invalidated: false,
                    bytesRead: bytesRead + pass.bytesRead,
                    linesConsumed: pass.lines
                )
            }
            invalidated = true
            try handle.seek(toOffset: 0)
        }

        var parser = FileParser(relativePath: relativePath)
        var hasher = SHA256()
        let pass = try consumeCompleteLines(from: handle, startingAt: 0,
                                            parser: &parser, hasher: &hasher, chunkSize: chunkSize)
        return FileParseOutcome(
            file: parser.finalize(mtime: mtime),
            state: IncrementalParseState(offset: pass.offset, prefixDigest: hasher.finalize(),
                                         parser: parser, mtime: mtime),
            mode: .full,
            invalidated: invalidated,
            bytesRead: bytesRead + pass.bytesRead,
            linesConsumed: pass.lines
        )
    } catch {
        return nil
    }
}

/// Reads from the handle's current position to the end. Each complete line
/// goes to the parser (minus its LF; blank lines skipped) and its raw bytes
/// to the hasher. A CR before the LF is left on the line: JSON treats it as
/// trailing whitespace. Whatever follows the last LF is left alone, so an
/// unfinished line is neither counted nor covered by the digest until a
/// later pass finds it finished.
private func consumeCompleteLines(
    from handle: FileHandle,
    startingAt start: UInt64,
    parser: inout FileParser,
    hasher: inout SHA256,
    chunkSize: Int
) throws -> (offset: UInt64, bytesRead: Int, lines: Int) {
    var committed = start
    var pending = Data()
    var bytesRead = 0
    var lines = 0

    // One autorelease pool per chunk. The whole refresh runs as a single
    // synchronous call, so without it every chunk buffer and every object
    // JSONSerialization creates for every line piles up until the refresh
    // returns: a cold parse of 9.3 GB of transcripts reached 23 GB. The old
    // `enumerateLines` drained a pool per line, which is why reading whole
    // files never showed this.
    while try autoreleasepool(invoking: { () -> Bool in
        guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
        bytesRead += chunk.count
        // Only the new chunk needs searching: `pending` never holds a LF.
        guard let lastLF = chunk.lastIndex(of: 0x0A) else {
            pending.append(chunk)
            return true
        }
        pending.append(chunk[chunk.startIndex...lastLF])
        hasher.update(data: pending)

        var lineStart = pending.startIndex
        while let lf = pending[lineStart...].firstIndex(of: 0x0A) {
            if lf > lineStart {
                parser.consume(line: pending[lineStart..<lf])
                lines += 1
            }
            lineStart = lf + 1
        }

        committed += UInt64(pending.count)
        pending = Data(chunk[(lastLF + 1)...])
        return true
    }) {}
    return (committed, bytesRead, lines)
}

/// Continuation states for the files most likely to change again, bounded
/// by count. When full, the state whose file was modified longest ago is
/// dropped; that file is simply parsed from the start if it changes later.
struct IncrementalStateStore {
    let capacity: Int
    private(set) var states: [String: IncrementalParseState] = [:]

    init(capacity: Int) {
        self.capacity = capacity
    }

    subscript(path: String) -> IncrementalParseState? { states[path] }

    var count: Int { states.count }

    mutating func put(_ state: IncrementalParseState, for path: String) {
        states[path] = state
        while states.count > capacity,
              let oldest = states.min(by: { $0.value.mtime < $1.value.mtime })?.key {
            states.removeValue(forKey: oldest)
        }
    }

    mutating func remove(_ path: String) {
        states.removeValue(forKey: path)
    }
}

/// Active coding minutes from a single date's timestamp set. Mirrors v1's
/// algorithm (10-min idle gap splits sessions, 2-min tail padding).
private func calculateActiveMinutes(_ timestamps: [Date]) -> Int {
    let maxGap: TimeInterval = 10 * 60
    let tailPadding: TimeInterval = 2 * 60
    guard timestamps.count >= 2 else {
        return timestamps.isEmpty ? 0 : max(1, Int(tailPadding / 60))
    }
    let sorted = timestamps.sorted()
    var total: TimeInterval = 0
    var periodStart = sorted[0]
    var periodEnd = sorted[0]
    for i in 1..<sorted.count {
        let gap = sorted[i].timeIntervalSince(periodEnd)
        if gap <= maxGap {
            periodEnd = sorted[i]
        } else {
            total += periodEnd.timeIntervalSince(periodStart) + tailPadding
            periodStart = sorted[i]
            periodEnd = sorted[i]
        }
    }
    total += periodEnd.timeIntervalSince(periodStart) + tailPadding
    return total > 0 ? max(1, Int(total / 60)) : 0
}

private func estimateLines(tool: String, input: [String: Any]) -> Int {
    switch tool {
    case "Write":
        let content = input["content"] as? String ?? ""
        return content.components(separatedBy: "\n").count
    case "Edit":
        let newStr = input["new_string"] as? String ?? ""
        let oldStr = input["old_string"] as? String ?? ""
        return max(0, newStr.components(separatedBy: "\n").count - oldStr.components(separatedBy: "\n").count)
    default:
        return 0
    }
}
