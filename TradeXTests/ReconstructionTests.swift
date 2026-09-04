//
//  ReconstructionTests.swift
//  TradeXTests
//

import Foundation
import Testing
@testable import TradeX

/// The replay that shipped a bug: reconstructing from zero made holdings created before
/// the ledger existed vanish from the past, inventing a crash that never happened.
struct ReconstructionTests {

    private let day0 = Date(timeIntervalSince1970: 1_780_000_000)
    private func day(_ offset: Int) -> Date { day0.addingTimeInterval(Double(offset) * 86_400) }
    private func endOf(_ offset: Int) -> Date { day(offset).addingTimeInterval(86_400) }

    // MARK: - Opening state

    @Test("Replaying every flow forward lands exactly on today")
    func openingStateReconciles() {
        let trades = [
            LedgerTrade(symbol: "TMCV", isBuy: true, quantity: 10, price: 467.10, timestamp: day(1)),
            LedgerTrade(symbol: "TMCV", isBuy: false, quantity: 4, price: 467.10, timestamp: day(2)),
        ]
        let adjustments = [LedgerCashFlow(amount: 274_500, timestamp: day(0))]
        let currentQuantities = ["TMCV": 6, "RELIANCE": 1]
        let currentCash = 291_955.80

        let opening = PerformanceReconstructor.openingState(
            currentQuantities: currentQuantities,
            currentCash: currentCash,
            trades: trades,
            adjustments: adjustments
        )

        // Replay forward from the derived opening state.
        var cash = opening.cash + adjustments.reduce(0) { $0 + $1.amount }
        var quantities = opening.quantities
        for trade in trades {
            cash += trade.cashFlow
            quantities[trade.symbol, default: 0] += trade.quantityChange
        }

        #expect(abs(cash - currentCash) < 0.001)
        #expect(quantities["TMCV"] == 6)
        #expect(quantities["RELIANCE"] == 1)
    }

    @Test("Holdings the ledger can't explain are carried from before it existed")
    func preLedgerHoldingsSurvive() {
        // RELIANCE is held but has no trade rows — it predates the journal.
        let opening = PerformanceReconstructor.openingState(
            currentQuantities: ["RELIANCE": 1, "TMCV": 6],
            currentCash: 291_955.80,
            trades: [LedgerTrade(symbol: "TMCV", isBuy: true, quantity: 6, price: 467.10, timestamp: day(1))],
            adjustments: [LedgerCashFlow(amount: 274_500, timestamp: day(0))]
        )

        #expect(opening.quantities["RELIANCE"] == 1)   // must not vanish
        #expect(opening.quantities["TMCV"] == nil)     // fully explained by the ledger
    }

    // MARK: - Daily replay

    private func closes(_ entries: [(Int, Double)]) -> DailyCloses {
        DailyCloses(sorted: entries.map { (day: day($0.0), close: $0.1) })
    }

    @Test("Buying at the day's close doesn't change net worth")
    func buyingIsValueNeutral() {
        let opening = OpeningState(cash: 100_000, quantities: [:])
        let trades = [LedgerTrade(symbol: "X", isBuy: true, quantity: 10, price: 100, timestamp: day(1))]

        let value = PerformanceReconstructor.state(
            on: day(1), endOfDay: endOf(1), opening: opening,
            trades: trades, adjustments: [],
            closes: ["X": closes([(0, 95), (1, 100)])],
            fallbackDeposits: 100_000
        )

        // 99,000 cash + 10 shares at 100 = unchanged.
        #expect(abs(value.netWorth - 100_000) < 0.001)
    }

    @Test("A day with no close carries the previous one forward")
    func missingCloseCarriesForward() {
        let opening = OpeningState(cash: 100_000, quantities: [:])
        let trades = [LedgerTrade(symbol: "X", isBuy: true, quantity: 10, price: 100, timestamp: day(1))]
        // No close on day 2 — a holiday or a halt.
        let history = ["X": closes([(0, 95), (1, 100), (3, 120)])]

        let carried = PerformanceReconstructor.state(
            on: day(2), endOfDay: endOf(2), opening: opening,
            trades: trades, adjustments: [], closes: history, fallbackDeposits: 100_000
        )
        // Day 1's close of 100 is reused rather than the position dropping out.
        #expect(abs(carried.netWorth - 100_000) < 0.001)

        let priced = PerformanceReconstructor.state(
            on: day(3), endOfDay: endOf(3), opening: opening,
            trades: trades, adjustments: [], closes: history, fallbackDeposits: 100_000
        )
        // 99,000 + 10 x 120
        #expect(abs(priced.netWorth - 100_200) < 0.001)
    }

    @Test("A trade only counts from the day it happened")
    func tradesAreNotBackdated() {
        let opening = OpeningState(cash: 100_000, quantities: [:])
        let trades = [LedgerTrade(symbol: "X", isBuy: true, quantity: 10, price: 100, timestamp: day(2))]

        let before = PerformanceReconstructor.state(
            on: day(1), endOfDay: endOf(1), opening: opening,
            trades: trades, adjustments: [],
            closes: ["X": closes([(1, 100), (2, 100)])],
            fallbackDeposits: 100_000
        )

        #expect(abs(before.netWorth - 100_000) < 0.001)   // still all cash
    }

    @Test("A sold-out position stops contributing equity")
    func closedPositionsDropOut() {
        let opening = OpeningState(cash: 0, quantities: ["X": 10])
        let trades = [LedgerTrade(symbol: "X", isBuy: false, quantity: 10, price: 120, timestamp: day(1))]

        let value = PerformanceReconstructor.state(
            on: day(1), endOfDay: endOf(1), opening: opening,
            trades: trades, adjustments: [],
            closes: ["X": closes([(1, 120)])],
            fallbackDeposits: 0
        )

        #expect(abs(value.netWorth - 1_200) < 0.001)   // proceeds only, no double count
    }

    @Test("Deposits accumulate as of the day they landed")
    func depositsAccumulate() {
        let opening = OpeningState(cash: 0, quantities: [:])
        let adjustments = [
            LedgerCashFlow(amount: 100_000, timestamp: day(0)),
            LedgerCashFlow(amount: 50_000, timestamp: day(2)),
        ]

        let before = PerformanceReconstructor.state(
            on: day(1), endOfDay: endOf(1), opening: opening,
            trades: [], adjustments: adjustments, closes: [:], fallbackDeposits: 0
        )
        let after = PerformanceReconstructor.state(
            on: day(2), endOfDay: endOf(2), opening: opening,
            trades: [], adjustments: adjustments, closes: [:], fallbackDeposits: 0
        )

        #expect(abs(before.netDeposits - 100_000) < 0.001)
        #expect(abs(after.netDeposits - 150_000) < 0.001)
    }

    // MARK: - Range selection

    @Test("The requested history reaches back far enough to cover the ledger")
    func rangeCoversTheLedger() {
        let now = day(0)
        #expect(PerformanceReconstructor.yahooRange(covering: now.addingTimeInterval(-10 * 86_400), now: now) == "1mo")
        #expect(PerformanceReconstructor.yahooRange(covering: now.addingTimeInterval(-60 * 86_400), now: now) == "3mo")
        #expect(PerformanceReconstructor.yahooRange(covering: now.addingTimeInterval(-200 * 86_400), now: now) == "1y")
        #expect(PerformanceReconstructor.yahooRange(covering: now.addingTimeInterval(-5_000 * 86_400), now: now) == "max")
    }
}
