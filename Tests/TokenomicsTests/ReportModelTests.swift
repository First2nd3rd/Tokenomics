import Testing
import Foundation
@testable import Tokenomics

@Suite("ReportModel")
struct ReportModelTests {

    private func makeReport(_ period: ReportPeriod, tokens: Int) -> PeriodReport {
        let record = UsageRecord(source: .claude, key: "r", epoch: Int(Date().timeIntervalSince1970),
                                 input: tokens, output: 0, cacheCreation: 0, cacheRead: 0, model: "m")
        return PeriodReport.make(records: [record], period: period, anchor: Date())
    }

    @Test("switching back to a period shows its last report instantly, then refreshes")
    func cachedSwitchIsInstant() {
        // A loader whose completions the test controls.
        var pending: [(ReportPeriod, (PeriodReport?) -> Void)] = []
        let model = ReportModel { period, _, done in pending.append((period, done)) }

        // First month load completes normally.
        model.reload()
        #expect(pending.count == 1)
        let monthReport = makeReport(.month, tokens: 100)
        pending[0].1(monthReport)
        #expect(model.report?.total.total == 100)

        // Switch to week (its load stays pending — nothing cached for week).
        model.period = .week
        #expect(model.isLoading)

        // Switch back to month: the cached report shows IMMEDIATELY, while a
        // fresh build is still in flight.
        model.period = .month
        #expect(model.report?.total.total == 100)
        #expect(model.isLoading)

        // The fresh build lands and replaces it.
        let fresh = makeReport(.month, tokens: 150)
        pending.last?.1(fresh)
        #expect(model.report?.total.total == 150)
        #expect(!model.isLoading)
    }

    @Test("a superseded load can not overwrite a newer period's report")
    func staleCompletionDropped() {
        var pending: [(ReportPeriod, (PeriodReport?) -> Void)] = []
        let model = ReportModel { period, _, done in pending.append((period, done)) }

        model.reload()                       // month (default), stays in flight
        model.period = .day                  // supersedes it
        pending[0].1(makeReport(.month, tokens: 999))   // old completion arrives late

        #expect(model.report == nil)         // dropped — day's load still owns the screen
        #expect(model.isLoading)
    }
}
