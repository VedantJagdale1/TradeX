//
//  PerformanceMathTests.swift
//  TradeXTests
//

import Foundation
import Testing
@testable import TradeX

/// The headline number on the Performance screen. Until now this had only ever been
/// checked against a reimplementation, not the shipped code.
struct PerformanceMathTests {

    private func snapshots(_ rows: [(day: Int, netWorth: Double, deposits: Double, nifty: Double?)]) -> [PortfolioSnapshot] {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return rows.map {
            PortfolioSnapshot(
                day: start.addingTimeInterval(Double($0.day) * 86_400),
                netWorth: $0.netWorth,
                netDeposits: $0.deposits,
                niftyLevel: $0.nifty
            )
        }
    }

    @Test("Consecutive gains compound rather than adding")
    func gainsChain() {
        let points = PerformanceMath.portfolioGrowth(from: snapshots([
            (0, 100_000, 100_000, nil),
            (1, 110_000, 100_000, nil),   // +10%
            (2, 121_000, 100_000, nil),   // +10% again
        ]))

        #expect(points.count == 3)
        #expect(abs((points.last?.value ?? 0) - 121.0) < 0.001)   // 1.1 x 1.1, not +20%
    }

    @Test("Paying money in is not a gain")
    func depositsAreNeutral() {
        // Cash quadruples, the market does nothing.
        let points = PerformanceMath.portfolioGrowth(from: snapshots([
            (0, 100_000, 100_000, nil),
            (1, 500_000, 500_000, nil),
        ]))

        #expect(abs((points.last?.value ?? 0) - PerformanceMath.base) < 0.001)
    }

    @Test("A deposit mid-period doesn't dilute the return either side of it")
    func depositBetweenGains() {
        // +10%, then 50k paid in with a flat market, then +10%.
        let points = PerformanceMath.portfolioGrowth(from: snapshots([
            (0, 100_000, 100_000, nil),
            (1, 110_000, 100_000, nil),
            (2, 160_000, 150_000, nil),
            (3, 176_000, 150_000, nil),
        ]))

        // The naive (value - deposits) / deposits would report +17.33%.
        #expect(abs((points.last?.value ?? 0) - 121.0) < 0.001)
    }

    @Test("A single mark isn't a return")
    func oneSnapshotProducesNoCurve() {
        #expect(PerformanceMath.portfolioGrowth(from: snapshots([(0, 100_000, 100_000, 24_000)])).isEmpty)
    }

    @Test("The benchmark is rebased to the same starting value")
    func benchmarkRebases() {
        let points = PerformanceMath.benchmarkGrowth(from: snapshots([
            (0, 100_000, 100_000, 24_000),
            (1, 100_000, 100_000, 24_240),   // +1%
        ]))

        #expect(abs((points.first?.value ?? 0) - 100.0) < 0.001)
        #expect(abs((points.last?.value ?? 0) - 101.0) < 0.001)
    }

    @Test("Days without a benchmark level are skipped, not treated as zero")
    func benchmarkIgnoresMissingLevels() {
        let points = PerformanceMath.benchmarkGrowth(from: snapshots([
            (0, 100_000, 100_000, 24_000),
            (1, 100_000, 100_000, nil),
            (2, 100_000, 100_000, 24_240),
        ]))

        #expect(points.count == 2)
    }

    @Test("A wiped-out portfolio doesn't divide by zero")
    func zeroValueIsSurvivable() {
        let points = PerformanceMath.portfolioGrowth(from: snapshots([
            (0, 0, 0, nil),
            (1, 0, 0, nil),
        ]))
        #expect(points.count == 2)
        #expect((points.last?.value ?? 0).isFinite)
    }
}
