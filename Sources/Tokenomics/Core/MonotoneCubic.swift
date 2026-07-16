import Foundation

/// Fritsch–Carlson monotone cubic interpolation, evaluated into a dense polyline.
///
/// The dashboard's stacked area charts want smooth curves, but letting Swift Charts
/// curve the marks (`.monotone` etc.) makes a ZERO-valued stacked band paint a
/// hairline along the silhouette of the bands below it — a phantom series (see
/// `DashboardView.stackInterpolation`). So the smoothing happens here, in data
/// space: each band is resampled through a monotone cubic and rendered `.linear`.
///
/// Monotonicity is the property that makes this safe for stacked usage bands:
/// the curve never overshoots its control points, so non-negative data stays
/// non-negative, peaks keep their exact height, and — crucially — a run of zeros
/// stays EXACTLY zero at every dense sample (flat secant ⇒ zero tangents ⇒ the
/// Hermite segment is constant).
enum MonotoneCubic {

    /// The dense x grid: every control x, plus `subdivisions − 1` evenly spaced
    /// samples inside each interval. Control points are always included, so the
    /// resampled curve passes through the original data exactly.
    static func denseXs(_ xs: [Double], subdivisions: Int) -> [Double] {
        guard xs.count > 1, subdivisions > 1 else { return xs }
        var out: [Double] = []
        out.reserveCapacity((xs.count - 1) * subdivisions + 1)
        for i in 0..<(xs.count - 1) {
            let width = xs[i + 1] - xs[i]
            for k in 0..<subdivisions {
                out.append(xs[i] + width * Double(k) / Double(subdivisions))
            }
        }
        out.append(xs[xs.count - 1])
        return out
    }

    /// Evaluate the monotone cubic through `(xs, ys)` at `dense` (ascending,
    /// spanning the same range). `xs` must be strictly increasing and match `ys`.
    static func resample(xs: [Double], ys: [Double], at dense: [Double]) -> [Double] {
        let n = xs.count
        guard n == ys.count, n > 0 else { return [] }
        guard n > 2 else {
            // 1–2 points: linear is already exact.
            return dense.map { x in
                guard n == 2, xs[1] > xs[0] else { return ys[0] }
                let t = min(1, max(0, (x - xs[0]) / (xs[1] - xs[0])))
                return ys[0] + (ys[1] - ys[0]) * t
            }
        }

        let m = tangents(xs: xs, ys: ys)

        var out: [Double] = []
        out.reserveCapacity(dense.count)
        var i = 0
        for x in dense {
            while i < n - 2 && x >= xs[i + 1] { i += 1 }
            let h = xs[i + 1] - xs[i]
            let t = min(1, max(0, (x - xs[i]) / h))
            let t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            out.append(h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1])
        }
        return out
    }

    /// Fritsch–Carlson tangents: averaged secants, zeroed at local extrema and on
    /// flat intervals, then limited so each segment stays monotone.
    private static func tangents(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let h = xs[i + 1] - xs[i]
            d[i] = h > 0 ? (ys[i + 1] - ys[i]) / h : 0
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
        }
        for i in 0..<(n - 1) {
            if d[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        return m
    }
}
