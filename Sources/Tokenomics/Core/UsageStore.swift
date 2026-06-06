import Foundation

/// A point-in-time view of usage, with the latest day and the one before it
/// surfaced for the menu bar's headline + day-over-day comparison.
struct UsageSnapshot {
    let days: [DailyUsage]   // sorted ascending by date

    /// Most recent day with activity (treated as "today").
    var latest: DailyUsage? { days.last }

    /// The day before `latest` in the data (may skip gap days for now).
    var previous: DailyUsage? { days.count >= 2 ? days[days.count - 2] : nil }
}

/// Owns the current provider and exposes a single refresh entry point.
/// Results are delivered on the main queue, ready for UI.
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
}
