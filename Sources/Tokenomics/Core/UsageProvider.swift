import Foundation

/// One day's aggregated usage, normalized across providers (Claude, Codex, …).
/// This is the shape every presentation layer (menu bar, future widget) consumes.
struct DailyUsage {
    let date: String            // ISO day, e.g. "2026-06-03"
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let totalCost: Double        // USD, API-equivalent pricing
    let models: [String]
}

/// A source of usage data. Callback-based rather than async/await to avoid
/// Swift-6 actor-isolation ceremony until the project adopts strict concurrency.
///
/// The one primitive is `fetchRecords`: the RAW, pre-dedup `UsageRecord` stream for
/// this source. Every derived view (daily, per-vendor, intraday matrix) is computed
/// from it through `UsageAggregator`, which runs the single global `Dedup.collapse`
/// over the union — so combining sources (the local providers today, peer Macs
/// later) stays correct without any source re-implementing aggregation.
protocol UsageProvider {
    var id: String { get }

    /// Raw, PRE-dedup records from this source.
    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void)

    func fetchDaily(completion: @escaping (Result<[DailyUsage], Error>) -> Void)
    /// Per-vendor daily series (provider id → days). The break-even view needs each
    /// vendor's cost separately, which the merged daily series throws away.
    func fetchDailyByVendor(completion: @escaping ([String: [DailyUsage]]) -> Void)
    /// Per-minute token counts (split by type + by model) for EVERY day with data
    /// (day → [1440]). Returning the full matrix lets the caller trim to a precise
    /// day window after merging, instead of each source guessing the window.
    func fetchDayMinuteMatrix(completion: @escaping ([String: [MinuteBucket]]) -> Void)
}

extension UsageProvider {
    /// All three views derive from the record stream through one aggregation path,
    /// so a conforming source only has to implement `fetchRecords`.
    func fetchDaily(completion: @escaping (Result<[DailyUsage], Error>) -> Void) {
        fetchRecords { completion(.success(UsageAggregator.daily($0))) }
    }

    func fetchDailyByVendor(completion: @escaping ([String: [DailyUsage]]) -> Void) {
        fetchRecords { completion(UsageAggregator.byVendor($0)) }
    }

    func fetchDayMinuteMatrix(completion: @escaping ([String: [MinuteBucket]]) -> Void) {
        fetchRecords { completion(UsageAggregator.dayMinuteMatrix($0)) }
    }
}
