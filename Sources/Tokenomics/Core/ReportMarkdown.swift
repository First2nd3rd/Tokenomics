import Foundation

/// Renders a `PeriodReport` as Markdown — for copy-to-clipboard from the report
/// window and for `--dump-archive`. Pure and deterministic given the report, so it
/// is easy to test and the same text drives both paths.
enum ReportMarkdown {
    static func make(_ r: PeriodReport, syncOn: Bool = false) -> String {
        var out = "# Usage Report — \(r.title)\n\n"

        out += "**\(Format.tokensShort(r.total.total)) tokens · \(Format.cost(r.cost))**"
        if let delta = Format.deltaPct(r.total.total, vs: r.previousTokens) {
            out += "  (\(delta) vs previous \(r.period.label.lowercased()))"
        }
        out += "\n"
        if let pt = r.projectedTokens, let pc = r.projectedCost {
            out += "Projected ~\(Format.tokensShort(pt)) · ~\(Format.cost(pc))\n"
        }

        var notes = ["This Mac"]
        if !r.pricesFrozen { notes.append("estimated at current prices") }
        if syncOn { notes.append("excludes other Macs") }
        out += "_\(notes.joined(separator: " · "))_\n"

        if !r.byVendor.isEmpty {
            out += "\n## By vendor\n\n| Vendor | Tokens | Cost |\n| --- | ---: | ---: |\n"
            for v in r.byVendor {
                out += "| \(v.vendor) | \(Format.tokensShort(v.tokens)) | \(Format.cost(v.cost)) |\n"
            }
        }

        if !r.byModel.isEmpty {
            out += "\n## By model\n\n| Model | Tokens | Cost |\n| --- | ---: | ---: |\n"
            for m in r.byModel {
                out += "| \(m.model) | \(Format.tokensShort(m.tokens)) | \(Format.cost(m.cost)) |\n"
            }
        }

        // All time rolls the (long) daily series up into months; the period views
        // keep their day-by-day table.
        if let months = r.months, !months.isEmpty {
            out += "\n## Monthly\n\n| Month | Tokens | Cost |\n| --- | ---: | ---: |\n"
            for m in months {
                out += "| \(m.month) | \(Format.tokensShort(m.tokens)) | \(Format.cost(m.cost)) |\n"
            }
        } else if !r.days.isEmpty {
            out += "\n## Daily\n\n| Day | Tokens | Cost |\n| --- | ---: | ---: |\n"
            for d in r.days {
                out += "| \(d.date) | \(Format.tokensShort(d.totalTokens)) | \(Format.cost(d.totalCost)) |\n"
            }
        }

        out += "\n## Stats\n\n"
        out += "- Active days: \(r.activeDays) of \(r.totalDays)\n"
        out += "- Daily average: \(Format.tokensShort(r.dailyAverage))\n"
        if let busiest = r.busiestDay {
            out += "- Busiest day: \(Format.shortMonthDay(busiest.date)) · \(Format.tokensShort(busiest.totalTokens))\n"
        }
        out += "- Longest streak: \(r.longestStreak) day\(r.longestStreak == 1 ? "" : "s")\n"
        return out
    }
}
