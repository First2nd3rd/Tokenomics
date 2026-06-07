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

/// One bucket (minute / 5-min) holding token counts split by type AND a per-model
/// total — enough to drive the line, by-type, and by-model rate charts.
struct MinuteBucket {
    var counts = TokenCounts()
    var byModel: [String: Int] = [:]

    mutating func add(input i: Int, output o: Int, cacheCreation cc: Int, cacheRead cr: Int, model: String?) {
        counts.add(input: i, output: o, cacheCreation: cc, cacheRead: cr)
        if let model { byModel[model, default: 0] += i + o + cc + cr }
    }

    mutating func add(_ other: MinuteBucket) {
        counts.add(other.counts)
        for (model, value) in other.byModel { byModel[model, default: 0] += value }
    }
}
