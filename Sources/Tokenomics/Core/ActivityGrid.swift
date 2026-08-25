import Foundation

/// The activity heatmap's grid (GitHub-contribution style): 53 week columns — 52
/// full weeks back plus the current one — × 7 weekday rows, each cell one calendar
/// day with its token total bucketed into five intensity levels. Pure: derived from
/// the daily series under the given calendar, so the view just paints it.
struct ActivityGrid: Equatable {
    struct Cell: Equatable {
        let day: String         // ISO day key, "2026-06-04"
        let tokens: Int
        let level: Int          // 0 (none) … 4 (top quartile of active days)
    }

    /// `columns[week][row]` walking the window oldest→current, each column one week
    /// starting on the calendar's first weekday. nil = a day after today (the
    /// current week's unplayed tail).
    let columns: [[Cell?]]
    /// Row index → weekday letter for the labeled rows (Mon / Wed / Fri), else nil.
    let rowLabels: [String?]
    /// Column index → month label ("Jun") where a month's 1st falls in the column.
    let monthLabels: [Int: String]

    static let weekCount = 53

    /// Quartile thresholds over the window's ACTIVE days decide the four nonzero
    /// levels, so the ramp always spreads across the user's own range — a heavy
    /// user's quiet day and a light user's big day both read correctly.
    static func make(days: [DailyUsage], now: Date, calendar: Calendar = .current) -> ActivityGrid {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let gridStart = calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: weekStart) ?? weekStart

        var tokens: [String: Int] = [:]
        for day in days { tokens[day.date] = day.totalTokens }

        let startKey = DayBucket.dayKey(gridStart, calendar: calendar)
        let active = tokens.filter { $0.key >= startKey && $0.value > 0 }.values.sorted()
        func quartile(_ p: Double) -> Int {
            guard !active.isEmpty else { return 0 }
            return active[Int(Double(active.count - 1) * p)]
        }
        let q1 = quartile(0.25), q2 = quartile(0.5), q3 = quartile(0.75)
        let top = active.last ?? 0
        func level(_ v: Int) -> Int {
            guard v > 0 else { return 0 }
            // The window maximum always paints darkest — with few or uniform
            // active days the quartiles collapse onto one value and the plain
            // bucket walk would leave even the busiest day at the faintest step.
            if v >= top { return 4 }
            if v <= q1 { return 1 }
            if v <= q2 { return 2 }
            if v <= q3 { return 3 }
            return 4
        }

        var columns: [[Cell?]] = []
        var monthLabels: [Int: String] = [:]
        for week in 0..<weekCount {
            var column: [Cell?] = []
            for row in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: week * 7 + row, to: gridStart),
                      date <= today
                else { column.append(nil); continue }
                let key = DayBucket.dayKey(date, calendar: calendar)
                column.append(Cell(day: key, tokens: tokens[key] ?? 0, level: level(tokens[key] ?? 0)))
                if calendar.component(.day, from: date) == 1 {
                    monthLabels[week] = Format.shortMonth(String(key.prefix(7)))
                }
            }
            columns.append(column)
        }

        // Weekday letters for the Mon/Wed/Fri rows, fixed-English like the rest of
        // the UI. Row order follows the calendar's first weekday.
        let letters = ["S", "M", "T", "W", "T", "F", "S"]        // 1 = Sunday
        let labeled: Set<Int> = [2, 4, 6]                        // Mon, Wed, Fri
        var rowLabels: [String?] = []
        for row in 0..<7 {
            let weekday = (calendar.firstWeekday - 1 + row) % 7 + 1
            rowLabels.append(labeled.contains(weekday) ? letters[weekday - 1] : nil)
        }

        return ActivityGrid(columns: columns, rowLabels: rowLabels, monthLabels: monthLabels)
    }
}
