import Foundation

/// This Mac's identity for cross-machine aggregation.
///
/// `id` is a random UUID minted once and persisted in an app-private file — NOT a
/// hardware fingerprint. Correctness never depends on it (record-level `Dedup`
/// handles duplicates), so a regenerated id only relabels the "by machine" view; it
/// can never cause double-counting.
enum DeviceIdentity {

    /// Stable per-install machine id (random UUID, persisted once).
    static let id: String = loadOrCreateID(at: idFileURL)

    static let displayNameKey = "machineDisplayName"

    /// Human label for this Mac: the user's override if set, else the computer name.
    static func displayName(_ defaults: UserDefaults = .standard) -> String {
        if let custom = defaults.string(forKey: displayNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return Host.current().localizedName ?? "This Mac"
    }

    // MARK: - Persistence

    /// App-private file holding the minted id. Lives in Application Support (not
    /// Caches), so clearing the parse cache doesn't churn the machine's identity.
    static var idFileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("me.stfang.tokenomics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("machine-id")
    }

    /// Read the id from `url`, minting + writing a fresh UUID if it's absent or empty.
    /// With `url == nil` (Application Support unreachable) returns a fresh UUID so the
    /// app degrades rather than crashes.
    static func loadOrCreateID(at url: URL?) -> String {
        guard let url else { return UUID().uuidString }
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let fresh = UUID().uuidString
        try? fresh.data(using: .utf8)?.write(to: url, options: .atomic)
        return fresh
    }
}
