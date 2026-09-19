//
//  TransactionCostTests.swift
//  TradeXTests
//

import Foundation
import SwiftData
import Testing
@testable import TradeX

@MainActor
private struct Billed {
    let context: ModelContext
    let manager: PortfolioManager

    init(profile: BrokerProfile = .discount, cash: Double? = nil) throws {
        let container = try ModelContainer(
            for: PortfolioHolding.self, UserSettings.self, Trade.self,
            CashAdjustment.self, PortfolioSnapshot.self, WatchlistItem.self,
            PriceAlert.self, LimitOrder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        manager = PortfolioManager()
        manager.quoteProvider = { _ in nil }

        let settings = manager.settings(in: context)
        settings.brokerProfile = profile
        if let cash { settings.availableCash = cash }
    }

    var cash: Double { manager.settings(in: context).availableCash }
    var trades: [Trade] {
        ((try? context.fetch(FetchDescriptor<Trade>())) ?? [])
            .sorted { $0.timestamp < $1.timestamp }
    }
    func holding(_ symbol: String) -> PortfolioHolding? {
        ((try? context.fetch(FetchDescriptor<PortfolioHolding>())) ?? []).first { $0.symbol == symbol }
    }
}


struct CostScheduleTests {

    /// Hand-checked against the components a discount broker itemises on a contract
    /// note, so a change to any rate shows up as a failure here rather than silently
    /// in someone's P&L.
    @Test("A discount buy is billed component by component")
    func discountBuyBreakdown() {
        let bill = CostSchedule.discountDelivery.charges(isBuy: true, quantity: 10, price: 1_000)

        #expect(bill.brokerage == 0)
        #expect(abs(bill.stt - 10.0) < 0.0001)
        #expect(abs(bill.exchange - 0.30) < 0.0001)
        #expect(abs(bill.sebi - 0.01) < 0.0001)
        #expect(abs(bill.stampDuty - 1.50) < 0.0001)
        #expect(abs(bill.gst - 0.06) < 0.0001)
        #expect(bill.dpCharge == 0)
        #expect(abs(bill.total - 11.87) < 0.0001)
    }

    @Test("The itemisation adds up to the amount billed")
    func itemsSumToTotal() {
        for (isBuy, quantity, price) in [(true, 10, 1_000.0), (false, 1, 500.0),
                                         (false, 7, 1_226.40), (true, 3, 17.35)] {
            for schedule in [CostSchedule.discountDelivery, .fullService] {
                let bill = schedule.charges(isBuy: isBuy, quantity: quantity, price: price)
                let shown = bill.items.reduce(0) { $0 + $1.amount }

                // Anyone can add the column on screen. If it disagreed with the total
                // by a paisa, every other figure in the app would look suspect too.
                #expect(abs(shown - bill.total) < 0.0001)
            }
        }
    }

    @Test("A discount sell swaps stamp duty for the depository's flat fee")
    func discountSellBreakdown() {
        let bill = CostSchedule.discountDelivery.charges(isBuy: false, quantity: 10, price: 1_000)

        #expect(bill.stampDuty == 0)
        #expect(abs(bill.dpCharge - 15.93) < 0.0001)
        #expect(abs(bill.total - 26.30) < 0.0001)
    }

    @Test("GST rides on the services, never on the taxes")
    func gstExcludesTaxes() {
        let bill = CostSchedule.fullService.charges(isBuy: true, quantity: 10, price: 1_000)
        let services = bill.brokerage + bill.exchange + bill.sebi

        #expect(abs(bill.gst - services * 0.18) < 0.01)
        // Taxing STT and stamp duty too would inflate this by roughly ₹2.
        #expect(bill.gst < (services + bill.stt + bill.stampDuty) * 0.18)
    }

    @Test("Brokerage is capped per order")
    func brokerageCap() {
        var schedule = CostSchedule.discountDelivery
        schedule.brokeragePercent = 0.03
        schedule.brokerageCap = 20

        // 0.03% of 10 lakh would be ₹300 without the cap.
        let bill = schedule.charges(isBuy: true, quantity: 100, price: 10_000)
        #expect(abs(bill.brokerage - 20) < 0.0001)
    }

    @Test("The flat depository fee dominates a small sell")
    func smallTradesAreExpensive() {
        let bill = CostSchedule.discountDelivery.charges(isBuy: false, quantity: 1, price: 500)
        let percentOfTurnover = bill.total / 500 * 100

        // Over 3% to get out of a ₹500 position — the reason small, frequent trades
        // lose money even when the calls are right.
        #expect(percentOfTurnover > 3.0)
        #expect(bill.dpCharge > bill.total - bill.dpCharge)
    }

    @Test("Nothing is billed on an empty or nonsensical order")
    func degenerateOrdersAreFree() {
        let schedule = CostSchedule.discountDelivery
        #expect(schedule.charges(isBuy: true, quantity: 0, price: 1_000).isZero)
        #expect(schedule.charges(isBuy: true, quantity: 10, price: 0).isZero)
        #expect(schedule.charges(isBuy: false, quantity: -5, price: 1_000).isZero)
    }

    @Test("The no-charges profile bills nothing")
    func noneProfileIsFree() {
        #expect(CostSchedule.none.charges(isBuy: true, quantity: 100, price: 5_000).isZero)
        #expect(CostSchedule.none.charges(isBuy: false, quantity: 100, price: 5_000).isZero)
    }

    @Test("Only rows with something in them are shown")
    func breakdownHidesEmptyRows() {
        let labels = CostSchedule.discountDelivery
            .charges(isBuy: true, quantity: 10, price: 1_000)
            .items.map(\.label)

        #expect(!labels.contains("Brokerage"))   // zero on discount delivery
        #expect(!labels.contains("DP charges"))  // sell-side only
        #expect(labels.contains("STT"))
        #expect(labels.contains("Stamp duty"))
    }
}


@MainActor
struct ChargedTradingTests {

    @Test("A buy debits the turnover plus the charges")
    func buyDebitsCharges() async throws {
        let account = try Billed(profile: .discount)
        let opening = account.cash

        try await account.manager.addStock(symbol: "RELIANCE", companyName: "Reliance",
                                           quantity: 10, buyPrice: 1_000,
                                           modelContext: account.context)

        #expect(abs(account.cash - (opening - 10_011.87)) < 0.01)
        #expect(abs((account.trades.first?.charges ?? 0) - 11.87) < 0.01)
    }

    @Test("Average cost stays the executed price, not the billed one")
    func chargesStayOutOfCostBasis() async throws {
        let account = try Billed(profile: .fullService)
        try await account.manager.addStock(symbol: "TCS", companyName: "TCS",
                                           quantity: 10, buyPrice: 1_000,
                                           modelContext: account.context)

        // Folding charges into the basis would hide them; they are reported instead.
        #expect(account.holding("TCS")?.avgBuyPrice == 1_000)
        #expect((account.trades.first?.charges ?? 0) > 47)
    }

    @Test("A sell credits the turnover less the charges")
    func sellCreditsNetOfCharges() async throws {
        let account = try Billed(profile: .discount)
        try await account.manager.addStock(symbol: "RELIANCE", companyName: "Reliance",
                                           quantity: 10, buyPrice: 1_000,
                                           modelContext: account.context)
        let beforeSale = account.cash
        let holding = try #require(account.holding("RELIANCE"))

        try account.manager.sellStock(holding, quantity: 10, modelContext: account.context)

        #expect(abs(account.cash - (beforeSale + 10_000 - 26.30)) < 0.01)
    }

    @Test("A round trip at the same price loses exactly the charges")
    func roundTripCostsTheCharges() async throws {
        let account = try Billed(profile: .discount)
        let opening = account.cash

        try await account.manager.addStock(symbol: "INFY", companyName: "Infosys",
                                           quantity: 10, buyPrice: 1_000,
                                           modelContext: account.context)
        let holding = try #require(account.holding("INFY"))
        try account.manager.sellStock(holding, quantity: 10, modelContext: account.context)

        // Buying and selling at an unchanged price is not free: ₹11.87 + ₹26.30.
        #expect(abs(account.cash - (opening - 38.17)) < 0.01)
    }

    @Test("Gross P&L can be positive while the trade actually lost money")
    func netPnLTellsTheTruth() async throws {
        let account = try Billed(profile: .discount)
        try await account.manager.addStock(symbol: "WIPRO", companyName: "Wipro",
                                           quantity: 10, buyPrice: 1_000,
                                           modelContext: account.context)
        let holding = try #require(account.holding("WIPRO"))
        holding.currentPrice = 1_002   // a ₹20 gain, on paper

        try account.manager.sellStock(holding, quantity: 10, modelContext: account.context)
        let sale = try #require(account.trades.last)

        #expect((sale.realizedPnL ?? 0) > 0)        // ₹20 gross
        #expect((sale.netRealizedPnL ?? 0) < 0)     // ₹26.32 of charges ate it
        #expect(!sale.isProfitable)
    }

    @Test("Affordability is judged on the full debit, charges included")
    func chargesCountAgainstBuyingPower() async throws {
        // Exactly enough for the turnover, nothing spare for the bill.
        let account = try Billed(profile: .discount, cash: 10_000)

        await #expect(throws: PortfolioError.self) {
            try await account.manager.addStock(symbol: "HDFCBANK", companyName: "HDFC Bank",
                                               quantity: 10, buyPrice: 1_000,
                                               modelContext: account.context)
        }
        #expect(account.holding("HDFCBANK") == nil)
        #expect(account.cash == 10_000)
    }

    @Test("Switching to the no-charges profile restores clean arithmetic")
    func noneProfileTradesClean() async throws {
        let account = try Billed(profile: .none)
        let opening = account.cash

        try await account.manager.addStock(symbol: "ITC", companyName: "ITC",
                                           quantity: 10, buyPrice: 1_000,
                                           modelContext: account.context)

        #expect(abs(account.cash - (opening - 10_000)) < 0.001)
        #expect(account.trades.first?.charges == 0)
    }

    @Test("Trades recorded before charges existed report none")
    func legacyTradesDefaultToZero() {
        let legacy = Trade(symbol: "SBIN", companyName: "SBI", isBuy: false,
                           quantity: 5, price: 600, realizedPnL: 250)

        #expect(legacy.charges == 0)
        #expect(legacy.netRealizedPnL == 250)
        #expect(legacy.netCashFlow == 3_000)
    }
}
