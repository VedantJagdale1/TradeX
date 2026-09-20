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

@MainActor
struct GrowthPairingTests {

    private func day(_ n: Int) -> Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
            .addingTimeInterval(TimeInterval(n) * 86_400)
    }

    private func point(_ n: Int, _ value: Double, _ series: String) -> GrowthPoint {
        GrowthPoint(date: day(n), value: value, series: series)
    }

    @Test("Both curves line up day by day")
    func pairsByDay() {
        let pairs = PerformanceMath.pair(
            portfolio: [point(0, 100, "p"), point(1, 102, "p"), point(2, 101, "p")],
            benchmark: [point(0, 100, "b"), point(1, 99, "b"), point(2, 103, "b")]
        )

        #expect(pairs.count == 3)
        #expect(pairs[1].gap == 3)
        #expect(pairs[1].isAhead)
        #expect(!pairs[2].isAhead)
    }

    @Test("A day only one curve has is dropped rather than guessed at")
    func unmatchedDaysDropped() {
        // Shading a gap on a day the index was never measured would draw a lead that
        // did not happen.
        let pairs = PerformanceMath.pair(
            portfolio: [point(0, 100, "p"), point(1, 102, "p"), point(5, 110, "p")],
            benchmark: [point(0, 100, "b"), point(1, 99, "b")]
        )

        #expect(pairs.count == 2)
        #expect(!pairs.contains { $0.date == day(5) })
    }

    @Test("Matching is by calendar day, not exact timestamp")
    func matchesAcrossTimesOfDay() {
        let morning = GrowthPoint(date: day(0).addingTimeInterval(9 * 3_600), value: 100, series: "p")
        let evening = GrowthPoint(date: day(0).addingTimeInterval(18 * 3_600), value: 97, series: "b")

        let pairs = PerformanceMath.pair(portfolio: [morning], benchmark: [evening])

        #expect(pairs.count == 1)
        #expect(pairs.first?.gap == 3)
    }

    @Test("Level curves pair with no gap, and count as ahead")
    func flatIsAhead() {
        let pairs = PerformanceMath.pair(
            portfolio: [point(0, 100, "p")], benchmark: [point(0, 100, "b")]
        )
        #expect(pairs.first?.gap == 0)
        #expect(pairs.first?.isAhead == true)
    }

    @Test("Empty input pairs to nothing")
    func emptyInput() {
        #expect(PerformanceMath.pair(portfolio: [], benchmark: [point(0, 100, "b")]).isEmpty)
        #expect(PerformanceMath.pair(portfolio: [point(0, 100, "p")], benchmark: []).isEmpty)
    }

    @Test("A scrub between days snaps to the nearest measured one")
    func nearestSnapsToMeasuredDay() throws {
        let pairs = PerformanceMath.pair(
            portfolio: [point(0, 100, "p"), point(3, 105, "p")],
            benchmark: [point(0, 100, "b"), point(3, 101, "b")]
        )

        // Two thirds of the way from day 0 to day 3 is nearer day 3.
        let between = day(0).addingTimeInterval(2 * 86_400)
        #expect(try #require(PerformanceMath.nearest(to: between, in: pairs)).date == day(3))

        let early = day(0).addingTimeInterval(3_600)
        #expect(try #require(PerformanceMath.nearest(to: early, in: pairs)).date == day(0))
    }

    @Test("Scrubbing an empty chart finds nothing rather than trapping")
    func nearestOnEmpty() {
        #expect(PerformanceMath.nearest(to: day(0), in: []) == nil)
    }
}
