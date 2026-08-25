import Foundation

/// A reporting granularity. Storage is period-agnostic; this enum lives only in the
/// analysis layer — the same archived records are bucketed into days, weeks, or
/// months at read time, under the current timezone (like every other view).
enum ReportPeriod: String, Codable, CaseIterable, Identifiable {
    case day, week, month, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .all: return "All"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .all: return .era      // never stepped; `.all` has a single unbounded range
        }
    }

    /// The half-open [start, end) interval of the period containing `date`.
    /// `.all` is one unbounded range — every date falls in it, so the navigator's
    /// forward step stays disabled and the report path takes the live-today branch.
    func range(containing date: Date, calendar: Calendar = .current) -> PeriodRange {
        if self == .all {
            return PeriodRange(period: .all, start: .distantPast, end: .distantFuture, calendar: calendar)
        }
        let interval = calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: date, duration: 86_400)
        return PeriodRange(period: self, start: interval.start, end: interval.end, calendar: calendar)
    }

    /// The period immediately before `range`.
    func previous(_ range: PeriodRange, calendar: Calendar = .current) -> PeriodRange {
        let before = calendar.date(byAdding: component, value: -1, to: range.start) ?? range.start
        return self.range(containing: before, calendar: calendar)
    }

    /// The period immediately after `range`.
    func next(_ range: PeriodRange, calendar: Calendar = .current) -> PeriodRange {
        self.range(containing: range.end.addingTimeInterval(1), calendar: calendar)
    }
}

/// A concrete period instance: its half-open date interval plus display strings and
/// the archive segments it spans.
struct PeriodRange: Equatable {
    let period: ReportPeriod
    let start: Date
    let end: Date            // exclusive
    let key: String          // stable id: "2026-06-27" / "2026-W26" / "2026-06"
    let title: String        // human: "Jun 27, 2026" / "Jun 22 – Jun 28, 2026" / "June 2026"

    init(period: ReportPeriod, start: Date, end: Date, calendar: Calendar) {
        self.period = period
        self.start = start
        self.end = end
        self.key = PeriodRange.makeKey(period, start: start, calendar: calendar)
        self.title = PeriodRange.makeTitle(period, start: start, end: end, calendar: calendar)
    }

    func contains(_ date: Date) -> Bool { date >= start && date < end }
    func contains(epoch: Int) -> Bool { contains(Date(timeIntervalSince1970: TimeInterval(epoch))) }

    /// Calendar-day count in the period (7 for a week, 28–31 for a month, 1 for a day).
    func dayCount(calendar: Calendar = .current) -> Int {
        max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
    }

    /// Archive segments ("YYYY-MM") to read for a report on this period: from the
    /// previous period's start (needed for the comparison) through this period's end,
    /// which folds in the next month as slack for a timezone shift after ingest.
    /// `.all` spans the whole archive — the caller must use the archive's own month
    /// list instead of spanning this range's unbounded dates.
    func segmentsToRead(calendar: Calendar = .current) -> [String] {
        guard period != .all else { return [] }
        let prior = period.previous(self, calendar: calendar)
        return DayBucket.monthsSpanning(from: prior.start, to: end, calendar: calendar)
    }

    // MARK: - Display

    private static func makeKey(_ period: ReportPeriod, start: Date, calendar: Calendar) -> String {
        switch period {
        case .day:   return DayBucket.dayKey(start, calendar: calendar)
        case .month: return DayBucket.monthKey(start, calendar: calendar)
        case .week:
            let week = calendar.component(.weekOfYear, from: start)
            let year = calendar.component(.yearForWeekOfYear, from: start)
            return String(format: "%04d-W%02d", year, week)
        case .all:   return "all"
        }
    }

    private static func makeTitle(_ period: ReportPeriod, start: Date, end: Date, calendar: Calendar) -> String {
        switch period {
        case .day:   return formatter("MMM d, yyyy", calendar).string(from: start)
        case .month: return formatter("LLLL yyyy", calendar).string(from: start)
        case .week:
            let lastDay = end.addingTimeInterval(-1)
            return formatter("MMM d", calendar).string(from: start)
                + " – " + formatter("MMM d, yyyy", calendar).string(from: lastDay)
        case .all:   return "All Time"
        }
    }

    private static func formatter(_ template: String, _ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = template
        return f
    }
}
