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
protocol UsageProvider {
    var id: String { get }
    func fetchDaily(completion: @escaping (Result<[DailyUsage], Error>) -> Void)
    /// Per-minute token counts (split by type) for today + the `lastDays` prior days
    /// (day → [1440]), for the intraday rate chart and the cumulative curve.
    func fetchDayMinuteMatrix(now: Date, lastDays: Int, completion: @escaping ([String: [MinuteBucket]]) -> Void)
}

extension UsageProvider {
    /// Providers without intraday support contribute an empty matrix.
    func fetchDayMinuteMatrix(now: Date, lastDays: Int, completion: @escaping ([String: [MinuteBucket]]) -> Void) {
        completion([:])
    }
}
