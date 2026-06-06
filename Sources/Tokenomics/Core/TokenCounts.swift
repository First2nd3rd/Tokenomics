import Foundation

/// Token counts split by type for one bucket (minute/day). `total` is their sum.
struct TokenCounts {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0

    var total: Int { input + output + cacheCreation + cacheRead }

    mutating func add(input i: Int, output o: Int, cacheCreation cc: Int, cacheRead cr: Int) {
        input += i
        output += o
        cacheCreation += cc
        cacheRead += cr
    }

    mutating func add(_ other: TokenCounts) {
        input += other.input
        output += other.output
        cacheCreation += other.cacheCreation
        cacheRead += other.cacheRead
    }
}
