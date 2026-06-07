import Testing
import Foundation
@testable import Tokenomics

/// Tests for `LineReader.forEachLine(of:chunkSize:_:)`.
///
/// Each test writes its own temp file under a unique UUID path so the
/// suite is safe under swift-testing's parallel execution, and cleans up
/// in a `defer` so no temp files leak even if an assertion throws.
@Suite("LineReader")
struct LineReaderTests {

    /// Writes `data` to a fresh unique temp file and returns its URL.
    /// The caller is responsible for removing it (use a `defer`).
    private func makeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    /// Collects every line `LineReader` delivers, decoded as UTF-8 strings.
    private func collectLines(from url: URL, chunkSize: Int = 1 << 16) -> [String] {
        var lines: [String] = []
        LineReader.forEachLine(of: url, chunkSize: chunkSize) { data in
            lines.append(String(decoding: data, as: UTF8.self))
        }
        return lines
    }

    @Test("delivers each newline-separated line in order")
    func multipleLines() throws {
        // Arrange
        let url = try makeTempFile(Data("alpha\nbeta\ngamma\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        // Act
        let lines = collectLines(from: url)

        // Assert
        #expect(lines == ["alpha", "beta", "gamma"])
    }

    @Test("delivers a final line that has no trailing newline")
    func finalLineWithoutNewline() throws {
        // Arrange
        let url = try makeTempFile(Data("first\nsecond\nlast-no-newline".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        // Act
        let lines = collectLines(from: url)

        // Assert
        #expect(lines == ["first", "second", "last-no-newline"])
    }

    @Test("skips empty lines produced by consecutive newlines")
    func skipsEmptyLines() throws {
        // Arrange: blank lines between and around real content.
        // The source guards with `if !line.isEmpty { handle(line) }`, so
        // empty lines must never reach the handler.
        let url = try makeTempFile(Data("\none\n\n\ntwo\n\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        // Act
        let lines = collectLines(from: url)

        // Assert
        #expect(lines == ["one", "two"])
    }

    @Test("an entirely empty file yields no lines")
    func emptyFileYieldsNothing() throws {
        // Arrange
        let url = try makeTempFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }

        // Act
        let lines = collectLines(from: url)

        // Assert
        #expect(lines.isEmpty)
    }

    @Test("a file of only newlines yields no lines")
    func onlyNewlinesYieldsNothing() throws {
        // Arrange
        let url = try makeTempFile(Data("\n\n\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        // Act
        let lines = collectLines(from: url)

        // Assert
        #expect(lines.isEmpty)
    }

    @Test("delivers a single line longer than the chunk size intact")
    func longLineSpanningChunks() throws {
        // Arrange: a single line that exceeds the 64KB default chunk size,
        // so the reader must reassemble it across multiple chunk reads via
        // its `leftover` carry-over buffer.
        let chunkSize = 1 << 16            // 65536, the production default
        let longLength = chunkSize * 3 + 7 // spans several chunks, not chunk-aligned
        let longLine = String(repeating: "x", count: longLength)
        let url = try makeTempFile(Data((longLine + "\n").utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        // Act
        let lines = collectLines(from: url, chunkSize: chunkSize)

        // Assert
        let delivered = try #require(lines.first)
        #expect(lines.count == 1)
        #expect(delivered.count == longLength)
        #expect(delivered == longLine)
    }

    @Test("delivers a long line with no trailing newline intact")
    func longLineNoTrailingNewline() throws {
        // Arrange: exercise both the multi-chunk carry-over AND the
        // final-leftover delivery path at once.
        let chunkSize = 1 << 16
        let longLength = chunkSize * 2 + 123
        let longLine = String(repeating: "y", count: longLength)
        let url = try makeTempFile(Data(longLine.utf8)) // no trailing newline
        defer { try? FileManager.default.removeItem(at: url) }

        // Act
        let lines = collectLines(from: url, chunkSize: chunkSize)

        // Assert
        let delivered = try #require(lines.first)
        #expect(lines.count == 1)
        #expect(delivered == longLine)
    }

    @Test("a missing file yields no lines and does not crash")
    func missingFile() {
        // Arrange: a path that was never created.
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        // Act
        let lines = collectLines(from: url)

        // Assert
        #expect(lines.isEmpty)
    }
}
