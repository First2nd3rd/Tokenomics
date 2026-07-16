import Testing
import Foundation
@testable import Tokenomics

@Suite("MonotoneCubic resampling")
struct MonotoneCubicTests {

    @Test("dense grid keeps every control x and stays sorted")
    func denseGrid() {
        let xs: [Double] = [0, 1, 2.5, 3]
        let dense = MonotoneCubic.denseXs(xs, subdivisions: 4)
        #expect(dense.count == 3 * 4 + 1)
        #expect(dense == dense.sorted())
        for x in xs { #expect(dense.contains(x)) }
    }

    @Test("curve passes through the control points exactly")
    func interpolatesControls() {
        let xs: [Double] = [0, 1, 2, 3, 4]
        let ys: [Double] = [0, 10, 3, 7, 7]
        let dense = MonotoneCubic.denseXs(xs, subdivisions: 5)
        let out = MonotoneCubic.resample(xs: xs, ys: ys, at: dense)
        for (i, x) in xs.enumerated() {
            let j = dense.firstIndex(of: x)!
            #expect(abs(out[j] - ys[i]) < 1e-9)
        }
    }

    @Test("a run of zeros stays exactly zero at every dense sample")
    func zeroRunStaysZero() {
        // The property that kills the phantom-band artifact: a band that is zero
        // over a stretch must contribute NOTHING there, not a smoothed hairline.
        let xs = (0..<20).map(Double.init)
        var ys = [Double](repeating: 0, count: 20)
        ys[3] = 5_000_000    // isolated spike before the zero run
        ys[15] = 2_000_000   // and one after
        let dense = MonotoneCubic.denseXs(xs, subdivisions: 8)
        let out = MonotoneCubic.resample(xs: xs, ys: ys, at: dense)
        for (x, y) in zip(dense, out) where x >= 4 && x <= 14 {
            #expect(y == 0, "expected exact zero at x=\(x), got \(y)")
        }
    }

    @Test("never overshoots the interval it interpolates")
    func noOvershoot() {
        let xs = (0..<12).map(Double.init)
        let ys: [Double] = [0, 8, 8, 1, 0, 0, 9, 2, 2, 5, 0, 3]
        let dense = MonotoneCubic.denseXs(xs, subdivisions: 10)
        let out = MonotoneCubic.resample(xs: xs, ys: ys, at: dense)
        for (x, y) in zip(dense, out) {
            let i = min(Int(x), 10)
            let lo = min(ys[i], ys[i + 1]) - 1e-9
            let hi = max(ys[i], ys[i + 1]) + 1e-9
            #expect(y >= lo && y <= hi, "overshoot at x=\(x): \(y) outside [\(lo), \(hi)]")
        }
    }

    @Test("handles non-uniform x spacing")
    func nonUniformX() {
        // Mirrors the rate chart's final partial bucket landing at "now".
        let xs: [Double] = [0, 5, 10, 12.4]
        let ys: [Double] = [0, 6, 0, 3]
        let dense = MonotoneCubic.denseXs(xs, subdivisions: 6)
        let out = MonotoneCubic.resample(xs: xs, ys: ys, at: dense)
        #expect(out.count == dense.count)
        #expect(abs(out.last! - 3) < 1e-9)
        for y in out { #expect(y >= -1e-9 && y <= 6 + 1e-9) }
    }

    @Test("degenerate inputs fall back to linear behaviour")
    func degenerateInputs() {
        #expect(MonotoneCubic.resample(xs: [], ys: [], at: [1, 2]).isEmpty)
        #expect(MonotoneCubic.resample(xs: [1], ys: [4], at: [1]) == [4])
        let two = MonotoneCubic.resample(xs: [0, 2], ys: [0, 10], at: [0, 1, 2])
        #expect(two == [0, 5, 10])
        #expect(MonotoneCubic.denseXs([3], subdivisions: 4) == [3])
    }
}
