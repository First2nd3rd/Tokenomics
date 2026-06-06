import Foundation

/// Holds the current model→price map: the live LiteLLM table (fetched over the
/// network and cached on disk) layered over the bundled offline snapshot.
///
/// Reads are synchronous and lock-guarded so the reader — which prices each
/// message on a background queue — never has to await. Network refreshes happen
/// in the background and only when the on-disk cache is missing or stale, so the
/// price table self-updates for new models without shipping a new build.
final class PricingStore {
    static let shared = PricingStore()

    private static let sourceURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static let cacheTTL: TimeInterval = 24 * 60 * 60   // refresh at most daily
    private static let cacheFileName = "litellm_prices.json"

    private let lock = NSLock()
    private var table: [String: ModelPricing]
    private var isFetching = false

    private init() {
        var merged = Pricing.bundledSnapshot
        if let cached = Self.readCache(), let parsed = Self.parse(cached) {
            merged.merge(parsed) { _, live in live }
        }
        table = merged
    }

    /// Pricing for a model id (exact → "-fast" ×mult → prefix). Sync + thread-safe.
    func pricing(for model: String?) -> ModelPricing? {
        guard let model else { return nil }
        lock.lock(); defer { lock.unlock() }
        return Pricing.resolve(model, in: table)
    }

    /// Fetch fresh prices in the background when the cache is missing or older than
    /// the TTL. No-op while a fetch is already in flight or the cache is fresh.
    func refreshIfStale() {
        lock.lock()
        let alreadyFetching = isFetching
        lock.unlock()
        guard !alreadyFetching else { return }
        if let age = Self.cacheAge(), age < Self.cacheTTL { return }

        lock.lock(); isFetching = true; lock.unlock()
        URLSession.shared.dataTask(with: Self.sourceURL) { [weak self] data, _, _ in
            guard let self else { return }
            defer {
                self.lock.lock(); self.isFetching = false; self.lock.unlock()
            }
            guard let data, let parsed = Self.parse(data), !parsed.isEmpty else { return }
            self.lock.lock()
            self.table.merge(parsed) { _, live in live }
            self.lock.unlock()
            Self.writeCache(data)
        }.resume()
    }

    // MARK: - Parsing (lenient: skip entries without a numeric input price)

    private static func parse(_ data: Data) -> [String: ModelPricing]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: ModelPricing] = [:]
        for (name, value) in object {
            guard let entry = value as? [String: Any],
                  let input = (entry["input_cost_per_token"] as? NSNumber)?.doubleValue
            else { continue }
            out[name] = ModelPricing(
                input: input,
                output: (entry["output_cost_per_token"] as? NSNumber)?.doubleValue ?? 0,
                cacheCreation: (entry["cache_creation_input_token_cost"] as? NSNumber)?.doubleValue ?? 0,
                cacheRead: (entry["cache_read_input_token_cost"] as? NSNumber)?.doubleValue ?? 0
            )
        }
        return out
    }

    // MARK: - Disk cache (~/Library/Caches/me.stfang.tokenomics/)

    private static var cacheURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = caches.appendingPathComponent("me.stfang.tokenomics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(cacheFileName)
    }

    private static func readCache() -> Data? {
        guard let url = cacheURL else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func writeCache(_ data: Data) {
        guard let url = cacheURL else { return }
        try? data.write(to: url)
    }

    private static func cacheAge() -> TimeInterval? {
        guard let url = cacheURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }
}
