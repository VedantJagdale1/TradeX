//
//  CorporateActionTests.swift
//  TradeXTests
//

import Foundation
import SwiftData
import Testing
@testable import TradeX

@MainActor
struct CorporateActionTests {

    private struct Book {
        let context: ModelContext
        let manager: PortfolioManager

        init() throws {
            let container = try ModelContainer(
                for: PortfolioHolding.self, UserSettings.self, Trade.self,
                CashAdjustment.self, PortfolioSnapshot.self, WatchlistItem.self,
                PriceAlert.self, LimitOrder.self, StoredChatMessage.self, CorporateAction.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            context = ModelContext(container)
            manager = PortfolioManager()
            manager.quoteProvider = { _ in nil }
            manager.settings(in: context).brokerProfile = .none
        }

        /// Records the buy that opened a position, so splits can be dated against it.
        func openedPosition(_ symbol: String, quantity: Int, cost: Double, daysAgo: Int) {
            context.insert(
                Trade(symbol: symbol, companyName: symbol, isBuy: true,
                      quantity: quantity, price: cost,
                      timestamp: Date(timeIntervalSinceNow: -Double(daysAgo) * 86_400))
            )
            try? context.save()
        }

        @discardableResult
        func hold(_ symbol: String, quantity: Int, cost: Double, mark: Double) -> PortfolioHolding {
            let holding = PortfolioHolding(symbol: symbol, companyName: symbol,
                                           quantity: quantity, avgBuyPrice: cost, currentPrice: mark)
            context.insert(holding)
            try? context.save()
            return holding
        }

        func scan(_ splits: [String: [SplitEvent]], now: Date = Date()) async -> [CorporateAction] {
            let suite = UserDefaults(suiteName: "CA.\(UUID().uuidString)")!
            return await CorporateActionService.apply(
                modelContext: context, now: now, defaults: suite,
                splitSource: { splits[$0] ?? [] }
            )
        }
    }

    private func split(_ numerator: Double, _ denominator: Double, daysAgo: Int = 30) -> SplitEvent {
        SplitEvent(date: Date(timeIntervalSinceNow: -Double(daysAgo) * 86_400),
                   numerator: numerator, denominator: denominator)
    }

    // MARK: - The bug this exists to prevent

    @Test("A split restates the position instead of showing a loss that never happened")
    func splitDoesNotCreateAPhantomLoss() async throws {
        let book = try Book()
        // Bought 10 at ₹2,000, before the split. A 2:1 halves the quoted price.
        book.openedPosition("RELIANCE", quantity: 10, cost: 2_000, daysAgo: 90)
        let holding = book.hold("RELIANCE", quantity: 10, cost: 2_000, mark: 2_000)

        _ = await book.scan(["RELIANCE": [split(2, 1)]])

        #expect(holding.quantity == 20)
        #expect(abs(holding.avgBuyPrice - 1_000) < 0.001)
        // Without the adjustment this position would read -50%.
        #expect(abs(holding.totalPNL) < 0.001)
        #expect(abs(holding.pnlPercentage) < 0.001)
    }

    @Test("Money invested is unchanged by a split")
    func investedCapitalIsInvariant() async throws {
        let book = try Book()
        book.openedPosition("TCS", quantity: 7, cost: 3_500, daysAgo: 90)
        let holding = book.hold("TCS", quantity: 7, cost: 3_500, mark: 3_500)
        let before = holding.investedAmount

        _ = await book.scan(["TCS": [split(5, 1)]])

        #expect(holding.quantity == 35)
        #expect(abs(holding.investedAmount - before) < 0.001)
    }

    @Test("An odd ratio keeps the cost basis exact despite rounding the share count")
    func roundingPreservesCostBasis() async throws {
        let book = try Book()
        // 3:2 on 5 shares is 7.5 — the count rounds, the money must not.
        book.openedPosition("INFY", quantity: 5, cost: 1_000, daysAgo: 90)
        let holding = book.hold("INFY", quantity: 5, cost: 1_000, mark: 1_000)
        let before = holding.investedAmount

        _ = await book.scan(["INFY": [split(3, 2)]])

        #expect(holding.quantity == 7)
        #expect(abs(holding.investedAmount - before) < 0.001)
    }

    @Test("A consolidation works the other way")
    func reverseSplitConsolidates() async throws {
        let book = try Book()
        book.openedPosition("X", quantity: 100, cost: 10, daysAgo: 90)
        let holding = book.hold("X", quantity: 100, cost: 10, mark: 10)

        _ = await book.scan(["X": [split(1, 10)]])

        #expect(holding.quantity == 10)
        #expect(abs(holding.avgBuyPrice - 100) < 0.001)
        #expect(abs(holding.investedAmount - 1_000) < 0.001)
    }

    @Test("A consolidation can't round a position out of existence")
    func tinyPositionSurvivesConsolidation() async throws {
        let book = try Book()
        book.openedPosition("X", quantity: 5, cost: 100, daysAgo: 90)
        let holding = book.hold("X", quantity: 5, cost: 100, mark: 100)

        _ = await book.scan(["X": [split(1, 10)]])

        #expect(holding.quantity >= 1)
        #expect(abs(holding.investedAmount - 500) < 0.001)
    }

    // MARK: - Applied exactly once

    @Test("Rescanning doesn't apply the same split twice")
    func splitsApplyOnce() async throws {
        let book = try Book()
        book.openedPosition("RELIANCE", quantity: 10, cost: 2_000, daysAgo: 90)
        let holding = book.hold("RELIANCE", quantity: 10, cost: 2_000, mark: 2_000)
        let event = split(2, 1)

        let first = await book.scan(["RELIANCE": [event]])
        let second = await book.scan(["RELIANCE": [event]])

        #expect(first.count == 1)
        #expect(second.isEmpty)          // reapplying would double the shares again
        #expect(holding.quantity == 20)
        #expect(abs(holding.avgBuyPrice - 1_000) < 0.001)
    }

    @Test("Two separate splits both apply")
    func consecutiveSplitsCompound() async throws {
        let book = try Book()
        book.openedPosition("X", quantity: 10, cost: 1_000, daysAgo: 90)
        let holding = book.hold("X", quantity: 10, cost: 1_000, mark: 1_000)

        _ = await book.scan(["X": [split(2, 1, daysAgo: 60), split(2, 1, daysAgo: 30)]])

        #expect(holding.quantity == 40)
        #expect(abs(holding.avgBuyPrice - 250) < 0.001)
    }

    @Test("The adjustment is recorded so it can be audited")
    func actionIsRecorded() async throws {
        let book = try Book()
        book.openedPosition("RELIANCE", quantity: 10, cost: 2_000, daysAgo: 90)
        book.hold("RELIANCE", quantity: 10, cost: 2_000, mark: 2_000)

        let applied = await book.scan(["RELIANCE": [split(2, 1)]])
        let action = try #require(applied.first)

        #expect(action.symbol == "RELIANCE")
        #expect(action.ratioDescription == "2:1")
        #expect(action.quantityBefore == 10)
        #expect(action.quantityAfter == 20)
        #expect(abs(action.averageCostBefore - 2_000) < 0.001)
        #expect(abs(action.averageCostAfter - 1_000) < 0.001)
    }

    // MARK: - Everything priced in rupees moves with the stock

    @Test("A stop moves with the split instead of triggering instantly")
    func restingOrdersAreRestated() async throws {
        let book = try Book()
        book.openedPosition("RELIANCE", quantity: 10, cost: 2_000, daysAgo: 90)
        book.hold("RELIANCE", quantity: 10, cost: 2_000, mark: 2_000)

        // A stop-loss at ₹1,900 would fire the moment the price restates to ₹1,000.
        let stop = LimitOrder(symbol: "RELIANCE", companyName: "RELIANCE", isBuy: false,
                              quantity: 10, limitPrice: 1_900, kind: .stop)
        book.context.insert(stop)
        try? book.context.save()

        _ = await book.scan(["RELIANCE": [split(2, 1)]])

        #expect(abs(stop.limitPrice - 950) < 0.001)
        #expect(stop.quantity == 20)
        #expect(stop.wouldFill(at: 1_000) == false)   // no longer triggered by the restatement
    }

    @Test("A trailing stop's high-water mark is restated too")
    func trailingHighWaterIsRestated() async throws {
        let book = try Book()
        book.openedPosition("X", quantity: 10, cost: 1_000, daysAgo: 90)
        book.hold("X", quantity: 10, cost: 1_000, mark: 1_000)

        let trail = LimitOrder(symbol: "X", companyName: "X", isBuy: false,
                               quantity: 10, limitPrice: 0, kind: .trailingStop, trailPercent: 10)
        trail.updateTrail(with: 1_000)
        book.context.insert(trail)
        try? book.context.save()

        _ = await book.scan(["X": [split(2, 1)]])

        #expect(abs((trail.extremePrice ?? 0) - 500) < 0.001)
        #expect(abs(trail.limitPrice - 450) < 0.001)
    }

    @Test("A price alert keeps meaning what its owner meant")
    func alertsAreRestated() async throws {
        let book = try Book()
        book.openedPosition("RELIANCE", quantity: 10, cost: 2_000, daysAgo: 90)
        book.hold("RELIANCE", quantity: 10, cost: 2_000, mark: 2_000)

        let alert = PriceAlert(symbol: "RELIANCE", companyName: "RELIANCE",
                               targetPrice: 2_600, isAbove: true)
        book.context.insert(alert)
        try? book.context.save()

        _ = await book.scan(["RELIANCE": [split(2, 1)]])

        #expect(abs(alert.targetPrice - 1_300) < 0.001)
    }

    @Test("Symbols with no action are left alone")
    func unaffectedHoldingsAreUntouched() async throws {
        let book = try Book()
        book.openedPosition("INFY", quantity: 10, cost: 1_000, daysAgo: 90)
        let holding = book.hold("INFY", quantity: 10, cost: 1_000, mark: 1_100)

        let applied = await book.scan(["INFY": []])

        #expect(applied.isEmpty)
        #expect(holding.quantity == 10)
        #expect(abs(holding.avgBuyPrice - 1_000) < 0.001)
    }

    // MARK: - Splits that predate the position

    @Test("A split from before the position was opened is already in the price paid")
    func historicalSplitIsNotReapplied() async throws {
        let book = try Book()
        // Bought last week, at a price that already reflects a split from two years ago.
        book.openedPosition("RELIANCE", quantity: 1, cost: 1_322, daysAgo: 7)
        let holding = book.hold("RELIANCE", quantity: 1, cost: 1_322, mark: 1_226)

        let applied = await book.scan(["RELIANCE": [split(2, 1, daysAgo: 700)]])

        #expect(applied.isEmpty)
        #expect(holding.quantity == 1)
        #expect(abs(holding.avgBuyPrice - 1_322) < 0.001)
        // Reapplying would have shown roughly +85% on a position that is down.
        #expect(holding.totalPNL < 0)
    }

    @Test("A split after the position was opened still applies")
    func laterSplitStillApplies() async throws {
        let book = try Book()
        book.openedPosition("X", quantity: 10, cost: 1_000, daysAgo: 90)
        let holding = book.hold("X", quantity: 10, cost: 1_000, mark: 1_000)

        let applied = await book.scan(["X": [split(2, 1, daysAgo: 30)]])

        #expect(applied.count == 1)
        #expect(holding.quantity == 20)
    }

    @Test("A holding with no trade record is left to future splits only")
    func untrackedHoldingSkipsHistory() async throws {
        let book = try Book()
        // No opening trade, so the position can't be dated and history can't be judged.
        let holding = book.hold("Y", quantity: 10, cost: 500, mark: 500)

        let applied = await book.scan(["Y": [split(2, 1, daysAgo: 30)]])

        #expect(applied.isEmpty)
        #expect(holding.quantity == 10)
    }

    @Test("An adjustment made in error is reversed")
    func repairsMisappliedActions() async throws {
        let book = try Book()
        book.openedPosition("RELIANCE", quantity: 1, cost: 1_322, daysAgo: 7)
        let holding = book.hold("RELIANCE", quantity: 2, cost: 661, mark: 1_226)

        // What the buggy build wrote: a two-year-old split applied to a week-old position.
        book.context.insert(
            CorporateAction(
                symbol: "RELIANCE",
                effectiveDate: Date(timeIntervalSinceNow: -700 * 86_400),
                numerator: 2, denominator: 1,
                quantityBefore: 1, quantityAfter: 2,
                averageCostBefore: 1_322, averageCostAfter: 661
            )
        )
        try? book.context.save()

        let repaired = CorporateActionService.repairMisapplied(modelContext: book.context)

        #expect(repaired == ["RELIANCE"])
        #expect(holding.quantity == 1)
        #expect(abs(holding.avgBuyPrice - 1_322) < 0.001)
        #expect(((try? book.context.fetch(FetchDescriptor<CorporateAction>())) ?? []).isEmpty)
    }

    @Test("A correctly applied adjustment is left alone by the repair")
    func repairLeavesValidActions() async throws {
        let book = try Book()
        book.openedPosition("X", quantity: 10, cost: 1_000, daysAgo: 90)
        let holding = book.hold("X", quantity: 10, cost: 1_000, mark: 1_000)
        _ = await book.scan(["X": [split(2, 1, daysAgo: 30)]])

        let repaired = CorporateActionService.repairMisapplied(modelContext: book.context)

        #expect(repaired.isEmpty)
        #expect(holding.quantity == 20)
    }

    @Test("A position traded since the bad adjustment is not guessed at")
    func repairSkipsChangedHoldings() async throws {
        let book = try Book()
        book.openedPosition("RELIANCE", quantity: 1, cost: 1_322, daysAgo: 7)
        // Quantity no longer matches what the adjustment left, so the original is gone.
        let holding = book.hold("RELIANCE", quantity: 5, cost: 700, mark: 1_226)

        book.context.insert(
            CorporateAction(
                symbol: "RELIANCE",
                effectiveDate: Date(timeIntervalSinceNow: -700 * 86_400),
                numerator: 2, denominator: 1,
                quantityBefore: 1, quantityAfter: 2,
                averageCostBefore: 1_322, averageCostAfter: 661
            )
        )
        try? book.context.save()

        let repaired = CorporateActionService.repairMisapplied(modelContext: book.context)

        #expect(repaired.isEmpty)
        #expect(holding.quantity == 5)   // left as found
    }

    @Test("A malformed ratio is ignored rather than trapping")
    func malformedRatioIsIgnored() async throws {
        let book = try Book()
        book.openedPosition("X", quantity: 10, cost: 100, daysAgo: 90)
        let holding = book.hold("X", quantity: 10, cost: 100, mark: 100)

        // A zero denominator makes the multiplier infinite, which clears a naive
        // `> 0` check and then traps converting back to a whole share count.
        let bogus = SplitEvent(date: Date(timeIntervalSinceNow: -30 * 86_400),
                               numerator: 2, denominator: 0)
        let applied = await book.scan(["X": [bogus]])

        #expect(applied.isEmpty)
        #expect(holding.quantity == 10)
    }

    @Test("The scan runs once a day, not on every appearance")
    func scanIsThrottledDaily() {
        let suite = UserDefaults(suiteName: "CAthrottle.\(UUID().uuidString)")!
        let now = Date()

        #expect(CorporateActionService.shouldScan(now: now, defaults: suite) == true)

        suite.set(now, forKey: "TradeX.lastSplitScan")
        #expect(CorporateActionService.shouldScan(now: now, defaults: suite) == false)
        #expect(CorporateActionService.shouldScan(now: now.addingTimeInterval(86_400), defaults: suite) == true)
    }
}
