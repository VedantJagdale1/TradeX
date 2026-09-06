//
//  StopOrderTests.swift
//  TradeXTests
//

import Foundation
import SwiftData
import Testing
@testable import TradeX

struct StopTriggerTests {

    private func order(buy: Bool, kind: LimitOrder.Kind, price: Double,
                       trail: Double? = nil) -> LimitOrder {
        LimitOrder(symbol: "RELIANCE", companyName: "Reliance Industries Limited",
                   isBuy: buy, quantity: 10, limitPrice: price,
                   kind: kind, trailPercent: trail)
    }

    @Test("A stop-loss triggers on the way down, the opposite of a sell limit")
    func sellStopTriggersBelow() {
        let stop = order(buy: false, kind: .stop, price: 1_250)
        #expect(stop.wouldFill(at: 1_200) == true)
        #expect(stop.wouldFill(at: 1_250) == true)
        #expect(stop.wouldFill(at: 1_251) == false)

        // Getting this inversion wrong turns a stop-loss into a take-profit.
        let limit = order(buy: false, kind: .limit, price: 1_250)
        #expect(limit.wouldFill(at: 1_200) == false)
        #expect(limit.wouldFill(at: 1_300) == true)
    }

    @Test("A buy stop triggers on the way up, the opposite of a buy limit")
    func buyStopTriggersAbove() {
        let stop = order(buy: true, kind: .stop, price: 1_400)
        #expect(stop.wouldFill(at: 1_450) == true)
        #expect(stop.wouldFill(at: 1_400) == true)
        #expect(stop.wouldFill(at: 1_399) == false)

        let limit = order(buy: true, kind: .limit, price: 1_400)
        #expect(limit.wouldFill(at: 1_450) == false)
        #expect(limit.wouldFill(at: 1_350) == true)
    }

    @Test("A trailing sell follows the price up and never gives ground")
    func trailRatchetsUpOnly() {
        let trail = order(buy: false, kind: .trailingStop, price: 0, trail: 10)

        trail.updateTrail(with: 1_000)
        #expect(abs(trail.limitPrice - 900) < 0.001)

        trail.updateTrail(with: 1_200)          // new high, trigger follows
        #expect(abs(trail.limitPrice - 1_080) < 0.001)

        trail.updateTrail(with: 1_100)          // pullback — must not loosen
        #expect(abs(trail.limitPrice - 1_080) < 0.001)
        #expect(abs((trail.extremePrice ?? 0) - 1_200) < 0.001)
    }

    @Test("A trailing buy follows the price down and never gives ground")
    func trailingBuyRatchetsDown() {
        let trail = order(buy: true, kind: .trailingStop, price: 0, trail: 10)

        trail.updateTrail(with: 1_000)
        #expect(abs(trail.limitPrice - 1_100) < 0.001)

        trail.updateTrail(with: 800)
        #expect(abs(trail.limitPrice - 880) < 0.001)

        trail.updateTrail(with: 900)            // bounce — trigger holds
        #expect(abs(trail.limitPrice - 880) < 0.001)
    }

    @Test("The ratchet reports whether it actually moved")
    func trailReportsMovement() {
        let trail = order(buy: false, kind: .trailingStop, price: 0, trail: 5)
        #expect(trail.updateTrail(with: 1_000) == true)
        #expect(trail.updateTrail(with: 900) == false)
        #expect(trail.updateTrail(with: 1_100) == true)
    }

    @Test("Only trailing orders trail")
    func nonTrailingOrdersDoNotMove() {
        let stop = order(buy: false, kind: .stop, price: 1_250)
        #expect(stop.updateTrail(with: 2_000) == false)
        #expect(abs(stop.limitPrice - 1_250) < 0.001)
    }

    @Test("Stops describe themselves as stops, not as limits")
    func descriptionsAreDistinct() {
        #expect(order(buy: false, kind: .stop, price: 1_250).conditionDescription.contains("falls to"))
        #expect(order(buy: true, kind: .stop, price: 1_400).conditionDescription.contains("rises to"))
        #expect(order(buy: false, kind: .limit, price: 1_400).conditionDescription.contains("or better"))
    }
}


@MainActor
struct StopExecutionTests {

    private struct Desk {
        let context: ModelContext
        let manager: PortfolioManager

        init() throws {
            let container = try ModelContainer(
                for: PortfolioHolding.self, UserSettings.self, Trade.self,
                CashAdjustment.self, PortfolioSnapshot.self, WatchlistItem.self,
                PriceAlert.self, LimitOrder.self, StoredChatMessage.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            context = ModelContext(container)
            manager = PortfolioManager()
            manager.quoteProvider = { _ in nil }
        }

        static let duringSession: Date = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            f.timeZone = MarketSession.exchangeTimeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.date(from: "2026-09-07 11:00")!     // a Monday
        }()

        func buy(_ symbol: String, quantity: Int, price: Double) async throws {
            try await manager.addStock(symbol: symbol, companyName: symbol,
                                       quantity: quantity, buyPrice: price, modelContext: context)
        }

        @discardableResult
        func rest(_ symbol: String, isBuy: Bool, quantity: Int, price: Double,
                  kind: LimitOrder.Kind, trail: Double? = nil) -> LimitOrder {
            let order = LimitOrder(symbol: symbol, companyName: symbol, isBuy: isBuy,
                                   quantity: quantity, limitPrice: price,
                                   kind: kind, trailPercent: trail)
            context.insert(order)
            try? context.save()
            return order
        }

        func check(_ quotes: [String: Double]) async {
            await LimitOrderService.checkAll(
                modelContext: context, manager: manager,
                now: Self.duringSession, quoteSource: { _ in quotes }
            )
        }

        var cash: Double { manager.settings(in: context).availableCash }
        var trades: [Trade] { (try? context.fetch(FetchDescriptor<Trade>())) ?? [] }
        func holding(_ s: String) -> PortfolioHolding? {
            ((try? context.fetch(FetchDescriptor<PortfolioHolding>())) ?? []).first { $0.symbol == s }
        }
    }

    @Test("A stop fills at the market, not at the stop price")
    func stopFillsAtMarketNotAtStop() async throws {
        let desk = try Desk()
        try await desk.buy("TCS", quantity: 10, price: 2_000)
        desk.holding("TCS")?.currentPrice = 2_000
        let order = desk.rest("TCS", isBuy: false, quantity: 10, price: 1_900, kind: .stop)

        // The market gapped through the stop. A stop becomes a market order when it
        // triggers, so this is what it actually gets — pretending it filled at 1,900
        // would teach that a stop guarantees a price.
        await desk.check(["TCS": 1_850])

        #expect(order.state == .filled)
        #expect(order.filledPrice == 1_850)

        let sell = try #require(desk.trades.first { !$0.isBuy })
        #expect(abs((sell.realizedPnL ?? 0) + 1_500) < 0.001)   // (1,850 - 2,000) x 10
    }

    @Test("A limit still fills at its limit, unlike a stop")
    func limitStillFillsAtItsLimit() async throws {
        let desk = try Desk()
        let order = desk.rest("RELIANCE", isBuy: true, quantity: 10, price: 1_250, kind: .limit)

        await desk.check(["RELIANCE": 1_180])

        #expect(order.filledPrice == 1_250)
    }

    @Test("A stop-loss above the market doesn't wait around")
    func stopLossTriggersOnADrop() async throws {
        let desk = try Desk()
        try await desk.buy("INFY", quantity: 10, price: 1_100)
        desk.holding("INFY")?.currentPrice = 1_100
        let stop = desk.rest("INFY", isBuy: false, quantity: 10, price: 1_000, kind: .stop)

        await desk.check(["INFY": 1_050])       // above the stop, still resting
        #expect(stop.isOpen == true)

        await desk.check(["INFY": 990])         // through it
        #expect(stop.state == .filled)
        #expect(desk.holding("INFY") == nil)
    }

    @Test("A trailing stop ratchets during checks and fires only on a real reversal")
    func trailingStopRatchetsThenFires() async throws {
        let desk = try Desk()
        try await desk.buy("TMCV", quantity: 10, price: 400)
        desk.holding("TMCV")?.currentPrice = 400

        let trail = desk.rest("TMCV", isBuy: false, quantity: 10, price: 0,
                              kind: .trailingStop, trail: 10)
        trail.updateTrail(with: 400)            // placed at the market
        #expect(abs(trail.limitPrice - 360) < 0.001)

        await desk.check(["TMCV": 500])         // rally: trigger follows to 450
        #expect(trail.isOpen == true)
        #expect(abs(trail.limitPrice - 450) < 0.001)

        await desk.check(["TMCV": 470])         // 6% pullback — not enough
        #expect(trail.isOpen == true)
        #expect(abs(trail.limitPrice - 450) < 0.001)

        await desk.check(["TMCV": 440])         // through the trigger
        #expect(trail.state == .filled)

        // Locked in a gain the position never would have kept with a fixed stop at 360.
        let sell = try #require(desk.trades.first { !$0.isBuy })
        #expect((sell.realizedPnL ?? 0) > 0)
    }

    @Test("A buy stop enters on a breakout")
    func buyStopEntersOnBreakout() async throws {
        let desk = try Desk()
        let stop = desk.rest("RELIANCE", isBuy: true, quantity: 5, price: 1_400, kind: .stop)

        await desk.check(["RELIANCE": 1_350])
        #expect(stop.isOpen == true)

        await desk.check(["RELIANCE": 1_420])
        #expect(stop.state == .filled)
        #expect(desk.holding("RELIANCE")?.quantity == 5)
    }

    @Test("Stops obey the session gate like every other order")
    func stopsDoNotFillWhenClosed() async throws {
        let desk = try Desk()
        try await desk.buy("INFY", quantity: 10, price: 1_100)
        let stop = desk.rest("INFY", isBuy: false, quantity: 10, price: 1_000, kind: .stop)

        let saturday = Desk.duringSession.addingTimeInterval(-2 * 86_400)
        await LimitOrderService.checkAll(
            modelContext: desk.context, manager: desk.manager,
            now: saturday, quoteSource: { _ in ["INFY": 900] }
        )

        #expect(stop.isOpen == true)
    }
}
