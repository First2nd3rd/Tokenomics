import Foundation

/// Holds the current model→price map, layered from three sources (lowest to
/// highest precedence):
///   1. the bundled offline snapshot,
///   2. models.dev — catalogs new models within hours of release, filling gaps
///      until LiteLLM catches up (e.g. a just-launched Claude model),
///   3. LiteLLM — the primary source our per-day cost parity is verified against.
///
/// Reads are synchronous and lock-guarded so the reader — which prices each
/// message on a background queue — never has to await. Network refreshes happen
/// in the background and only when an on-disk cache is missing or stale, so the
/// price table self-updates for new models without shipping a new build.
final class PricingStore {
    static let shared = PricingStore()

    private static let liteLLMURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static let modelsDevURL = URL(string: "https://models.dev/api.json")!
    private static let cacheTTL: TimeInterval = 24 * 60 * 60   // refresh at most daily
    private static let liteLLMCacheFile = "litellm_prices.json"
    private static let modelsDevCacheFile = "modelsdev_prices.json"

    private let lock = NSLock()
    private var liteLLM: [String: ModelPricing] = [:]
    private var modelsDev: [String: ModelPricing] = [:]
    private var table: [String: ModelPricing] = [:]
    private var isFetching = false

    private init() {
        if let cached = Self.readCache(Self.liteLLMCacheFile) {
            liteLLM = Self.parseLiteLLM(cached) ?? [:]
        }
        if let cached = Self.readCache(Self.modelsDevCacheFile) {
            modelsDev = Self.parseModelsDev(cached) ?? [:]
        }
        table = Self.layered(modelsDev: modelsDev, liteLLM: liteLLM)
    }

    /// Bundled snapshot < models.dev < LiteLLM.
    static func layered(modelsDev: [String: ModelPricing],
                        liteLLM: [String: ModelPricing]) -> [String: ModelPricing] {
        Pricing.bundledSnapshot
            .merging(modelsDev) { _, newer in newer }
            .merging(liteLLM) { _, newer in newer }
    }

    /// Pricing for a model id (exact → "-fast" ×mult → prefix). Sync + thread-safe.
    func pricing(for model: String?) -> ModelPricing? {
        guard let model else { return nil }
        lock.lock(); defer { lock.unlock() }
        return Pricing.resolve(model, in: table)
    }

    /// Fetch fresh prices in the background for whichever caches are missing or
    /// older than the TTL. No-op while a fetch is already in flight or both are fresh.
    func refreshIfStale() {
        let liteLLMStale = Self.isStale(Self.liteLLMCacheFile)
        let modelsDevStale = Self.isStale(Self.modelsDevCacheFile)
        guard liteLLMStale || modelsDevStale else { return }

        // Claim the fetch under the lock so two callers can't both start one.
        lock.lock()
        if isFetching { lock.unlock(); return }
        isFetching = true
        lock.unlock()

        let group = DispatchGroup()
        if liteLLMStale {
            fetch(Self.liteLLMURL, into: Self.liteLLMCacheFile, group: group) { [weak self] parsed in
                self?.liteLLM = parsed
            }
        }
        if modelsDevStale {
            fetch(Self.modelsDevURL, into: Self.modelsDevCacheFile, group: group) { [weak self] parsed in
                self?.modelsDev = parsed
            }
        }
        group.notify(queue: .global(qos: .utility)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.table = Self.layered(modelsDev: self.modelsDev, liteLLM: self.liteLLM)
            self.isFetching = false
            self.lock.unlock()
        }
    }

    /// One background download: parse (by cache file identity), assign under the
    /// lock via `store`, and persist the raw bytes for the next cold start.
    private func fetch(_ url: URL, into cacheFile: String, group: DispatchGroup,
                       store: @escaping ([String: ModelPricing]) -> Void) {
        group.enter()
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            defer { group.leave() }
            guard let self, let data else { return }
            let parsed = cacheFile == Self.liteLLMCacheFile
                ? Self.parseLiteLLM(data) : Self.parseModelsDev(data)
            guard let parsed, !parsed.isEmpty else { return }
            self.lock.lock(); store(parsed); self.lock.unlock()
            Self.writeCache(data, to: cacheFile)
        }.resume()
    }

    // MARK: - Parsing (lenient: skip entries without a numeric input price)

    /// LiteLLM: flat `{model: {input_cost_per_token: …}}`, prices per TOKEN.
    static func parseLiteLLM(_ data: Data) -> [String: ModelPricing]? {
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

    /// models.dev: `{provider: {models: {id: {cost: {input, …}}}}}`, prices per
    /// MILLION tokens. Only the first-party providers we read logs for — vendor
    /// aggregators (openrouter, bedrock, …) duplicate the same models under
    /// prefixed ids and sometimes regional rates.
    static func parseModelsDev(_ data: Data) -> [String: ModelPricing]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let million = 1_000_000.0
        var out: [String: ModelPricing] = [:]
        for provider in ["anthropic", "openai"] {
            guard let entry = root[provider] as? [String: Any],
                  let models = entry["models"] as? [String: Any] else { continue }
            for (id, value) in models {
                guard let model = value as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = (cost["input"] as? NSNumber)?.doubleValue
                else { continue }
                out[id] = ModelPricing(
                    input: input / million,
                    output: ((cost["output"] as? NSNumber)?.doubleValue ?? 0) / million,
                    cacheCreation: ((cost["cache_write"] as? NSNumber)?.doubleValue ?? 0) / million,
                    cacheRead: ((cost["cache_read"] as? NSNumber)?.doubleValue ?? 0) / million
                )
            }
        }
        return out
    }

    // MARK: - Disk cache (~/Library/Caches/me.stfang.tokenomics/)

    private static func cacheURL(_ fileName: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = caches.appendingPathComponent("me.stfang.tokenomics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private static func readCache(_ fileName: String) -> Data? {
        guard let url = cacheURL(fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func writeCache(_ data: Data, to fileName: String) {
        guard let url = cacheURL(fileName) else { return }
        try? data.write(to: url)
    }

    /// Missing or older than the TTL.
    private static func isStale(_ fileName: String) -> Bool {
        guard let url = cacheURL(fileName),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) >= cacheTTL
    }
}
