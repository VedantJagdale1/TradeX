//
//  PortfolioManagerTests.swift
//  TradeXTests
//

import Foundation
import SwiftData
import Testing
@testable import TradeX

/// Shared setup: an in-memory store and a manager whose post-trade quote is stubbed, so
/// every assertion is about the trade itself rather than the network.
@MainActor
private struct Account {
    let context: ModelContext
    let manager: PortfolioManager

    init(quote: Double? = nil) throws {
        let container = try ModelContainer(
            for: PortfolioHolding.self, UserSettings.self, Trade.self,
            CashAdjustment.self, PortfolioSnapshot.self, WatchlistItem.self,
            PriceAlert.self, LimitOrder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        manager = PortfolioManager()
        manager.quoteProvider = { _ in quote }
    }

    var cash: Double { manager.settings(in: context).availableCash }
    var holdings: [PortfolioHolding] { (try? context.fetch(FetchDescriptor<PortfolioHolding>())) ?? [] }
    var trades: [Trade] { (try? context.fetch(FetchDescriptor<Trade>())) ?? [] }
    var adjustments: [CashAdjustment] { (try? context.fetch(FetchDescriptor<CashAdjustment>())) ?? [] }

    func holding(_ symbol: String) -> PortfolioHolding? { holdings.first { $0.symbol == symbol } }
}


@MainActor
struct PortfolioManagerBuyTests {

    @Test("A buy debits cash, opens the position and records the trade")
    func buySucceeds() async throws {
        let account = try Account()
        let opening = account.cash

        try await account.manager.addStock(
            symbol: "RELIANCE", companyName: "Reliance Industries Limited",
            quantity: 10, buyPrice: 1_300, thesis: "cheap vs sector",
            modelContext: account.context
        )

        #expect(abs(account.cash - (opening - 13_000)) < 0.001)

        let holding = try #require(account.holding("RELIANCE"))
        #expect(holding.quantity == 10)
        #expect(abs(holding.avgBuyPrice - 1_300) < 0.001)

        let trade = try #require(account.trades.first)
        #expect(trade.isBuy == true)
        #expect(trade.quantity == 10)
        #expect(trade.thesis == "cheap vs sector")
        #expect(trade.realizedPnL == nil)   // a buy books nothing
    }

    @Test("An order beyond available cash is refused and changes nothing")
    func insufficientFundsIsRejected() async throws {
        let account = try Account()
        let opening = account.cash

        await #expect(throws: PortfolioError.self) {
            try await account.manager.addStock(
                symbol: "RELIANCE", companyName: "Reliance Industries Limited",
                quantity: 10_000, buyPrice: 1_300, modelContext: account.context
            )
        }

        // The whole point: no partial application.
        #expect(abs(account.cash - opening) < 0.001)
        #expect(account.holdings.isEmpty)
        #expect(account.trades.isEmpty)
    }

    @Test("A nonsensical size or price is refused")
    func invalidOrdersAreRejected() async throws {
        let account = try Account()

        await #expect(throws: PortfolioError.self) {
            try await account.manager.addStock(
                symbol: "TCS", companyName: "Tata Consultancy Services Limited",
                quantity: 0, buyPrice: 2_000, modelContext: account.context
            )
        }
        await #expect(throws: PortfolioError.self) {
            try await account.manager.addStock(
                symbol: "TCS", companyName: "Tata Consultancy Services Limited",
                quantity: 5, buyPrice: 0, modelContext: account.context
            )
        }
        #expect(account.holdings.isEmpty)
    }

    @Test("Topping up a position averages the cost across both fills")
    func topUpAveragesCost() async throws {
        let account = try Account()

        try await account.manager.addStock(
            symbol: "INFY", companyName: "Infosys Limited",
            quantity: 10, buyPrice: 1_000, modelContext: account.context
        )
        try await account.manager.addStock(
            symbol: "INFY", companyName: "Infosys Limited",
            quantity: 10, buyPrice: 1_200, modelContext: account.context
        )

        let holding = try #require(account.holding("INFY"))
        #expect(holding.quantity == 20)
        #expect(abs(holding.avgBuyPrice - 1_100) < 0.001)     // (10x1000 + 10x1200) / 20
        #expect(account.holdings.count == 1)                  // one position, not two
        #expect(account.trades.count == 2)                    // but both trades kept
    }

    @Test("A failed quote after the fill doesn't undo the trade")
    func unreachableQuoteLeavesTradeIntact() async throws {
        let account = try Account(quote: nil)   // provider yields nothing

        try await account.manager.addStock(
            symbol: "TMCV", companyName: "Tata Motors Limited",
            quantity: 5, buyPrice: 467.10, modelContext: account.context
        )

        let holding = try #require(account.holding("TMCV"))
        #expect(abs(holding.currentPrice - 467.10) < 0.001)   // marked at the fill price
    }

    @Test("A live quote after the fill re-marks the position")
    func liveQuoteUpdatesTheMark() async throws {
        let account = try Account(quote: 480.0)

        try await account.manager.addStock(
            symbol: "TMCV", companyName: "Tata Motors Limited",
            quantity: 5, buyPrice: 467.10, modelContext: account.context
        )

        let holding = try #require(account.holding("TMCV"))
        #expect(abs(holding.currentPrice - 480.0) < 0.001)
        #expect(abs(holding.avgBuyPrice - 467.10) < 0.001)    // cost basis untouched
    }
}


@MainActor
struct PortfolioManagerSellTests {

    private func accountHolding(
        _ symbol: String, quantity: Int, cost: Double, mark: Double
    ) async throws -> Account {
        let account = try Account()
        try await account.manager.addStock(
            symbol: symbol, companyName: symbol,
            quantity: quantity, buyPrice: cost, modelContext: account.context
        )
        account.holding(symbol)?.currentPrice = mark
        return account
    }

    @Test("Selling the whole position credits proceeds and books the result")
    func fullSell() async throws {
        let account = try await accountHolding("TCS", quantity: 10, cost: 2_000, mark: 2_200)
        let beforeSale = account.cash
        let holding = try #require(account.holding("TCS"))

        try account.manager.sellStock(holding, quantity: 10, thesis: "target hit",
                                      modelContext: account.context)

        #expect(abs(account.cash - (beforeSale + 22_000)) < 0.001)
        #expect(account.holding("TCS") == nil)                 // position closed

        let sell = try #require(account.trades.first { !$0.isBuy })
        #expect(sell.quantity == 10)
        #expect(abs((sell.realizedPnL ?? 0) - 2_000) < 0.001)  // (2200 - 2000) x 10
        #expect(sell.thesis == "target hit")
    }

    @Test("A partial sell keeps the position open and the cost basis unchanged")
    func partialSell() async throws {
        let account = try await accountHolding("TMCV", quantity: 10, cost: 467.10, mark: 500)
        let beforeSale = account.cash
        let holding = try #require(account.holding("TMCV"))

        try account.manager.sellStock(holding, quantity: 4, modelContext: account.context)

        let remaining = try #require(account.holding("TMCV"))
        #expect(remaining.quantity == 6)
        // Average cost is a per-share figure; selling some of them doesn't change it.
        #expect(abs(remaining.avgBuyPrice - 467.10) < 0.001)
        #expect(abs(account.cash - (beforeSale + 2_000)) < 0.001)   // 4 x 500

        let sell = try #require(account.trades.first { !$0.isBuy })
        #expect(abs((sell.realizedPnL ?? 0) - 131.60) < 0.001)      // (500 - 467.10) x 4
    }

    @Test("Selling more than is held is refused and changes nothing")
    func overSellIsRejected() async throws {
        let account = try await accountHolding("INFY", quantity: 5, cost: 1_000, mark: 1_100)
        let beforeSale = account.cash
        let holding = try #require(account.holding("INFY"))

        #expect(throws: PortfolioError.self) {
            try account.manager.sellStock(holding, quantity: 6, modelContext: account.context)
        }

        #expect(account.holding("INFY")?.quantity == 5)
        #expect(abs(account.cash - beforeSale) < 0.001)
        #expect(account.trades.filter { !$0.isBuy }.isEmpty)
    }

    @Test("A sale at a loss books a negative result")
    func lossIsBooked() async throws {
        let account = try await accountHolding("HDFCBANK", quantity: 10, cost: 800, mark: 712)
        let holding = try #require(account.holding("HDFCBANK"))

        try account.manager.sellStock(holding, quantity: 10, modelContext: account.context)

        let sell = try #require(account.trades.first { !$0.isBuy })
        #expect(abs((sell.realizedPnL ?? 0) + 880) < 0.001)   // (712 - 800) x 10
    }

    @Test("Selling in pieces books the same total as selling at once")
    func piecemealSellMatchesSingleSell() async throws {
        let piecemeal = try await accountHolding("X", quantity: 10, cost: 100, mark: 150)
        for _ in 0..<2 {
            let holding = try #require(piecemeal.holding("X"))
            try piecemeal.manager.sellStock(holding, quantity: 5, modelContext: piecemeal.context)
        }
        let split = piecemeal.trades.compactMap(\.realizedPnL).reduce(0, +)

        let single = try await accountHolding("X", quantity: 10, cost: 100, mark: 150)
        try single.manager.sellStock(try #require(single.holding("X")), quantity: 10,
                                     modelContext: single.context)
        let whole = single.trades.compactMap(\.realizedPnL).reduce(0, +)

        #expect(abs(split - whole) < 0.001)
        #expect(abs(split - 500) < 0.001)
    }

    @Test("Round-tripping a position returns the cash it started with")
    func roundTripIsCashNeutralAtCost() async throws {
        let account = try Account()
        let opening = account.cash

        try await account.manager.addStock(
            symbol: "X", companyName: "X", quantity: 10, buyPrice: 100,
            modelContext: account.context
        )
        // Sell at exactly the cost — no gain, no loss.
        try account.manager.sellStock(try #require(account.holding("X")), quantity: 10,
                                      modelContext: account.context)

        #expect(abs(account.cash - opening) < 0.001)
        #expect(abs((account.trades.first { !$0.isBuy }?.realizedPnL ?? -1)) < 0.001)
    }
}


@MainActor
struct PortfolioCashTests {

    @Test("Seeding the account creates exactly one settings row and logs the opening balance")
    func openingBalanceIsRecorded() throws {
        let account = try Account()
        _ = account.cash

        #expect(abs(account.cash - PortfolioManager.defaultStartingCash) < 0.001)
        #expect(account.adjustments.count == 1)
        #expect(account.adjustments.first?.note == "Opening balance")
    }

    @Test("Duplicate settings rows collapse to the largest, so cash can't shrink")
    func duplicateSettingsConsolidate() throws {
        let account = try Account()
        _ = account.cash

        // Simulate the older bug where two code paths each inserted a row.
        account.context.insert(UserSettings(availableCash: 999))
        try? account.context.save()

        #expect(abs(account.cash - PortfolioManager.defaultStartingCash) < 0.001)
        #expect(((try? account.context.fetch(FetchDescriptor<UserSettings>()))?.count ?? 0) == 1)
    }

    @Test("A cash change is recorded as a signed adjustment")
    func adjustmentsAreLogged() throws {
        let account = try Account()
        let opening = account.cash

        account.manager.adjustCash(to: opening + 50_000, note: "Deposit",
                                   modelContext: account.context)

        #expect(abs(account.cash - (opening + 50_000)) < 0.001)
        let deposit = try #require(account.adjustments.first { $0.note == "Deposit" })
        #expect(abs(deposit.amount - 50_000) < 0.001)

        // Deposits raise the denominator, so a top-up can't look like performance.
        #expect(abs(account.manager.netDeposits(in: account.context) - (opening + 50_000)) < 0.001)
    }

    @Test("Setting cash to its current value records nothing")
    func noOpAdjustmentIsIgnored() throws {
        let account = try Account()
        let opening = account.cash

        account.manager.adjustCash(to: opening, modelContext: account.context)
        #expect(account.adjustments.count == 1)   // still just the opening balance
    }

    @Test("Trading does not count as depositing")
    func tradesDoNotAffectDeposits() async throws {
        let account = try Account()
        let deposited = account.manager.netDeposits(in: account.context)

        try await account.manager.addStock(
            symbol: "X", companyName: "X", quantity: 10, buyPrice: 100,
            modelContext: account.context
        )

        #expect(abs(account.manager.netDeposits(in: account.context) - deposited) < 0.001)
    }
}


@MainActor
struct BuyingPowerTests {

    /// Rests an order without going through submit(), whose market-hours handling is
    /// tested separately and is not what these assertions are about.
    private func rest(
        _ symbol: String, isBuy: Bool, quantity: Int, limit: Double, in context: ModelContext
    ) {
        context.insert(
            LimitOrder(symbol: symbol, companyName: symbol, isBuy: isBuy,
                       quantity: quantity, limitPrice: limit)
        )
        try? context.save()
    }

    @Test("A resting buy ties up cash; a resting sell doesn't")
    func restingBuysReserveCash() throws {
        let account = try Account()
        let opening = account.cash

        rest("RELIANCE", isBuy: true, quantity: 10, limit: 1_250, in: account.context)
        rest("TCS", isBuy: false, quantity: 5, limit: 2_400, in: account.context)

        #expect(abs(account.manager.reservedCash(in: account.context) - 12_500) < 0.001)
        #expect(abs(account.manager.freeCash(in: account.context) - (opening - 12_500)) < 0.001)
    }

    @Test("Cancelling an order releases what it reserved")
    func cancellingReleasesCash() throws {
        let account = try Account()
        let opening = account.cash

        rest("RELIANCE", isBuy: true, quantity: 10, limit: 1_250, in: account.context)
        let order = try #require((try? account.context.fetch(FetchDescriptor<LimitOrder>()))?.first)
        LimitOrderService.cancel(order, modelContext: account.context)

        #expect(abs(account.manager.reservedCash(in: account.context)) < 0.001)
        #expect(abs(account.manager.freeCash(in: account.context) - opening) < 0.001)
    }

    @Test("Shares promised to a resting sell aren't offered again")
    func restingSellsReserveShares() async throws {
        let account = try Account()
        try await account.manager.addStock(
            symbol: "TMCV", companyName: "Tata Motors Limited",
            quantity: 10, buyPrice: 467.10, modelContext: account.context
        )
        let holding = try #require(account.holding("TMCV"))

        rest("TMCV", isBuy: false, quantity: 4, limit: 500, in: account.context)

        #expect(account.manager.reservedShares(symbol: "TMCV", in: account.context) == 4)
        #expect(account.manager.freeShares(for: holding, in: account.context) == 6)
    }
}
