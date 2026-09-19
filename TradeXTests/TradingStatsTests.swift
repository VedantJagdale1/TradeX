//
//  TradingStatsTests.swift
//  TradeXTests
//

import Foundation
import Testing
@testable import TradeX

struct DrawdownTests {

    @Test("A curve that only rises has no drawdown")
    func risingCurveHasNone() {
        #expect(abs(TradingStats.maxDrawdown(of: [100, 105, 110, 130])) < 0.001)
    }

    @Test("Drawdown is measured peak to trough, not start to end")
    func measuredFromThePeak() {
        // Ends above where it began, but fell 25% from 120 to 90 on the way.
        let drawdown = TradingStats.maxDrawdown(of: [100, 120, 90, 130])
        #expect(abs(drawdown - 25) < 0.001)
    }

    @Test("The deepest fall wins, not the most recent")
    func keepsTheWorst() {
        // -40% early, -10% late.
        let drawdown = TradingStats.maxDrawdown(of: [100, 60, 100, 90])
        #expect(abs(drawdown - 40) < 0.001)
    }

    @Test("Two records with the same return can have very different drawdowns")
    func sameReturnDifferentRide() {
        let steady = TradingStats.maxDrawdown(of: [100, 105, 110, 115, 120])
        let violent = TradingStats.maxDrawdown(of: [100, 160, 80, 100, 120])

        // Both finish at 120. Only one was survivable.
        #expect(steady < 1)
        #expect(violent > 45)
    }

    @Test("An empty or flat curve doesn't divide by zero")
    func degenerateCurves() {
        #expect(TradingStats.maxDrawdown(of: []) == 0)
        #expect(TradingStats.maxDrawdown(of: [100]) == 0)
        #expect(TradingStats.maxDrawdown(of: [0, 0]) == 0)
    }
}


struct ExpectancyTests {

    private func closed(_ pnl: [Double]) -> [ClosedTrade] {
        pnl.enumerated().map {
            ClosedTrade(symbol: "X", realizedPnL: $1,
                        closedAt: Date(timeIntervalSince1970: Double($0) * 86_400),
                        openedAt: nil)
        }
    }

    @Test("Expectancy is what an average trade is worth")
    func expectancyIsPerTrade() {
        // Three wins of 100, one loss of 100: (0.75 x 100) - (0.25 x 100) = 50.
        let stats = TradingStats.make(closed: closed([100, 100, 100, -100]), equityCurve: [])

        #expect(abs(stats.winRate - 75) < 0.001)
        #expect(abs(stats.averageWin - 100) < 0.001)
        #expect(abs(stats.averageLoss - 100) < 0.001)
        #expect(abs(stats.expectancy - 50) < 0.001)
    }

    @Test("A record can lose most trades and still be profitable")
    func lowWinRateCanStillPay() {
        // One win of 1,000, four losses of 100. Win rate 20%, expectancy still positive.
        let stats = TradingStats.make(closed: closed([1_000, -100, -100, -100, -100]), equityCurve: [])

        #expect(abs(stats.winRate - 20) < 0.001)
        #expect(stats.expectancy > 0)
        #expect((stats.profitFactor ?? 0) > 1)
    }

    @Test("A record can win most trades and still lose money")
    func highWinRateCanStillLose() {
        // Four wins of 50, one loss of 500 — the shape that ruins accounts.
        let stats = TradingStats.make(closed: closed([50, 50, 50, 50, -500]), equityCurve: [])

        #expect(abs(stats.winRate - 80) < 0.001)
        #expect(stats.expectancy < 0)
        #expect((stats.profitFactor ?? 99) < 1)
    }

    @Test("Profit factor is undefined rather than infinite with no losses")
    func noLossesMeansNoFactor() {
        #expect(TradingStats.make(closed: closed([100, 200]), equityCurve: []).profitFactor == nil)
    }

    @Test("A break-even trade counts as a loss, not a win")
    func breakEvenIsNotAWin() {
        let stats = TradingStats.make(closed: closed([0, 100]), equityCurve: [])
        #expect(abs(stats.winRate - 50) < 0.001)
    }

    @Test("No closed trades gives empty statistics, not nonsense")
    func emptyRecord() {
        let stats = TradingStats.make(closed: [], equityCurve: [100, 90])
        #expect(stats.closedCount == 0)
        #expect(stats.expectancy == 0)
        #expect(abs(stats.maxDrawdown - 10) < 0.001)   // drawdown still applies
    }
}


struct HoldingPeriodTests {

    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private func day(_ n: Int) -> Date { start.addingTimeInterval(Double(n) * 86_400) }

    private func buy(_ symbol: String, _ qty: Int, on n: Int) -> LedgerTrade {
        LedgerTrade(symbol: symbol, isBuy: true, quantity: qty, price: 100, timestamp: day(n))
    }
    private func sell(_ symbol: String, _ qty: Int, on n: Int, pnl: Double) -> LedgerTrade {
        LedgerTrade(symbol: symbol, isBuy: false, quantity: qty, price: 100,
                    timestamp: day(n), realizedPnL: pnl)
    }

    @Test("A holding period runs from when the position was opened")
    func measuredFromTheOpen() {
        let closed = TradingStats.closedTrades(from: [
            buy("X", 10, on: 0),
            sell("X", 10, on: 7, pnl: 500),
        ])

        #expect(closed.count == 1)
        #expect(abs((closed.first?.holdingDays ?? 0) - 7) < 0.001)
    }

    @Test("Topping up doesn't restart the clock")
    func topUpsDoNotResetTheOpenDate() {
        // Averaging cost across top-ups makes any other answer arbitrary.
        let closed = TradingStats.closedTrades(from: [
            buy("X", 10, on: 0),
            buy("X", 10, on: 5),
            sell("X", 20, on: 10, pnl: 500),
        ])

        #expect(abs((closed.first?.holdingDays ?? 0) - 10) < 0.001)
    }

    @Test("Reopening a symbol starts a new clock")
    func reopeningStartsFresh() {
        let closed = TradingStats.closedTrades(from: [
            buy("X", 10, on: 0),
            sell("X", 10, on: 4, pnl: 100),
            buy("X", 10, on: 20),
            sell("X", 10, on: 22, pnl: -50),
        ])

        #expect(closed.count == 2)
        #expect(abs((closed[0].holdingDays ?? 0) - 4) < 0.001)
        #expect(abs((closed[1].holdingDays ?? 0) - 2) < 0.001)
    }

    @Test("A partial sell is measured from the original open")
    func partialSellUsesTheOpen() {
        let closed = TradingStats.closedTrades(from: [
            buy("X", 10, on: 0),
            sell("X", 4, on: 6, pnl: 200),
        ])

        #expect(abs((closed.first?.holdingDays ?? 0) - 6) < 0.001)
    }

    @Test("Positions in different symbols are tracked separately")
    func symbolsDoNotInterfere() {
        let closed = TradingStats.closedTrades(from: [
            buy("A", 10, on: 0),
            buy("B", 10, on: 8),
            sell("A", 10, on: 10, pnl: 100),
            sell("B", 10, on: 12, pnl: -100),
        ])

        #expect(abs((closed.first { $0.symbol == "A" }?.holdingDays ?? 0) - 10) < 0.001)
        #expect(abs((closed.first { $0.symbol == "B" }?.holdingDays ?? 0) - 4) < 0.001)
    }

    @Test("Holding losers longer than winners is detected")
    func detectsCuttingWinnersShort() {
        // Win closed after 2 days, loss nursed for 30 — the classic failure.
        let closed = TradingStats.closedTrades(from: [
            buy("A", 10, on: 0),
            sell("A", 10, on: 2, pnl: 100),
            buy("B", 10, on: 0),
            sell("B", 10, on: 30, pnl: -100),
        ])
        let stats = TradingStats.make(closed: closed, equityCurve: [])

        #expect(abs((stats.averageHoldWinners ?? 0) - 2) < 0.001)
        #expect(abs((stats.averageHoldLosers ?? 0) - 30) < 0.001)
        #expect(stats.holdsLosersLonger == true)
    }

    @Test("Buys alone close nothing")
    func buysAreNotClosedTrades() {
        #expect(TradingStats.closedTrades(from: [buy("X", 10, on: 0)]).isEmpty)
    }
}
