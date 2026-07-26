import SwiftUI

/// Drives the report window: the selected granularity + period, and the loaded
/// `PeriodReport`. Data loading is injected (AppDelegate wires it to `UsageStore`),
/// so the model stays decoupled from storage. Updated on the main queue (the loader
/// delivers there), mirroring `DashboardModel`.
final class ReportModel: ObservableObject {
    @Published var period: ReportPeriod = .month { didSet { anchor = Date(); reload() } }
    @Published private(set) var anchor = Date()
    @Published private(set) var report: PeriodReport?
    @Published private(set) var isLoading = false
    /// Whether sync is on — the report is this-Mac-only, so the view notes the gap.
    @Published var syncOn = false

    private let loader: (ReportPeriod, Date, @escaping (PeriodReport?) -> Void) -> Void

    init(loader: @escaping (ReportPeriod, Date, @escaping (PeriodReport?) -> Void) -> Void) {
        self.loader = loader
    }

    /// "Next" is disabled once the shown period already contains today.
    var canStepForward: Bool {
        !period.range(containing: anchor).contains(Date())
    }

    /// Loads run on a concurrent queue and can finish out of order (rapid period
    /// stepping); the generation stamp drops completions for superseded requests
    /// so a slow older load can't overwrite a newer period's data.
    private var generation = 0

    func reload() {
        generation += 1
        let requested = generation
        isLoading = true
        loader(period, anchor) { [weak self] report in
            guard let self, self.generation == requested else { return }
            self.report = report
            self.isLoading = false
        }
    }

    /// Move by whole periods (−1 = previous, +1 = next). Won't step into the future.
    func step(_ delta: Int) {
        if delta > 0 && !canStepForward { return }
        anchor = Calendar.current.date(byAdding: period.component, value: delta, to: anchor) ?? anchor
        reload()
    }
}
