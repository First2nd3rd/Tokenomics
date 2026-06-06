import Foundation

/// Reads a file line-by-line without loading the whole file into memory: it pulls
/// fixed-size chunks, hands off each complete newline-terminated line, and keeps
/// only the trailing partial line for the next chunk. Peak memory is bounded by
/// the chunk size plus the longest single line — independent of file size, which
/// matters when scanning multi-GB JSONL logs.
enum LineReader {
    static func forEachLine(of url: URL, chunkSize: Int = 1 << 16, _ handle: (Data) -> Void) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }

        let newline: UInt8 = 0x0A
        var buffer = Data()
        var reachedEOF = false

        while !reachedEOF {
            // The whole iteration — including the read — must be inside the pool: the
            // Data returned by read(upToCount:) is autoreleased, so reading outside
            // would pile every 64KB chunk into the outer pool across a multi-GB scan.
            autoreleasepool {
                guard let chunk = (try? file.read(upToCount: chunkSize)) ?? nil, !chunk.isEmpty else {
                    reachedEOF = true
                    return
                }
                buffer.append(chunk)

                var lineStart = buffer.startIndex
                while let newlineIndex = buffer[lineStart...].firstIndex(of: newline) {
                    if newlineIndex > lineStart {
                        handle(buffer.subdata(in: lineStart..<newlineIndex))
                    }
                    lineStart = buffer.index(after: newlineIndex)
                }
                if lineStart > buffer.startIndex {
                    buffer = buffer.subdata(in: lineStart..<buffer.endIndex)
                }
            }
        }

        if !buffer.isEmpty { handle(buffer) }   // final line, no trailing newline
    }
}
