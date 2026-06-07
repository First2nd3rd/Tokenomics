import Foundation

/// A point-in-time view of usage: the per-day series, sorted ascending by date.
struct UsageSnapshot {
    let days: [DailyUsage]
}

/// Owns the current provider and exposes refresh entry points. Results are
/// delivered on the main queue, ready for UI.
final class UsageStore {
    private let provider: UsageProvider

    init(provider: UsageProvider = CombinedProvider([ClaudeNativeProvider(), CodexProvider()])) {
        self.provider = provider
    }

    /// Per-vendor daily series (provider id → days), delivered on the main queue.
    /// The combined snapshot is just the merge of these, so this is the single
    /// source for both the headline and the per-vendor break-even.
    func refreshByVendor(completion: @escaping ([String: [DailyUsage]]) -> Void) {
        provider.fetchDailyByVendor { byVendor in
            DispatchQueue.main.async { completion(byVendor) }
        }
    }

    /// Day→minute matrix (today + the `lastDays` prior days with data), delivered on
    /// the main queue. Providers return their full matrix; the merge happens first
    /// and the window is trimmed once here, so it stays exact across providers.
    func refreshMatrix(now: Date = Date(), lastDays: Int, completion: @escaping ([String: [MinuteBucket]]) -> Void) {
        provider.fetchDayMinuteMatrix { matrix in
            let trimmed = DayBucket.recentDays(matrix, now: now, count: lastDays)
            DispatchQueue.main.async { completion(trimmed) }
        }
    }
}
