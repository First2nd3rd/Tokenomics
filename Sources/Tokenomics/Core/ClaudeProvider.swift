import Foundation

/// Reads Claude Code usage by shelling out to `ccusage daily --json`.
/// (v2 may replace this with a native JSONL reader to drop the Node dependency.)
final class ClaudeProvider: UsageProvider {
    let id = "claude"

    func fetchDaily(completion: @escaping (Result<[DailyUsage], Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try Self.runCCUsage()
                let decoded = try JSONDecoder().decode(CCUsageResponse.self, from: data)
                let days = decoded.daily.map { $0.normalized() }
                completion(.success(days))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Run through a login shell so the global npm bin (e.g. /opt/homebrew/bin)
    /// is on PATH even when the app is launched from Finder, not a terminal.
    private static func runCCUsage() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "ccusage daily --json"]

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ProviderError.commandFailed(status: process.terminationStatus)
        }
        return data
    }
}

enum ProviderError: LocalizedError {
    case commandFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let status):
            return "ccusage failed (exit \(status))"
        }
    }
}

// MARK: - ccusage JSON shape (only the fields we use)

private struct CCUsageResponse: Decodable {
    let daily: [CCUsageDay]
}

private struct CCUsageDay: Decodable {
    let period: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let totalCost: Double
    let modelsUsed: [String]

    func normalized() -> DailyUsage {
        DailyUsage(
            date: period,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            totalTokens: totalTokens,
            totalCost: totalCost,
            models: modelsUsed
        )
    }
}
