import Foundation

/// App-wide on-disk identity. One place for the bundle id and the two base
/// directories so the parse cache, device identity, peer files, and the durable
/// archive can't drift apart (the id used to be hardcoded in several spots).
enum AppPaths {
    /// Reverse-DNS app id; the subdirectory name under Caches / Application Support.
    static let bundleID = "me.stfang.tokenomics"

    /// `~/Library/Caches/me.stfang.tokenomics[/sub]`, created on demand. The OS may
    /// purge this under disk pressure — only for regenerable data (the parse cache).
    static func caches(_ subdirectory: String? = nil) -> URL? {
        directory(for: .cachesDirectory, subdirectory: subdirectory)
    }

    /// `~/Library/Application Support/me.stfang.tokenomics[/sub]`, created on demand.
    /// Durable: survives a Caches purge. Use for data we must not lose (the device
    /// id, the archive). nil only if Application Support is unreachable, so callers
    /// degrade rather than crash.
    static func applicationSupport(_ subdirectory: String? = nil) -> URL? {
        directory(for: .applicationSupportDirectory, subdirectory: subdirectory)
    }

    private static func directory(for base: FileManager.SearchPathDirectory, subdirectory: String?) -> URL? {
        guard let root = FileManager.default.urls(for: base, in: .userDomainMask).first else { return nil }
        var dir = root.appendingPathComponent(bundleID, isDirectory: true)
        if let subdirectory { dir = dir.appendingPathComponent(subdirectory, isDirectory: true) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
