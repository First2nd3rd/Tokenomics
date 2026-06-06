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

    /// Tokens that represent "real work" — excludes cache traffic, which can
    /// dwarf the headline number. Useful for an alternate display later.
    var workTokens: Int { inputTokens + outputTokens }
}

/// A source of usage data. Callback-based to keep the prototype free of Swift-6
/// concurrency ceremony.
protocol UsageProvider {
    var id: String { get }
    func fetchDaily(completion: @escaping (Result<[DailyUsage], Error>) -> Void)
    /// Today's tokens per local minute (0…1439), for the intraday rate chart.
    func fetchTodayByMinute(now: Date, completion: @escaping ([Int]) -> Void)
}

extension UsageProvider {
    /// Providers without intraday support contribute an empty (all-zero) series.
    func fetchTodayByMinute(now: Date, completion: @escaping ([Int]) -> Void) {
        completion(Array(repeating: 0, count: 1440))
    }
}
