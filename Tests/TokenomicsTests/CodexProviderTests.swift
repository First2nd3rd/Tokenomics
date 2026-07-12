import Testing
import Foundation
@testable import Tokenomics

@Suite("CodexProvider parsing")
struct CodexProviderTests {

    private func write(_ lines: [String]) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-test-\(UUID().uuidString).jsonl")
        try? lines.joined(separator: "\n").appending("\n").data(using: .utf8)!.write(to: url)
        return url
    }

    private func tokenCount(total: (i: Int, c: Int, o: Int), last: (i: Int, c: Int, o: Int)? = nil,
                            ts: String = "2026-07-11T04:00:00Z") -> String {
        var info = #""total_token_usage":{"input_tokens":\#(total.i),"cached_input_tokens":\#(total.c),"output_tokens":\#(total.o)}"#
        if let last {
            info += #","last_token_usage":{"input_tokens":\#(last.i),"cached_input_tokens":\#(last.c),"output_tokens":\#(last.o)}"#
        }
        return #"{"type":"event_msg","timestamp":"\#(ts)","payload":{"type":"token_count","info":{\#(info)}}}"#
    }

    @Test("counts per-turn usage from last_token_usage")
    func perTurnUsage() {
        let file = write([
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            tokenCount(total: (1000, 800, 50), last: (1000, 800, 50)),
            tokenCount(total: (1600, 1200, 80), last: (600, 400, 30)),
        ])
        let records = CodexProvider.parseFile(file)
        #expect(records.count == 2)
        #expect(records[0].input == 200)       // 1000 − 800 cached
        #expect(records[0].cacheRead == 800)
        #expect(records[0].output == 50)
        #expect(records[1].input == 200)       // 600 − 400
        #expect(records[1].cacheRead == 400)
        #expect(records[1].output == 30)
        #expect(records.allSatisfy { $0.model == "gpt-5.6-sol" })
    }

    @Test("counts a sub-turn that does NOT advance the session cumulative")
    func subTurnNotInCumulative() {
        // Second event: a parallel review thread reports last_token_usage while the
        // cumulative stays put — the old delta logic counted this as zero.
        let file = write([
            tokenCount(total: (1000, 800, 50), last: (1000, 800, 50)),
            tokenCount(total: (1000, 800, 50), last: (500, 400, 20)),
        ])
        let records = CodexProvider.parseFile(file)
        #expect(records.count == 2)
        #expect(records[1].input == 100)       // 500 − 400, not 0
        #expect(records[1].cacheRead == 400)
        #expect(records[1].output == 20)
    }

    @Test("falls back to cumulative deltas for old rollouts without last_token_usage")
    func cumulativeFallback() {
        let file = write([
            tokenCount(total: (100, 0, 10)),
            tokenCount(total: (300, 100, 25)),
        ])
        let records = CodexProvider.parseFile(file)
        #expect(records.count == 2)
        #expect(records[0].input == 100)
        #expect(records[0].output == 10)
        #expect(records[1].input == 100)       // Δinput 200 − Δcached 100
        #expect(records[1].cacheRead == 100)
        #expect(records[1].output == 15)
    }

    @Test("skips a literally re-emitted token_count (double-logged turn)")
    func skipsDuplicateEvent() {
        let dup = tokenCount(total: (1000, 800, 50), last: (500, 400, 20), ts: "2026-07-12T01:04:52Z")
        let file = write([
            tokenCount(total: (500, 400, 30), last: (500, 400, 30)),
            dup,
            dup,   // identical timestamp + counts: the same turn logged twice
        ])
        let records = CodexProvider.parseFile(file)
        #expect(records.count == 2)
        #expect(records.map(\.output) == [30, 20])
    }

    @Test("counts two turns that differ only in the cumulative (not duplicates)")
    func distinctTurnsSameShape() {
        // Same per-turn shape and timestamp, but the cumulative advanced — two real
        // turns, both kept.
        let file = write([
            tokenCount(total: (500, 400, 20), last: (500, 400, 20), ts: "2026-07-12T01:04:52Z"),
            tokenCount(total: (1000, 800, 40), last: (500, 400, 20), ts: "2026-07-12T01:04:52Z"),
        ])
        #expect(CodexProvider.parseFile(file).count == 2)
    }

    @Test("events before the first turn_context inherit the session's model")
    func preContextEventsGetSessionModel() {
        let file = write([
            tokenCount(total: (100, 0, 10), last: (100, 0, 10)),   // before any turn_context
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            tokenCount(total: (200, 0, 20), last: (100, 0, 10)),
        ])
        let records = CodexProvider.parseFile(file)
        #expect(records.count == 2)
        #expect(records.map(\.model) == ["gpt-5.6-sol", "gpt-5.6-sol"])
    }

    @Test("skips the spawn-second replay block of a forked/sub-agent session")
    func skipsForkReplayBlock() {
        let file = write([
            #"{"type":"session_meta","payload":{"id":"s1","forked_from_id":"parent-id","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-id"}}}}}"#,
            // Replayed parent history: hundreds of events stamped in ONE second.
            tokenCount(total: (1000, 800, 50), last: (1000, 800, 50), ts: "2026-07-12T01:34:05.055Z"),
            tokenCount(total: (2000, 1600, 90), last: (1000, 800, 40), ts: "2026-07-12T01:34:05.064Z"),
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            // Real work starts seconds later.
            tokenCount(total: (2500, 2000, 120), last: (500, 400, 30), ts: "2026-07-12T01:34:23.529Z"),
        ])
        let records = CodexProvider.parseFile(file)
        #expect(records.count == 1)
        #expect(records[0].output == 30)
        #expect(records[0].cacheRead == 400)
        #expect(records[0].model == "gpt-5.6-sol")
    }

    @Test("does not replay-skip an ordinary session with same-second events")
    func noSkipWithoutForkMarkers() {
        let file = write([
            #"{"type":"session_meta","payload":{"id":"s1"}}"#,
            tokenCount(total: (1000, 800, 50), last: (1000, 800, 50), ts: "2026-07-12T01:34:05.055Z"),
            tokenCount(total: (2000, 1600, 90), last: (1000, 800, 40), ts: "2026-07-12T01:34:05.064Z"),
        ])
        #expect(CodexProvider.parseFile(file).count == 2)
    }

    @Test("per-event keys are stable and distinct")
    func stableKeys() {
        let file = write([
            tokenCount(total: (100, 0, 10), last: (100, 0, 10)),
            tokenCount(total: (200, 0, 20), last: (100, 0, 10)),
        ])
        let records = CodexProvider.parseFile(file)
        #expect(records.count == 2)
        #expect(records[0].key != nil)
        #expect(records[0].key != records[1].key)
        // Same file parsed twice → identical keys (cross-machine dedup identity).
        #expect(CodexProvider.parseFile(file).map(\.key) == records.map(\.key))
    }
}
