import Foundation

private let log = FileLog("CacheV2")

// The per-file models (`CachedEntryV2`, `CachedFileV2`,
// `ActivityDayContributionV2`) and the parser that produces them live in
// SessionFileParser.swift.

/// What pricing snapshot is currently driving cost output. Stamped on
/// the envelope so it's debuggable from outside the app.
struct PricingMeta: Codable, Sendable {
    let source: String          // "bundle:abc1234" or "fresh:2026-05-15T03:00Z"
    let fetchedAt: Date?
}

private struct CacheEnvelopeV2: Codable {
    let version: Int            // must equal CURRENT_VERSION
    let lastUpdated: Date
    var pricing: PricingMeta
    var files: [String: CachedFileV2]
}

// MARK: - SessionParseCacheV2 (actor)

actor SessionParseCacheV2 {
    static let shared = SessionParseCacheV2()

    // v3: cost entries gained `cw1h` (1-hour cache split) and dedup switched to
    // max-output-wins; bump forces a full re-parse so old caches don't serve
    // entries missing the new field or deduped under the old first-wins rule.
    // v4: lines are split on LF only. The old `enumerateLines` also broke on
    // CR, U+2028, U+2029 and U+0085, cutting the rows that contain them into
    // halves that failed to parse and were dropped; a file with one invalid
    // UTF-8 byte anywhere was dropped whole. Re-parse so no cache mixes the two.
    private static let currentVersion = 4
    private let claudeProjectsDir: String
    private let cacheURL: URL

    private var files: [String: CachedFileV2] = [:]
    // Where the last pass over each recently changed file stopped, so a
    // transcript that only grew is parsed from there rather than from the
    // start. Memory only: after a launch each file pays one full parse the
    // first time it changes.
    private var incremental = IncrementalStateStore(capacity: 32)
    private var pricingMeta: PricingMeta = .init(source: "unknown", fetchedAt: nil)
    private var loaded = false
    // The cache is a pure derivative of the JSONL files, so it does not need
    // to hit disk every refresh. Changes accumulate in `dirty` across refreshes
    // and are written at most once per `minSaveInterval`; the first change
    // after launch is written immediately so a fresh rebuild is not lost.
    private var dirty = false
    private var lastSuccessfulSave: Date?
    private static let minSaveInterval: TimeInterval = 15 * 60

    private init() {
        self.claudeProjectsDir = NSHomeDirectory() + "/.claude/projects"

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("CCSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("session-parse-cache-v2.json")
    }

    // MARK: Public API

    /// Walk `~/.claude/projects/**/*.jsonl`, re-parse any file whose mtime
    /// has changed, evict missing files, persist the result. All work runs
    /// on the actor's executor; the actor is on the cooperative pool, not
    /// the main thread, so the UI is never blocked.
    func refreshFromFilesystem() async {
        ensureLoaded()
        await PricingService.shared.ensureLoaded()
        // Pick up a newer pricing snapshot the background download may have
        // written since launch — otherwise a long-lived session prices any
        // model released mid-session at $0. Runs before stamping/pricing so
        // this cycle's cost output already reflects the reloaded table.
        await PricingService.shared.reloadIfFreshChanged()
        // Capture the current pricing source for the envelope stamp.
        let src = await PricingService.shared.currentSource()
        let previousPricingSource = pricingMeta.source
        pricingMeta = stampFor(source: src)
        // Trigger a TTL'd background refresh of the LiteLLM JSON. No-op if fresh.
        PricingService.shared.refreshInBackground()

        let start = Date()
        let cachedMtimes: [String: Double] = files.mapValues { $0.mtimeUnix }
        let result = Self.scanAndParse(projectsDir: claudeProjectsDir, cachedMtimes: cachedMtimes,
                                       incremental: &incremental)

        for (path, entry) in result.updates {
            files[path] = entry
        }
        var evicted = 0
        for path in files.keys where !result.livePaths.contains(path) {
            files.removeValue(forKey: path)
            incremental.remove(path)
            evicted += 1
            log.debug("EVICT \(path) reason=file-deleted")
        }

        let totalMs = Int(Date().timeIntervalSince(start) * 1000)
        log.info(
            "refresh: scanned=\(result.livePaths.count) "
            + "hit=\(result.hits) miss=\(result.missesNew + result.missesMtime) "
            + "(new=\(result.missesNew), mtime=\(result.missesMtime)) "
            + "evicted=\(evicted) parse_total=\(result.parseElapsedMs)ms total=\(totalMs)ms "
            + "incremental=\(result.incrementalParses)/\(result.incrementalMs)ms/"
            + "\(result.incrementalBytes / 1024)KB/\(result.incrementalLines)lines "
            + "full=\(result.fullParses)/\(result.fullMs)ms "
            + "(known_path=\(result.fullParsesOnKnownPath)) "
            + "invalidated=\(result.invalidations) read=\(result.bytesRead / 1024)KB "
            + "lines=\(result.linesConsumed) states=\(incremental.count) "
            + "pricing=\(pricingMeta.source)"
        )

        if !result.updates.isEmpty || evicted > 0 || pricingMeta.source != previousPricingSource {
            dirty = true
        }
        saveIfDue()
    }

    /// Per-day, per-model cost summary. Applies global max-output-wins dedup
    /// across all cached files (keeping the largest-output copy of each
    /// duplicated message) to match ccusage 20.x's behavior.
    ///
    /// Each kept row is priced individually so the 200k-tier threshold
    /// and the fast multiplier apply per-request — not at the aggregated
    /// (date, model) level — which would let one fast or one 200k+ row
    /// contaminate every other row in its bucket.
    func costSummary() async -> CostSummary {
        await PricingService.shared.ensureLoaded()

        // Sort files by earliest timestamp. Secondary sort by path string for
        // deterministic ordering when timestamps tie (or are
        // .greatestFiniteMagnitude for files with no parseable timestamps,
        // which sort last). Dedup is max-output-wins below, so this order no
        // longer affects which duplicate copy wins — it only stabilizes output.
        let sortedFiles: [(path: String, file: CachedFileV2)] = files
            .map { ($0.key, $0.value) }
            .sorted {
                if $0.1.earliestTimestampUnix != $1.1.earliestTimestampUnix {
                    return $0.1.earliestTimestampUnix < $1.1.earliestTimestampUnix
                }
                return $0.0 < $1.0
            }

        // (date, model) → running totals; cost is summed per-row.
        struct Acc {
            var input = 0, output = 0, cw = 0, cr = 0
            var cost: Double = 0
        }
        var bucket: [String: [String: Acc]] = [:]
        var sessionsByDate: [String: Set<String>] = [:]
        // Resolve every model's price in a single actor hop up front. Doing
        // this atomically — rather than awaiting `pricing(for:)` per row —
        // means a concurrent `reloadIfFreshChanged()` can't swap the pricing
        // table mid-summary and leave one result mixing old and new prices.
        var distinctModels: Set<String> = []
        for (_, file) in sortedFiles {
            for e in file.entries { distinctModels.insert(e.model) }
        }
        let priceCache = await PricingService.shared.prices(for: Array(distinctModels))

        // Global max-output-wins dedup across files. A message written more than
        // once (partial stream snapshot + final copy) shares a hash; input/cache
        // are identical across copies, only output_tokens grows, so keep the
        // largest-output copy. nil-hash entries are never deduped. Selecting the
        // winner is order-independent (max), so file order doesn't matter here.
        struct Winner { let e: CachedEntryV2; let sessionKey: String }
        var bestByHash: [String: Winner] = [:]
        var nilHashWinners: [Winner] = []
        for (path, file) in sortedFiles {
            let sessionKey = file.sessionId ?? path
            for e in file.entries {
                let w = Winner(e: e, sessionKey: sessionKey)
                guard let h = e.hash else { nilHashWinners.append(w); continue }
                if let cur = bestByHash[h] {
                    if e.output > cur.e.output { bestByHash[h] = w }
                } else {
                    bestByHash[h] = w
                }
            }
        }

        var winners: [Winner] = Array(bestByHash.values)
        winners.append(contentsOf: nilHashWinners)
        for w in winners {
            let e = w.e
            // ccusage strips `<synthetic>` from modelBreakdowns at aggregation
            // time. These rows are zero-token / zero-cost anyway (compaction
            // events, internal errors), so skipping them changes no numbers —
            // only removes a meaningless entry from the UI's model column.
            if e.model == "<synthetic>" { continue }
            sessionsByDate[e.date, default: []].insert(w.sessionKey)

            // priceCache holds every model seen above; `?? nil` flattens
            // the optional-of-optional for a model with no pricing entry.
            let price = priceCache[e.model] ?? nil
            let rowCost = price?.cost(
                input: e.input, output: e.output,
                cacheCreate: e.cw, cacheCreate1h: e.cw1h, cacheRead: e.cr,
                isFast: e.speed == "fast"
            ) ?? 0

            var byModel = bucket[e.date] ?? [:]
            var acc = byModel[e.model] ?? Acc()
            acc.input += e.input
            acc.output += e.output
            acc.cw += e.cw
            acc.cr += e.cr
            acc.cost += rowCost
            byModel[e.model] = acc
            bucket[e.date] = byModel
        }

        var dailyCosts: [DailyCost] = []
        for (date, byModel) in bucket {
            var totalCost: Double = 0
            var modelBreakdown: [String: Double] = [:]
            var sumIn = 0, sumOut = 0, sumCW = 0, sumCR = 0
            for (model, acc) in byModel {
                totalCost += acc.cost
                let short = CostParser.shortModelName(model)
                modelBreakdown[short, default: 0] += acc.cost
                sumIn += acc.input; sumOut += acc.output
                sumCW += acc.cw; sumCR += acc.cr
            }
            dailyCosts.append(DailyCost(
                date: date,
                totalCost: totalCost,
                modelBreakdown: modelBreakdown,
                sessionCount: sessionsByDate[date]?.count ?? 0,
                inputTokens: sumIn,
                outputTokens: sumOut,
                cacheWriteTokens: sumCW,
                cacheReadTokens: sumCR
            ))
        }
        dailyCosts.sort { $0.date > $1.date }

        let todayStr = Self.localDateString(Date())
        let todayCost = dailyCosts.first(where: { $0.date == todayStr })?.totalCost ?? 0
        log.info("costSummary: \(dailyCosts.count) days, today=$\(String(format: "%.2f", todayCost))")
        return CostSummary(todayCost: todayCost, dailyCosts: dailyCosts)
    }

    /// Today's activity stats. Sidechain (subagent) files are excluded —
    /// matches v1 behavior and avoids subagent tool-calls inflating the
    /// "today you wrote X lines" headline.
    func activityStatsToday() -> ActivityStats {
        let today = Self.localDateString(Date())

        var turns = 0, active = 0, lines = 0
        var tools: [String: Int] = [:]
        var models: [String: Int] = [:]

        for (_, file) in files {
            if file.isSidechain { continue }
            guard let day = file.activityByDate[today] else { continue }
            turns += day.turns
            active += day.activeMinutes
            lines += day.linesWritten
            for (k, v) in day.toolCounts { tools[k, default: 0] += v }
            for (k, v) in day.modelCounts { models[k, default: 0] += v }
        }

        log.info("activityStatsToday: turns=\(turns) active=\(active)m lines=\(lines)")
        return ActivityStats(
            conversationTurns: turns,
            activeCodingMinutes: active,
            toolUsage: tools,
            linesWritten: lines,
            modelUsage: models
        )
    }

    /// Read-only view of the pricing snapshot in use. Surfaced for
    /// debugging UIs and the Cost tab's "How We Calculate" line.
    func pricingMetaSnapshot() -> PricingMeta { pricingMeta }

    // MARK: - Scan & parse

    private struct ScanResult {
        let livePaths: Set<String>
        let updates: [String: CachedFileV2]
        let hits: Int
        let missesNew: Int
        let missesMtime: Int
        let parseElapsedMs: Int
        var incrementalParses = 0
        var fullParses = 0
        /// Of `fullParses`, the ones on a path the cache already knew: either
        /// no state to continue from (dropped to make room), or a state whose
        /// prefix no longer matched (also counted in `invalidations`).
        /// Separated because "a path we had never seen" and "a known path
        /// rebuilt from scratch" cost the same but mean different things.
        var fullParsesOnKnownPath = 0
        var invalidations = 0
        var bytesRead = 0
        var linesConsumed = 0
        /// Split by mode, so a slow refresh can be attributed rather than
        /// argued about: which half of the work took the time.
        var incrementalMs = 0
        var fullMs = 0
        var incrementalBytes = 0
        var incrementalLines = 0
    }

    private static func scanAndParse(
        projectsDir: String,
        cachedMtimes: [String: Double],
        incremental: inout IncrementalStateStore
    ) -> ScanResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectsDir) else {
            log.warning("scan: cannot enumerate \(projectsDir)")
            return ScanResult(livePaths: [], updates: [:], hits: 0, missesNew: 0, missesMtime: 0, parseElapsedMs: 0)
        }

        var live: Set<String> = []
        var updates: [String: CachedFileV2] = [:]
        var hits = 0, missesNew = 0, missesMtime = 0
        var incrementalParses = 0, fullParses = 0, invalidations = 0, bytesRead = 0, linesConsumed = 0
        var fullOnKnownPath = 0
        // Seconds as Double, rounded once at the end: per-file truncation to
        // whole milliseconds silently drops most of a cold build's time.
        var parseSec = 0.0, incrementalSec = 0.0, fullSec = 0.0
        var incrementalBytes = 0, incrementalLines = 0

        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") else { continue }
            let filePath = projectsDir + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let mtimeDate = attrs[.modificationDate] as? Date else { continue }
            let mtime = mtimeDate.timeIntervalSince1970
            live.insert(filePath)

            if let cached = cachedMtimes[filePath], cached == mtime {
                hits += 1
                continue
            }
            let isNewPath = cachedMtimes[filePath] == nil
            if isNewPath { missesNew += 1 } else { missesMtime += 1 }

            let t0 = Date()
            let outcome = parseJSONLFile(at: filePath, relativePath: rel, mtime: mtime,
                                         previous: incremental[filePath])
            let elapsed = Date().timeIntervalSince(t0)
            parseSec += elapsed
            if let outcome {
                updates[filePath] = outcome.file
                incremental.put(outcome.state, for: filePath)
                switch outcome.mode {
                case .incremental:
                    incrementalParses += 1
                    incrementalSec += elapsed
                    incrementalBytes += outcome.bytesRead
                    incrementalLines += outcome.linesConsumed
                case .full:
                    fullParses += 1
                    fullSec += elapsed
                    if !isNewPath { fullOnKnownPath += 1 }
                }
                if outcome.invalidated { invalidations += 1 }
                bytesRead += outcome.bytesRead
                linesConsumed += outcome.linesConsumed
            }
        }

        return ScanResult(livePaths: live, updates: updates, hits: hits,
                          missesNew: missesNew, missesMtime: missesMtime,
                          parseElapsedMs: Int(parseSec * 1000),
                          incrementalParses: incrementalParses, fullParses: fullParses,
                          fullParsesOnKnownPath: fullOnKnownPath,
                          invalidations: invalidations, bytesRead: bytesRead,
                          linesConsumed: linesConsumed,
                          incrementalMs: Int(incrementalSec * 1000),
                          fullMs: Int(fullSec * 1000),
                          incrementalBytes: incrementalBytes,
                          incrementalLines: incrementalLines)
    }

    // MARK: - Disk I/O

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL) else {
            log.info("LOAD path=\(cacheURL.path) status=missing")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(CacheEnvelopeV2.self, from: data) else {
            log.warning("LOAD bytes=\(data.count) decode-failed, discarding")
            return
        }
        guard envelope.version == Self.currentVersion else {
            log.info("LOAD version=\(envelope.version) != current=\(Self.currentVersion), discarding")
            return
        }
        files = envelope.files
        pricingMeta = envelope.pricing
        log.info("LOAD bytes=\(data.count) entries=\(files.count) pricing=\(envelope.pricing.source)")
    }

    private func saveIfDue() {
        guard dirty else { return }
        if let last = lastSuccessfulSave, Date().timeIntervalSince(last) < Self.minSaveInterval {
            log.debug("SAVE deferred: dirty, last save \(Int(Date().timeIntervalSince(last)))s ago")
            return
        }
        if save() {
            dirty = false
            lastSuccessfulSave = Date()
        }
    }

    private func save() -> Bool {
        let envelope = CacheEnvelopeV2(
            version: Self.currentVersion,
            lastUpdated: Date(),
            pricing: pricingMeta,
            files: files
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else {
            log.error("SAVE failed to encode")
            return false
        }
        do {
            try data.write(to: cacheURL, options: .atomic)
            log.info("SAVE bytes=\(data.count) entries=\(files.count)")
            return true
        } catch {
            log.error("SAVE failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Helpers

    private nonisolated func stampFor(source: PricingSource) -> PricingMeta {
        switch source {
        case .bundle(let commit):
            return PricingMeta(source: "bundle:\(commit)", fetchedAt: nil)
        case .fresh(let at):
            let f = ISO8601DateFormatter()
            return PricingMeta(source: "fresh:\(f.string(from: at))", fetchedAt: at)
        }
    }

    private static func localDateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
