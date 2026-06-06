import Foundation

/// Reads a file line-by-line without loading the whole file into memory: it pulls
/// fixed-size chunks, hands off each complete newline-terminated line, and keeps
/// only the trailing partial line for the next chunk. Peak memory is bounded by
/// the chunk size plus the longest single line.
///
/// Newlines are searched only within each freshly-read chunk — the carried-over
/// `leftover` is known to contain none — so the whole scan is O(total bytes),
/// not O(line length²). That matters for Codex rollout logs, whose lines can be
/// multiple megabytes (embedded image/screenshot base64).
enum LineReader {
    static func forEachLine(of url: URL, chunkSize: Int = 1 << 16, _ handle: (Data) -> Void) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }

        let newline: UInt8 = 0x0A
        var leftover = Data()       // partial line carried across chunks; contains no newline
        var reachedEOF = false

        while !reachedEOF {
            // The read must be inside the pool too: read(upToCount:) returns an
            // autoreleased Data, which would otherwise pile up across a huge scan.
            autoreleasepool {
                guard let chunk = (try? file.read(upToCount: chunkSize)) ?? nil, !chunk.isEmpty else {
                    reachedEOF = true
                    return
                }
                var cursor = chunk.startIndex
                while let newlineIndex = chunk[cursor...].firstIndex(of: newline) {
                    var line = leftover
                    line.append(chunk[cursor..<newlineIndex])
                    if !line.isEmpty { handle(line) }
                    leftover = Data()
                    cursor = chunk.index(after: newlineIndex)
                }
                if cursor < chunk.endIndex {
                    leftover.append(chunk[cursor...])
                }
            }
        }

        if !leftover.isEmpty { handle(leftover) }   // final line, no trailing newline
    }
}
