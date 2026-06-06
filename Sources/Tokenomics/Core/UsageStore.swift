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

    /// Day→minute matrix (today + recent days), delivered on the main queue.
    func refreshMatrix(now: Date = Date(), lastDays: Int, completion: @escaping ([String: [Int]]) -> Void) {
        provider.fetchDayMinuteMatrix(now: now, lastDays: lastDays) { matrix in
            DispatchQueue.main.async { completion(matrix) }
        }
    }
}
