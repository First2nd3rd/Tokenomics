import Foundation

/// Fans out to several providers and UNIONS their raw records into one stream.
/// Deduping and aggregation (the single global `Dedup.collapse`) happen downstream
/// in `UsageAggregator` via the default `UsageProvider` views — so a turn that
/// appears under two sources (e.g. a mirror-synced dotfile, or a peer Mac later) is
/// deduped once instead of double-counted. A provider that fails to produce records
/// simply contributes nothing rather than failing the whole refresh.
final class CombinedProvider: UsageProvider {
    let id = "combined"

    private let providers: [UsageProvider]

    init(_ providers: [UsageProvider]) {
        self.providers = providers
    }

    /// The union of every child's raw, pre-dedup records.
    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var all: [UsageRecord] = []

        for provider in providers {
            group.enter()
            provider.fetchRecords { records in
                lock.lock()
                all.append(contentsOf: records)
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .utility)) { completion(all) }
    }

    /// Merge per-vendor daily series into one combined series, summing tokens and
    /// cost and unioning model lists. `AppDelegate` builds the headline snapshot from
    /// the per-vendor series this way; the per-vendor series is already deduped
    /// (`UsageAggregator`), so this is a plain same-date sum.
    static func merge(_ lists: [[DailyUsage]]) -> [DailyUsage] {
        var byDay: [String: DailyUsage] = [:]
        for day in lists.flatMap({ $0 }) {
            if let existing = byDay[day.date] {
                byDay[day.date] = combine(existing, day)
            } else {
                byDay[day.date] = day
            }
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    private static func combine(_ a: DailyUsage, _ b: DailyUsage) -> DailyUsage {
        DailyUsage(
            date: a.date,
            inputTokens: a.inputTokens + b.inputTokens,
            outputTokens: a.outputTokens + b.outputTokens,
            cacheCreationTokens: a.cacheCreationTokens + b.cacheCreationTokens,
            cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
            totalTokens: a.totalTokens + b.totalTokens,
            totalCost: a.totalCost + b.totalCost,
            models: Array(Set(a.models).union(b.models)).sorted()
        )
    }
}
