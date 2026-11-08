import Foundation
import Testing
@testable import DustlingAppModel

struct SkeletonMathTests {
    @Test func rowCountFillsTheHeightWithWholeRows() {
        #expect(SkeletonMath.rowCount(height: 540, rowHeight: 54) == 10)
        #expect(SkeletonMath.rowCount(height: 539, rowHeight: 54) == 9)
    }

    @Test func rowCountCountsTheSpacingBetweenRows() {
        // 4 rows of 80 with 3 gaps of 14 = 362.
        #expect(SkeletonMath.rowCount(height: 362, rowHeight: 80, spacing: 14) == 4)
        #expect(SkeletonMath.rowCount(height: 361, rowHeight: 80, spacing: 14) == 3)
    }

    @Test func rowCountIsClamped() {
        #expect(SkeletonMath.rowCount(height: 0, rowHeight: 54) == SkeletonMath.minRows)
        #expect(SkeletonMath.rowCount(height: 60, rowHeight: 54) == SkeletonMath.minRows)
        #expect(SkeletonMath.rowCount(height: -10, rowHeight: 54) == SkeletonMath.minRows)
        #expect(SkeletonMath.rowCount(height: 100, rowHeight: 0) == SkeletonMath.minRows)
        #expect(SkeletonMath.rowCount(height: 100_000, rowHeight: 38) == SkeletonMath.maxRows)
    }

    @Test func pulseGoesFromFullToFaintAndBack() {
        let p = 1.3
        #expect(abs(SkeletonMath.pulseOpacity(at: 0, index: 0, period: p, stagger: 0.12) - 1) < 1e-9)
        #expect(abs(SkeletonMath.pulseOpacity(at: p / 2, index: 0, period: p, stagger: 0.12) - 0.45) < 1e-9)
        #expect(abs(SkeletonMath.pulseOpacity(at: p, index: 0, period: p, stagger: 0.12) - 1) < 1e-9)
        for step in 0..<50 {
            let value = SkeletonMath.pulseOpacity(at: Double(step) * 0.037, index: 0, period: p, stagger: 0.12)
            #expect(value >= 0.45 - 1e-9 && value <= 1 + 1e-9)
        }
    }

    @Test func eachRowRunsOneStaggerBehind() {
        let t = 1_000.4
        let row2 = SkeletonMath.pulseOpacity(at: t, index: 2, period: 1.3, stagger: 0.12)
        let row0 = SkeletonMath.pulseOpacity(at: t - 0.24, index: 0, period: 1.3, stagger: 0.12)
        #expect(abs(row2 - row0) < 1e-9)
        // Early times (or large indexes) don't go negative.
        let early = SkeletonMath.pulseOpacity(at: 0.1, index: 5, period: 1.3, stagger: 0.12)
        #expect(early >= 0.45 && early <= 1)
    }
}
