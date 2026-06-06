import Foundation

/// One point on a cumulative chart line.
struct CumPoint: Identifiable {
    let id: Int          // minute-of-day (unique within its series)
    let hour: Double     // x position in hours
    let tokens: Int
}

/// Builds the cumulative chart's three lines from a day×minute matrix:
///   - today: actual cumulative up to "now"
///   - typical: average cumulative of prior days (a "normal day" reference)
///   - predicted: today's curve extended to end-of-day along the typical shape
/// All sampled at 5-minute resolution. Pure and deterministic.
enum IntradayCurve {
    /// Below this typical-cumulative fraction the projection is too unstable.
    private static let minFraction = 0.05

    struct Series {
        let today: [CumPoint]
        let typical: [CumPoint]
        let predicted: [CumPoint]
        let projectedTotal: Int?
    }

    static func build(matrix: [String: [TokenCounts]], now: Date, calendar: Calendar = .current) -> Series {
        let todayKey = DayBucket.dayKey(now, calendar: calendar)
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinute = min(1439, (comps.hour ?? 0) * 60 + (comps.minute ?? 0))

        let todayCum = prefixSum(matrix[todayKey] ?? Array(repeating: TokenCounts(), count: 1440))

        // Typical: average absolute cumulative + average normalized shape over prior days.
        var typicalAbs = [Double](repeating: 0, count: 1440)
        var fraction = [Double](repeating: 0, count: 1440)
        var dayCount = 0
        for (day, minutes) in matrix where day < todayKey {
            let cum = prefixSum(minutes)
            let total = cum[1439]
            guard total > 0 else { continue }
            dayCount += 1
            for m in 0..<1440 {
                typicalAbs[m] += Double(cum[m])
                fraction[m] += Double(cum[m]) / Double(total)
            }
        }
        let hasTypical = dayCount > 0
        if hasTypical {
            for m in 0..<1440 {
                typicalAbs[m] /= Double(dayCount)
                fraction[m] /= Double(dayCount)
            }
        }

        // Curve-based projection: today's total ÷ typical fraction completed by now.
        var projectedTotal: Double?
        if hasTypical, fraction[nowMinute] >= minFraction, todayCum[nowMinute] > 0 {
            projectedTotal = Double(todayCum[nowMinute]) / fraction[nowMinute]
        }

        var today: [CumPoint] = [], typical: [CumPoint] = [], predicted: [CumPoint] = []
        var m = 0
        while m <= 1439 {
            let h = Double(m) / 60.0
            if m <= nowMinute { today.append(CumPoint(id: m, hour: h, tokens: todayCum[m])) }
            if hasTypical { typical.append(CumPoint(id: m, hour: h, tokens: Int(typicalAbs[m]))) }
            if let total = projectedTotal, m >= nowMinute {
                predicted.append(CumPoint(id: m, hour: h, tokens: Int(total * fraction[m])))
            }
            m += 5
        }

        // Pin both lines to the exact current cumulative at "now" (5-min sampling can
        // stop a few minutes short, leaving the today line below the real total).
        let nowHour = Double(nowMinute) / 60.0
        if today.last?.id != nowMinute {
            today.append(CumPoint(id: nowMinute, hour: nowHour, tokens: todayCum[nowMinute]))
        }
        if projectedTotal != nil, predicted.first?.id != nowMinute {
            predicted.insert(CumPoint(id: nowMinute, hour: nowHour, tokens: todayCum[nowMinute]), at: 0)
        }

        return Series(today: today, typical: typical, predicted: predicted,
                      projectedTotal: projectedTotal.map(Int.init))
    }

    private static func prefixSum(_ values: [TokenCounts]) -> [Int] {
        var out = [Int](repeating: 0, count: values.count)
        var running = 0
        for i in values.indices { running += values[i].total; out[i] = running }
        return out
    }
}
