//
//  OrderLogicTests.swift
//  TradeXTests
//

import Foundation
import Testing
@testable import TradeX

/// Buy-below / sell-above is the convention that transfers to a real broker, and it is
/// the one most easily inverted by a refactor.
struct LimitOrderTests {

    private func order(buy: Bool, quantity: Int = 10, limit: Double) -> LimitOrder {
        LimitOrder(symbol: "RELIANCE", companyName: "Reliance Industries Limited",
                   isBuy: buy, quantity: quantity, limitPrice: limit)
    }

    @Test("A buy limit fills at or below its price, never above")
    func buyFillsBelow() {
        let buy = order(buy: true, limit: 1250)
        #expect(buy.wouldFill(at: 1200) == true)
        #expect(buy.wouldFill(at: 1250) == true)     // "or better" includes the limit
        #expect(buy.wouldFill(at: 1251) == false)
        #expect(buy.wouldFill(at: 1322) == false)
    }

    @Test("A sell limit fills at or above its price, never below")
    func sellFillsAbove() {
        let sell = order(buy: false, limit: 1400)
        #expect(sell.wouldFill(at: 1450) == true)
        #expect(sell.wouldFill(at: 1400) == true)
        #expect(sell.wouldFill(at: 1399) == false)
        #expect(sell.wouldFill(at: 1322) == false)
    }

    @Test("Only a resting buy ties up cash")
    func onlyBuysReserveCash() {
        #expect(order(buy: true, quantity: 10, limit: 1250).reservedCash == 12_500)
        #expect(order(buy: false, quantity: 10, limit: 1400).reservedCash == 0)
    }

    @Test("A GTC order never expires; a day order expires at its close")
    func expiry() {
        let gtc = order(buy: true, limit: 1250)
        #expect(gtc.hasExpired() == false)

        let day = LimitOrder(symbol: "TCS", companyName: "Tata Consultancy Services Limited",
                             isBuy: true, quantity: 1, limitPrice: 2000,
                             expiresAt: Date(timeIntervalSinceNow: -60))
        #expect(day.hasExpired() == true)

        let live = LimitOrder(symbol: "TCS", companyName: "Tata Consultancy Services Limited",
                              isBuy: true, quantity: 1, limitPrice: 2000,
                              expiresAt: Date(timeIntervalSinceNow: 3_600))
        #expect(live.hasExpired() == false)
    }

    @Test("Only open, unexpired orders are worth pricing")
    func armedState() {
        let open = order(buy: true, limit: 1250)
        #expect(open.isOpen == true)

        open.state = .filled
        #expect(open.isOpen == false)
    }
}

/// Alerts read the opposite way round to limit orders, deliberately.
struct PriceAlertTests {

    @Test("A rise alert triggers on the way up")
    func riseAlert() {
        let alert = PriceAlert(symbol: "INFY", companyName: "Infosys Limited",
                               targetPrice: 1200, isAbove: true)
        #expect(alert.hasMet(price: 1200) == true)
        #expect(alert.hasMet(price: 1250) == true)
        #expect(alert.hasMet(price: 1199) == false)
    }

    @Test("A fall alert triggers on the way down")
    func fallAlert() {
        let alert = PriceAlert(symbol: "INFY", companyName: "Infosys Limited",
                               targetPrice: 1000, isAbove: false)
        #expect(alert.hasMet(price: 1000) == true)
        #expect(alert.hasMet(price: 950) == true)
        #expect(alert.hasMet(price: 1001) == false)
    }

    @Test("A triggered alert is no longer armed, so it fires once")
    func firesOnce() {
        let alert = PriceAlert(symbol: "INFY", companyName: "Infosys Limited",
                               targetPrice: 1200, isAbove: true)
        #expect(alert.isArmed == true)

        alert.triggeredAt = Date()
        #expect(alert.isArmed == false)
        #expect(alert.isTriggered == true)
    }
}

/// Position arithmetic, including the partial-sell case.
struct HoldingTests {

    @Test("P&L is measured against average cost")
    func profitAndLoss() {
        let holding = PortfolioHolding(symbol: "TCS", companyName: "Tata Consultancy Services Limited",
                                       quantity: 10, avgBuyPrice: 2088, currentPrice: 2308.40)
        #expect(abs(holding.investedAmount - 20_880) < 0.001)
        #expect(abs(holding.currentValue - 23_084) < 0.001)
        #expect(abs(holding.totalPNL - 2_204) < 0.001)
        #expect(abs(holding.pnlPercentage - 10.555) < 0.01)
        #expect(holding.isProfit == true)
    }

    @Test("A position bought and never moved is flat, not a loss")
    func breakEvenCountsAsFlat() {
        let holding = PortfolioHolding(symbol: "TMCV", companyName: "Tata Motors Limited",
                                       quantity: 6, avgBuyPrice: 467.10, currentPrice: 467.10)
        #expect(holding.totalPNL == 0)
        #expect(holding.isProfit == true)
    }

    @Test("An empty position can't divide by zero")
    func zeroInvestedIsSafe() {
        let holding = PortfolioHolding(symbol: "X", companyName: "X",
                                       quantity: 0, avgBuyPrice: 0, currentPrice: 100)
        #expect(holding.pnlPercentage == 0)
    }
}
