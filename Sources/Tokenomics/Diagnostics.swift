import Foundation

/// Runs an async, callback-based fetch synchronously. Diagnostics only.
private func waitFor<T>(_ fetch: (@escaping (T) -> Void) -> Void) -> T {
    var result: T!
    let semaphore = DispatchSemaphore(value: 0)
    fetch { value in
        result = value
        semaphore.signal()
    }
    semaphore.wait()
    return result
}

/// Times report builds per period, twice each (cold, then warm caches), to see
/// where a Statistics period switch spends its time. Invoked with `--bench-report`.
enum BenchReport {
    static func run() {
        // Deliver inline: this CLI has no main run loop to drain the default hop.
        let store = UsageStore(deliver: { work in work() })
        for period in [ReportPeriod.day, .week, .month] {
            for attempt in 1...2 {
                let start = Date()
                let report: PeriodReport? = waitFor { done in
                    store.report(period: period, anchor: Date(), completion: done)
                }
                let ms = Date().timeIntervalSince(start) * 1000
                let total = report?.total.total ?? -1
                FileHandle.standardError.write(Data(
                    String(format: "%@ #%d: %.0f ms (total %d)\n",
                           period.label, attempt, ms, total).utf8))
            }
        }
    }
}

/// One-off repair (`--refreeze <day> [<day>…]`): recompute the named finalized
/// days from the LIVE logs with the dashboard's exact collapse, then overwrite
/// both the archive segment and the frozen snapshot — the explicit escape hatch
/// from the grow-only rule for days the archive captured inflated transients.
/// Run with the menu bar app quit. Refuses a day the logs no longer cover.
enum Refreeze {
    /// A live total this far below the archive means partial log rotation, not a
    /// transient correction — refuse rather than truncate a real day.
    private static let plausibleShrinkFloor = 0.8

    static func run(days: [String], force: Bool) {
        let records: [UsageRecord] = waitFor { done in
            CombinedProvider([ClaudeNativeProvider(), CodexProvider(), WorkBuddyProvider()]).fetchRecords(completion: done)
        }
        guard let folder = LocalArchiveFolder() else {
            FileHandle.standardError.write(Data("archive folder unavailable\n".utf8))
            exit(1)
        }
        let archive = UsageArchive(folder: folder)
        let snapshots = SnapshotStore()
        let now = Date()
        var failures = 0

        backUp(days: days)

        // Dashboard semantics: collapse the WHOLE corpus first, then bucket by the
        // surviving record's epoch — filtering by day first would count a
        // midnight-straddling turn's superseded partials into the repaired day.
        let collapsed = Dedup.collapse(records)

        for day in days {
            let dayRecords = collapsed.filter { DayBucket.day(epoch: $0.epoch) == day }
            guard !dayRecords.isEmpty else {
                FileHandle.standardError.write(Data("refuse \(day): live logs hold no records (rotated?)\n".utf8))
                failures += 1
                continue
            }
            let month = String(day.prefix(7))
            let archiveTotal = archive.records(forMonths: [month])
                .filter { DayBucket.day(epoch: $0.epoch) == day }
                .reduce(0) { $0 + $1.totalTokens }
            let liveTotal = dayRecords.reduce(0) { $0 + $1.totalTokens }
            if !force, liveTotal < Int(Double(archiveTotal) * plausibleShrinkFloor) {
                FileHandle.standardError.write(Data(
                    "refuse \(day): live \(liveTotal) is >20% below archive \(archiveTotal) — partial rotation likely (--force to override)\n".utf8))
                failures += 1
                continue
            }
            guard let summary = UsageAggregator.daySummaries(
                dayRecords, pricedAt: Int(now.timeIntervalSince1970), frozen: true,
                assumeCollapsed: true).first else { failures += 1; continue }

            guard archive.replaceDay(day, with: dayRecords) else {
                FileHandle.standardError.write(Data("FAILED \(day): archive segment write failed\n".utf8))
                failures += 1
                continue
            }
            guard snapshots.overwrite(summary, now: now) else {
                FileHandle.standardError.write(Data(
                    "FAILED \(day): snapshot store refused (unreadable snapshots.ndjson?) — archive repaired, rerun after checking the file\n".utf8))
                failures += 1
                continue
            }
            print("\(day): frozen \(archiveTotal) → \(summary.total.total)")
        }
        exit(failures == 0 ? 0 : 1)
    }

    /// Copy snapshots.ndjson and each affected month segment aside before mutating.
    private static func backUp(days: [String]) {
        guard let support = AppPaths.applicationSupport() else { return }
        let dir = support.appendingPathComponent(
            "backup-refreeze-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sources = [support.appendingPathComponent("snapshots.ndjson")]
        for month in Set(days.map { String($0.prefix(7)) }) {
            sources.append(support.appendingPathComponent("archive")
                .appendingPathComponent(archiveSegmentName(forMonth: month)))
        }
        for src in sources where FileManager.default.fileExists(atPath: src.path) {
            try? FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(src.lastPathComponent))
        }
        print("backup: \(dir.path)")
    }
}

/// Builds every Statistics period against REAL data and checks the invariants the
/// sub-pages rely on: per-day rows sum to the period total, and each period's
/// alternate chart (hourly / week slots / weekly rollup) preserves that total.
/// Prints per-day rows for external diffing; exits non-zero on any violation.
/// Invoked with `--verify-report`.
enum VerifyReport {
    static func run() {
        let store = UsageStore(deliver: { work in work() })
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "ok " : "FAIL") \(name)")
            if !ok { failures += 1 }
        }

        for period in [ReportPeriod.day, .week, .month, .all] {
            guard let r: PeriodReport = waitFor({ done in
                store.report(period: period, anchor: Date(), completion: done)
            }) else {
                check("\(period.label): report built", false)
                continue
            }
            let daySum = r.days.reduce(0) { $0 + $1.totalTokens }
            check("\(period.label): day rows sum to total (\(r.total.total))", daySum == r.total.total)
            let vendorSum = r.byVendor.reduce(0) { $0 + $1.tokens }
            check("\(period.label): vendor split sums to total", vendorSum == r.total.total)

            switch period {
            case .day:
                let hourSum = (r.hourly ?? []).reduce(0) { $0 + $1.total }
                check("Day: hour buckets sum to total", hourSum == r.total.total)
            case .week:
                let fine = r.fine ?? []
                let slotSum = fine.reduce(0) { $0 + $1.counts.total }
                check("Week: hour slots sum to total", slotSum == r.total.total)
                let regrouped = PeriodReport.regroup(fine, hours: 3).reduce(0) { $0 + $1.counts.total }
                check("Week: 3h regroup preserves total", regrouped == r.total.total)
            case .month:
                let weekly = r.weeklyRollup().reduce(0) { $0 + $1.totalTokens }
                check("Month: weekly rollup sums to total", weekly == r.total.total)
            case .all:
                let monthly = (r.months ?? []).reduce(0) { $0 + $1.tokens }
                check("All: monthly rollup sums to total", monthly == r.total.total)
            }
            // The all-time day list spans the whole archive — the per-day dump
            // stays scoped to the calendar periods.
            if period != .all {
                for day in r.days { print("\(period.label) \(day.date) \(day.totalTokens)") }
            }
        }
        exit(failures == 0 ? 0 : 1)
    }
}

/// Times two consecutive reads on one provider instance: the first does the full
/// scan, the second should hit the mtime cache. Invoked with `--bench`.
enum Bench {
    static func run() {
        let provider = ClaudeNativeProvider()
        for i in 1...2 {
            let start = Date()
            let semaphore = DispatchSemaphore(value: 0)
            provider.fetchDaily { _ in semaphore.signal() }
            semaphore.wait()
            let ms = Date().timeIntervalSince(start) * 1000
            FileHandle.standardError.write(Data(String(format: "read #%d: %.0f ms\n", i, ms).utf8))
        }
    }
}

/// Streams every Claude JSONL line WITHOUT decoding or storing — isolates the
/// LineReader's memory behaviour from parsing. Invoked with `--scan-only`.
enum ScanOnly {
    static func run() {
        var lines = 0
        var bytes = 0
        for root in ClaudeNativeProvider.claudeProjectRoots() {
            for file in ClaudeNativeProvider.jsonlFiles(under: root) {
                LineReader.forEachLine(of: file) { lineData in
                    lines += 1
                    bytes += lineData.count
                }
            }
        }
        FileHandle.standardOutput.write(Data("lines=\(lines) bytes=\(bytes)\n".utf8))
    }
}

/// Prints per-day token totals + cost as TSV, for diffing against
/// `ccusage daily --json`. `--dump-daily` dumps Claude; `--dump-codex` dumps Codex.
enum DumpDaily {
    static func run(provider: UsageProvider = ClaudeNativeProvider()) {
        let result = waitFor { provider.fetchDaily(completion: $0) }
        switch result {
        case .success(let days):
            var out = ""
            for day in days.sorted(by: { $0.date < $1.date }) {
                out += "\(day.date)\t\(day.inputTokens)\t\(day.outputTokens)\t\(day.cacheCreationTokens)\t\(day.cacheReadTokens)\t\(day.totalTokens)\t\(String(format: "%.6f", day.totalCost))\n"
            }
            FileHandle.standardOutput.write(Data(out.utf8))
        case .failure(let error):
            FileHandle.standardError.write(Data("dump-daily error: \(error)\n".utf8))
        }
    }
}

/// Inspects the iCloud peers folder via the real `ICloudDriveFolder` read path and
/// prints each peer file's manifest + a structure check. Invoked with `--dump-peers`.
/// Run from a context that has iCloud Drive access (the app's own bundle).
enum DumpPeers {
    static func run() {
        let folder = ICloudDriveFolder()
        print("this machine id: \(DeviceIdentity.id)")
        print("display name:    \(DeviceIdentity.displayName())")
        guard let dir = folder.directoryURL else {
            print("iCloud Drive unavailable (directoryURL == nil) — not signed in / iCloud Drive off")
            return
        }
        print("peers dir:       \(dir.path)")

        let urls = folder.peerFileURLs()
        print("found \(urls.count) *.ndjson file(s)\n")

        for url in urls {
            let name = url.lastPathComponent
            print("===== \(name) =====")
            guard let data = folder.readData(at: url) else {
                print("  [unreadable — undownloaded iCloud placeholder, or TCC-blocked]\n")
                continue
            }
            guard let contents = PeerFile.decode(data) else {
                print("  [decode FAILED — \(data.count) bytes, manifest missing/unsupported]\n")
                continue
            }
            let m = contents.manifest
            let isThisMac = m.machineId == DeviceIdentity.id
            let filenameOK = name == peerFileName(forMachine: m.machineId)
            print("  bytes:        \(data.count)")
            print("  schemaVersion:\(m.schemaVersion)")
            print("  machineId:    \(m.machineId)  \(isThisMac ? "(THIS MAC — should be skipped on read)" : "(peer)")")
            print("  displayName:  \(m.displayName)")
            print("  appVersion:   \(m.appVersion)")
            print("  publishedAt:  \(m.publishedAt)  (\(Date(timeIntervalSince1970: TimeInterval(m.publishedAt)))) ")
            print("  windowDays:   \(m.windowDays)")
            print("  recordCount:  manifest=\(m.recordCount)  actual=\(contents.records.count)  \(m.recordCount == contents.records.count ? "✓ match" : "✗ MISMATCH")")
            print("  filename↔id:  \(filenameOK ? "✓ match" : "✗ MISMATCH")")
            if let r = contents.records.first {
                print("  first record: source=\(r.source.rawValue) key=\(r.key ?? "nil") ts=\(r.epoch) i=\(r.input) o=\(r.output) w=\(r.cacheCreation) r=\(r.cacheRead) model=\(r.model ?? "nil") machine=\(r.machine ?? "nil")")
            }
            print("")
        }
    }
}

/// Inspects the durable archive: each month segment's manifest + record count, the
/// backfill flag, and a Markdown report for the current month. Invoked with
/// `--dump-archive`. Run from the app's bundle (it owns the Application Support dir).
enum DumpArchive {
    static func run() {
        guard let folder = LocalArchiveFolder() else {
            print("archive directory unavailable (Application Support unreachable)")
            return
        }
        let archive = UsageArchive(folder: folder)
        print("archive dir: \(folder.directoryURL?.path ?? "nil")")
        print("backfilled:  \(archive.isBackfilled)")
        let months = archive.availableMonths()
        print("segments:    \(months.count)\n")

        for month in months {
            guard let dir = folder.directoryURL,
                  let data = folder.readData(at: dir.appendingPathComponent(archiveSegmentName(forMonth: month))),
                  let contents = ArchiveFile.decode(data) else {
                print("===== \(month) =====\n  [unreadable]\n")
                continue
            }
            let m = contents.manifest
            print("===== \(month) =====")
            print("  bytes:        \(data.count)")
            print("  schema:       \(m.schemaVersion)")
            print("  recordCount:  manifest=\(m.recordCount)  actual=\(contents.records.count)  \(m.recordCount == contents.records.count ? "✓" : "✗ MISMATCH")")
            print("  updatedAt:    \(Date(timeIntervalSince1970: TimeInterval(m.updatedAt)))")
            print("")
        }

        let now = Date()
        let range = ReportPeriod.month.range(containing: now)
        let report = PeriodReport.make(records: archive.records(forMonths: range.segmentsToRead()),
                                       period: .month, anchor: now, now: now)
        print("----- current month report -----")
        print(ReportMarkdown.make(report))
    }
}

/// Prints today's non-empty 5-minute token buckets (combined Claude+Codex) plus a
/// TOTAL, to sanity-check the intraday rate chart. Invoked with `--dump-intraday`.
enum DumpIntraday {
    static func run() {
        let provider = CombinedProvider([ClaudeNativeProvider(), CodexProvider(), WorkBuddyProvider()])
        let now = Date()
        let matrix = waitFor { provider.fetchDayMinuteMatrix(completion: $0) }
        let minutes = matrix[DayBucket.dayKey(now)] ?? Array(repeating: MinuteBucket(), count: 1440)

        var out = ""
        var total = 0
        var start = 0
        while start < 1440 {
            let sum = minutes[start..<min(start + 5, 1440)].reduce(0) { $0 + $1.counts.total }
            total += sum
            if sum > 0 { out += String(format: "%02d:%02d\t%d\n", start / 60, start % 60, sum) }
            start += 5
        }
        out += "TOTAL\t\(total)\n"
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

/// Prints the cumulative-curve summary (today final, typical final, projected) to
/// sanity-check the prediction. Invoked with `--dump-curve`.
enum DumpCurve {
    static func run() {
        let provider = CombinedProvider([ClaudeNativeProvider(), CodexProvider(), WorkBuddyProvider()])
        let now = Date()
        let full = waitFor { provider.fetchDayMinuteMatrix(completion: $0) }
        // Mirror UsageStore: merge first (CombinedProvider), then trim to the window.
        let matrix = DayBucket.recentDays(full, now: now, count: 14)
        let series = IntradayCurve.build(matrix: matrix, now: now)

        var out = ""
        out += "prior days in matrix: \(matrix.keys.count - 1)\n"
        out += "today cumulative (so far): \(series.today.last?.tokens ?? 0)\n"
        out += "typical day (avg total):   \(series.typical.last?.tokens ?? 0)\n"
        out += "projected end-of-day:      \(series.projectedTotal.map(String.init) ?? "n/a")\n"
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}
