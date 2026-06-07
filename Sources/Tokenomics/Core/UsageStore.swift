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

    func refresh(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        provider.fetchDaily { result in
            let mapped = result.map { days -> UsageSnapshot in
                UsageSnapshot(days: days.sorted { $0.date < $1.date })
            }
            DispatchQueue.main.async { completion(mapped) }
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
