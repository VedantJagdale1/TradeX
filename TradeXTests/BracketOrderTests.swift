//
//  BracketOrderTests.swift
//  TradeXTests
//

import Foundation
import SwiftData
import Testing
@testable import TradeX

/// A held position with an exit plan attached, exercised without the network.
@MainActor
private struct Bracketed {
    let context: ModelContext
    let manager: PortfolioManager
    let holding: PortfolioHolding

    init(entry: Double = 1_000, quantity: Int = 10, mark: Double? = nil) async throws {
        let container = try ModelContainer(
            for: PortfolioHolding.self, UserSettings.self, Trade.self,
            CashAdjustment.self, PortfolioSnapshot.self, WatchlistItem.self,
            PriceAlert.self, LimitOrder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        manager = PortfolioManager()
        manager.quoteProvider = { _ in nil }

        // These suites assert exact cash movements, so they trade at clean prices.
        // Charges have their own suite; mixing the two would make every arithmetic
        // assertion here a test of the tax code as well.
        manager.settings(in: context).brokerProfile = .none

        try await manager.addStock(symbol: "RELIANCE", companyName: "Reliance",
                                   quantity: quantity, buyPrice: entry, modelContext: context)
        holding = ((try? context.fetch(FetchDescriptor<PortfolioHolding>())) ?? []).first!
        if let mark { holding.currentPrice = mark }
    }

    var orders: [LimitOrder] {
        ((try? context.fetch(FetchDescriptor<LimitOrder>())) ?? [])
            .sorted { $0.limitPrice > $1.limitPrice }
    }
    var open: [LimitOrder] { orders.filter(\.isOpen) }

    @discardableResult
    func protect(quantity: Int = 10, target: Double = 1_100,
                 stop: Double? = 950, trail: Double? = nil) -> String? {
        LimitOrderService.protectPosition(
            holding: holding, quantity: quantity, targetPrice: target,
            stopPrice: stop, trailPercent: trail, thesis: "", modelContext: context
        )
    }

    func check(at price: Double) async {
        await LimitOrderService.checkAll(
            modelContext: context, manager: manager,
            now: Bracketed.duringSession, quoteSource: { _ in ["RELIANCE": price] }
        )
    }

    static let duringSession: Date = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = MarketSession.exchangeTimeZone
        return formatter.date(from: "2026-09-04 11:00")!
    }()
}


@MainActor
struct BracketPlacementTests {

    @Test("Protecting a position rests a target and a stop sharing one group")
    func placesBothLegs() async throws {
        let desk = try await Bracketed()
        #expect(desk.protect() == nil)

        let orders = desk.orders
        #expect(orders.count == 2)
        #expect(orders.allSatisfy { !$0.isBuy && $0.quantity == 10 })

        let group = try #require(orders.first?.groupID)
        #expect(orders.allSatisfy { $0.groupID == group })
        #expect(orders.map(\.kind) == [.limit, .stop])
    }

    @Test("A target below the market is rejected rather than filling instantly")
    func rejectsInvertedTarget() async throws {
        let desk = try await Bracketed()
        #expect(desk.protect(target: 900) != nil)
        #expect(desk.orders.isEmpty)
    }

    @Test("A stop above the market is rejected")
    func rejectsInvertedStop() async throws {
        let desk = try await Bracketed()
        #expect(desk.protect(stop: 1_050) != nil)
        #expect(desk.orders.isEmpty)
    }

    @Test("A plan with no downside leg is refused")
    func requiresProtection() async throws {
        let desk = try await Bracketed()
        #expect(desk.protect(stop: nil, trail: nil) != nil)
        #expect(desk.orders.isEmpty)
    }

    @Test("A bracket cannot cover more shares than are free")
    func respectsFreeShares() async throws {
        let desk = try await Bracketed(quantity: 10)
        #expect(desk.protect(quantity: 25) != nil)
        #expect(desk.orders.isEmpty)
    }

    @Test("A bracket reserves the shares once, not once per leg")
    func reservesSharesOnce() async throws {
        let desk = try await Bracketed(quantity: 1, mark: 1_000)
        desk.protect(quantity: 1, target: 1_100, stop: 950)

        // Both legs cover the same share. Summing them would report the position as
        // twice committed and leave nothing sellable.
        #expect(desk.manager.reservedShares(symbol: "RELIANCE", in: desk.context) == 1)
        #expect(desk.manager.freeShares(for: desk.holding, in: desk.context) == 0)
    }

    @Test("A bracket alongside a standalone order reserves the sum of both")
    func mixesGroupedAndLoneOrders() async throws {
        let desk = try await Bracketed(quantity: 10, mark: 1_000)
        desk.protect(quantity: 4, target: 1_100, stop: 950)

        let loner = LimitOrder(symbol: "RELIANCE", companyName: "Reliance", isBuy: false,
                               quantity: 3, limitPrice: 1_200)
        desk.context.insert(loner)
        try desk.context.save()

        #expect(desk.manager.reservedShares(symbol: "RELIANCE", in: desk.context) == 7)
    }

    @Test("A trailing leg starts its high water mark at today's price")
    func trailingSeedsExtreme() async throws {
        let desk = try await Bracketed(entry: 1_000, mark: 1_000)
        #expect(desk.protect(stop: nil, trail: 10) == nil)

        let trailing = try #require(desk.orders.first { $0.kind == .trailingStop })
        #expect(trailing.extremePrice == 1_000)
        #expect(abs(trailing.limitPrice - 900) < 0.001)
    }
}


@MainActor
struct BracketExclusivityTests {

    @Test("The target filling cancels the stop, so the position is sold once")
    func targetFillCancelsStop() async throws {
        let desk = try await Bracketed(entry: 1_000, quantity: 10)
        desk.protect(target: 1_100, stop: 950)

        await desk.check(at: 1_120)

        let target = try #require(desk.orders.first { $0.kind == .limit })
        let stop = try #require(desk.orders.first { $0.kind == .stop })
        #expect(target.state == .filled)
        #expect(stop.state == .cancelled)
        #expect(desk.holdingQuantity == 0)
    }

    @Test("The stop firing cancels the target")
    func stopFillCancelsTarget() async throws {
        let desk = try await Bracketed(entry: 1_000, quantity: 10)
        desk.protect(target: 1_100, stop: 950)

        await desk.check(at: 940)

        let target = try #require(desk.orders.first { $0.kind == .limit })
        let stop = try #require(desk.orders.first { $0.kind == .stop })
        #expect(stop.state == .filled)
        #expect(target.state == .cancelled)
    }

    @Test("A filled target leaves no stop to fire against a position rebuilt later")
    func retiredLegCannotFireLater() async throws {
        let desk = try await Bracketed(entry: 1_000, quantity: 10)
        desk.protect(target: 1_100, stop: 950)

        // The two legs can never trigger on the same price — a sell target needs
        // 1,100 or more and a sell stop 950 or less. The exposure is across days:
        // the target fills, the position is rebuilt, and an orphaned stop then sells
        // shares the exit plan was never written for.
        await desk.check(at: 1_120)
        #expect(desk.sellTrades.count == 1)

        try await desk.manager.addStock(symbol: "RELIANCE", companyName: "Reliance",
                                        quantity: 10, buyPrice: 1_120,
                                        modelContext: desk.context)
        await desk.check(at: 940)

        #expect(desk.sellTrades.count == 1)
        #expect(desk.holdingQuantity == 10)
    }

    @Test("Cancelling one leg by hand retires the whole bracket")
    func manualCancelTakesBoth() async throws {
        let desk = try await Bracketed()
        desk.protect()

        let target = try #require(desk.orders.first { $0.kind == .limit })
        LimitOrderService.cancel(target, modelContext: desk.context)

        #expect(desk.open.isEmpty)
    }

    @Test("A standalone order has no siblings to disturb")
    func ungroupedOrdersAreUnaffected() async throws {
        let desk = try await Bracketed()
        desk.protect(quantity: 5, target: 1_100, stop: 950)

        let loner = LimitOrder(symbol: "TCS", companyName: "TCS", isBuy: false,
                               quantity: 1, limitPrice: 4_000)
        desk.context.insert(loner)
        try desk.context.save()

        LimitOrderService.cancel(loner, modelContext: desk.context)
        #expect(desk.open.count == 2)
    }

    @Test("A leg that fails to execute does not leave its sibling armed")
    func failedLegRetiresTheBracket() async throws {
        let desk = try await Bracketed(entry: 1_000, quantity: 10)
        desk.protect(quantity: 10, target: 1_100, stop: 950)

        // The shares are sold out from under the resting bracket.
        try desk.manager.sellStock(desk.holding, quantity: 10, modelContext: desk.context)

        await desk.check(at: 1_120)

        #expect(desk.open.isEmpty)
        #expect(desk.orders.contains { $0.state == .failed })
    }
}


private extension Bracketed {
    var holdingQuantity: Int {
        ((try? context.fetch(FetchDescriptor<PortfolioHolding>())) ?? [])
            .first { $0.symbol == "RELIANCE" }?.quantity ?? 0
    }
    var sellTrades: [Trade] {
        ((try? context.fetch(FetchDescriptor<Trade>())) ?? []).filter { !$0.isBuy }
    }
}
