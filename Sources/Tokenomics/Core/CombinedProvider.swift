import Foundation

/// Fans out to several providers and merges their per-day usage into one series,
/// summing tokens and cost and unioning the model lists. A provider that fails
/// contributes nothing rather than failing the whole refresh.
final class CombinedProvider: UsageProvider {
    let id = "combined"

    private let providers: [UsageProvider]

    init(_ providers: [UsageProvider]) {
        self.providers = providers
    }

    /// Combined daily series = the per-vendor series merged. Kept as a thin wrapper
    /// over `fetchDailyByVendor` (the path the app actually uses) so the two can't
    /// drift; satisfies the protocol and stays available for diagnostics.
    func fetchDaily(completion: @escaping (Result<[DailyUsage], Error>) -> Void) {
        fetchDailyByVendor { byVendor in
            completion(.success(Self.merge(Array(byVendor.values))))
        }
    }

    func fetchDailyByVendor(completion: @escaping ([String: [DailyUsage]]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var merged: [String: [DailyUsage]] = [:]

        for provider in providers {
            group.enter()
            provider.fetchDailyByVendor { byVendor in
                lock.lock()
                for (id, days) in byVendor { merged[id, default: []].append(contentsOf: days) }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .utility)) { completion(merged) }
    }

    func fetchDayMinuteMatrix(completion: @escaping ([String: [MinuteBucket]]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var merged: [String: [MinuteBucket]] = [:]

        for provider in providers {
            group.enter()
            provider.fetchDayMinuteMatrix { matrix in
                lock.lock()
                for (day, minutes) in matrix {
                    if var existing = merged[day] {
                        for i in 0..<min(existing.count, minutes.count) { existing[i].add(minutes[i]) }
                        merged[day] = existing
                    } else {
                        merged[day] = minutes
                    }
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .utility)) { completion(merged) }
    }

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
