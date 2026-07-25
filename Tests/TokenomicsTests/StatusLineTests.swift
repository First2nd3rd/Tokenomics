import Testing
@testable import Tokenomics

@Suite("StatusLine menu-bar lines")
struct StatusLineTests {

    @Test("shows the live increment while usage is flowing")
    func liveDelta() {
        let lines = StatusLine.make(totalTokens: 259_100_000, cost: 326.34, delta: 1_234_000)
        #expect(lines.top == "259.1M")
        #expect(lines.bottom == "+1.2M")
    }

    @Test("falls back to cost when nothing new arrived")
    func idleShowsCost() {
        let lines = StatusLine.make(totalTokens: 259_100_000, cost: 326.34, delta: 0)
        #expect(lines.bottom == "$326")
        #expect(StatusLine.make(totalTokens: 1_000, cost: 3.276, delta: nil).bottom == "$3.28")
    }

    @Test("a recount shrinking the total reads as idle, not a negative delta")
    func negativeDeltaShowsCost() {
        let lines = StatusLine.make(totalTokens: 100_000, cost: 12.34, delta: -5_000)
        #expect(lines.bottom == "$12.3")
    }

    @Test("no data yet renders a bare placeholder")
    func noData() {
        let lines = StatusLine.make(totalTokens: nil, cost: nil, delta: nil)
        #expect(lines.top == "—")
        #expect(lines.bottom.isEmpty)
    }
}

@Suite("Format.costCompact")
struct CostCompactTests {

    @Test("keeps only the digits that matter at each magnitude")
    func magnitudes() {
        #expect(Format.costCompact(3.276) == "$3.28")
        #expect(Format.costCompact(32.61) == "$32.6")
        #expect(Format.costCompact(326.34) == "$326")
        #expect(Format.costCompact(0) == "$0.00")
        #expect(Format.costCompact(41.02) == "$41")
    }
}
