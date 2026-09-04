//
//  LimitOrderServiceTests.swift
//  TradeXTests
//

import Foundation
import SwiftData
import Testing
@testable import TradeX

/// An in-memory account with a stubbed clock and quote source, so fills can be exercised
/// without the network and without only passing between 9:15 and 3:30.
@MainActor
private struct Desk {
    let context: ModelContext
    let manager: PortfolioManager

    init() throws {
        let container = try ModelContainer(
            for: PortfolioHolding.self, UserSettings.self, Trade.self,
            CashAdjustment.self, PortfolioSnapshot.self, WatchlistItem.self,
            PriceAlert.self, LimitOrder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        manager = PortfolioManager()
        manager.quoteProvider = { _ in nil }   // no post-trade re-mark
    }

    /// A Friday mid-session, and the following Saturday.
    static func ist(_ stamp: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = MarketSession.exchangeTimeZone
        return formatter.date(from: stamp)!
    }
    static let duringSession = ist("2026-09-04 11:00")
    static let afterHours = ist("2026-09-05 11:00")

    @discardableResult
    func rest(_ symbol: String, isBuy: Bool, quantity: Int, limit: Double,
              expiresAt: Date? = nil) -> LimitOrder {
        let order = LimitOrder(symbol: symbol, companyName: symbol, isBuy: isBuy,
                               quantity: quantity, limitPrice: limit, expiresAt: expiresAt)
        context.insert(order)
        try? context.save()
        return order
    }

    func buy(_ symbol: String, quantity: Int, price: Double) async throws {
        try await manager.addStock(symbol: symbol, companyName: symbol,
                                   quantity: quantity, buyPrice: price, modelContext: context)
    }

    var cash: Double { manager.settings(in: context).availableCash }
    var trades: [Trade] { (try? context.fetch(FetchDescriptor<Trade>())) ?? [] }
    func holding(_ symbol: String) -> PortfolioHolding? {
        ((try? context.fetch(FetchDescriptor<PortfolioHolding>())) ?? []).first { $0.symbol == symbol }
    }
}


@MainActor
struct LimitOrderFillTests {

    @Test("A buy limit that is reached fills, debits cash and records the trade")
    func buyFills() async throws {
        let desk = try Desk()
        let opening = desk.cash
        let order = desk.rest("RELIANCE", isBuy: true, quantity: 10, limit: 1_250)

        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: Desk.duringSession, quoteSource: { _ in ["RELIANCE": 1_240] }
        )

        #expect(order.state == .filled)
        #expect(desk.holding("RELIANCE")?.quantity == 10)
        #expect(abs(desk.cash - (opening - 12_500)) < 0.001)

        let trade = try #require(desk.trades.first)
        #expect(trade.isBuy == true)
        #expect(abs(trade.price - 1_250) < 0.001)
    }

    @Test("The fill is at the limit, not at whatever price was observed")
    func fillsAtTheLimitNotTheQuote() async throws {
        let desk = try Desk()
        let opening = desk.cash
        let order = desk.rest("RELIANCE", isBuy: true, quantity: 10, limit: 1_250)

        // Quotes are sampled, so by the time an order looks fillable the market may have
        // run well past it. Filling at 1,180 would hand back a price that a real order,
        // executing as it crossed, could never have got.
        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: Desk.duringSession, quoteSource: { _ in ["RELIANCE": 1_180] }
        )

        #expect(order.filledPrice == 1_250)
        #expect(abs(desk.cash - (opening - 12_500)) < 0.001)
    }

    @Test("A sell limit that is reached credits proceeds and books P&L at the limit")
    func sellFills() async throws {
        let desk = try Desk()
        try await desk.buy("TCS", quantity: 10, price: 2_000)
        let afterBuy = desk.cash

        let order = desk.rest("TCS", isBuy: false, quantity: 4, limit: 2_400)

        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: Desk.duringSession, quoteSource: { _ in ["TCS": 2_450] }
        )

        #expect(order.state == .filled)
        #expect(desk.holding("TCS")?.quantity == 6)          // partial, position stays open
        #expect(abs(desk.cash - (afterBuy + 9_600)) < 0.001) // 4 x 2,400

        let sell = try #require(desk.trades.first { !$0.isBuy })
        #expect(abs((sell.realizedPnL ?? 0) - 1_600) < 0.001) // (2,400 - 2,000) x 4
    }

    @Test("An order the market hasn't reached stays resting")
    func unreachedOrderStaysOpen() async throws {
        let desk = try Desk()
        let order = desk.rest("RELIANCE", isBuy: true, quantity: 10, limit: 1_250)

        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: Desk.duringSession, quoteSource: { _ in ["RELIANCE": 1_322] }
        )

        #expect(order.isOpen == true)
        #expect(desk.holding("RELIANCE") == nil)
        #expect(desk.trades.isEmpty)
    }

    @Test("Nothing fills outside a session, even at a price that would fill")
    func nothingFillsWhenClosed() async throws {
        let desk = try Desk()
        let order = desk.rest("RELIANCE", isBuy: true, quantity: 10, limit: 1_250)

        // Yahoo serves the last close out of hours; without the gate this would execute.
        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: Desk.afterHours, quoteSource: { _ in ["RELIANCE": 1_240] }
        )

        #expect(order.isOpen == true)
        #expect(desk.trades.isEmpty)
    }

    @Test("A day order that outlived its session expires instead of filling")
    func expiredOrderDoesNotFill() async throws {
        let desk = try Desk()
        let order = desk.rest("RELIANCE", isBuy: true, quantity: 10, limit: 1_250,
                              expiresAt: Desk.duringSession.addingTimeInterval(-3_600))

        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: Desk.duringSession, quoteSource: { _ in ["RELIANCE": 1_240] }
        )

        #expect(order.state == .expired)
        #expect(desk.trades.isEmpty)
    }

    @Test("Expiry is swept even out of hours, so a stale order can't fill days later")
    func expirySweepsWhenClosed() async throws {
        let desk = try Desk()
        let order = desk.rest("RELIANCE", isBuy: true, quantity: 10, limit: 1_250,
                              expiresAt: Desk.duringSession)

        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: Desk.afterHours, quoteSource: { _ in [:] }
        )

        #expect(order.state == .expired)
    }

    @Test("A cancelled order is never revisited")
    func cancelledOrdersAreIgnored() async throws {
        let desk = try Desk()
        let order = desk.rest("RELIANCE", isBuy: true, quantity: 10, limit: 1_250)
        LimitOrderService.cancel(order, modelContext: desk.context)

        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: Desk.duringSession, quoteSource: { _ in ["RELIANCE": 1_240] }
        )

        #expect(order.state == .cancelled)
        #expect(desk.trades.isEmpty)
    }
}


@MainActor
struct LimitOrderFailureTests {

    @Test("A buy that can no longer be afforded fails with a reason, not silently")
    func unaffordableBuyFails() async throws {
        let desk = try Desk()
        let order = desk.rest("RELIANCE", isBuy: true, quantity: 10_000, limit: 1_250)

        let outcome = await LimitOrderService.execute(order, manager: desk.manager,
                                                      modelContext: desk.context)

        #expect(order.state == .failed)
        #expect(order.failureReason?.isEmpty == false)
        #expect(desk.holding("RELIANCE") == nil)
        if case .failed = outcome {} else { Issue.record("expected a failure outcome") }
    }

    @Test("A sell of shares that are already gone fails rather than inventing them")
    func sellWithoutSharesFails() async throws {
        let desk = try Desk()
        let order = desk.rest("INFY", isBuy: false, quantity: 5, limit: 1_200)

        let outcome = await LimitOrderService.execute(order, manager: desk.manager,
                                                      modelContext: desk.context)

        #expect(order.state == .failed)
        #expect(desk.holding("INFY") == nil)
        #expect(desk.trades.isEmpty)
        if case .failed = outcome {} else { Issue.record("expected a failure outcome") }
    }

    @Test("Selling more than is held fails and leaves the position untouched")
    func oversizedSellFails() async throws {
        let desk = try Desk()
        try await desk.buy("INFY", quantity: 5, price: 1_000)
        let afterBuy = desk.cash

        let order = desk.rest("INFY", isBuy: false, quantity: 20, limit: 1_100)
        _ = await LimitOrderService.execute(order, manager: desk.manager, modelContext: desk.context)

        #expect(order.state == .failed)
        #expect(desk.holding("INFY")?.quantity == 5)
        #expect(abs(desk.cash - afterBuy) < 0.001)
    }

    @Test("A failed order is done, not retried on the next check")
    func failedOrdersAreNotRetried() async throws {
        let desk = try Desk()
        let order = desk.rest("RELIANCE", isBuy: true, quantity: 10_000, limit: 1_250)
        _ = await LimitOrderService.execute(order, manager: desk.manager, modelContext: desk.context)

        // Even with plenty of cash and a filling price, a failed order stays failed.
        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: Desk.duringSession, quoteSource: { _ in ["RELIANCE": 1_000] }
        )

        #expect(order.state == .failed)
        #expect(desk.trades.isEmpty)
    }

    @Test("One order failing doesn't stop the others being filled")
    func oneFailureDoesNotBlockTheRest() async throws {
        let desk = try Desk()
        desk.rest("RELIANCE", isBuy: true, quantity: 10_000, limit: 1_250)  // unaffordable
        let affordable = desk.rest("TCS", isBuy: true, quantity: 2, limit: 2_000)

        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: Desk.duringSession,
            quoteSource: { _ in ["RELIANCE": 1_240, "TCS": 1_990] }
        )

        #expect(affordable.state == .filled)
        #expect(desk.holding("TCS")?.quantity == 2)
    }
}
