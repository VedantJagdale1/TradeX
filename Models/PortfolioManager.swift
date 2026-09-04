//
//  PortfolioManager.swift
//  TradeX
//
//  Created by vedant jagdale on 04/07/26.
//

import Foundation
import SwiftData

enum PortfolioError: LocalizedError {
    case invalidQuantity
    case invalidPrice
    case insufficientFunds(required: Double, available: Double)
    case insufficientShares(requested: Int, available: Int)
    case priceUnavailable(symbol: String)

    var errorDescription: String? {
        switch self {
        case .invalidQuantity:
            return "Enter a whole number of shares greater than zero."
        case .invalidPrice:
            return "Enter a buy price greater than zero."
        case let .insufficientFunds(required, available):
            return String(
                format: "Not enough cash. This order costs ₹%.2f but you only have ₹%.2f available.",
                required, available
            )
        case let .insufficientShares(_, available):
            return "You only hold \(available) share\(available == 1 ? "" : "s"). Enter \(available) or fewer to sell."
        case let .priceUnavailable(symbol):
            return "Could not fetch a live price for \(symbol). Check your connection, or enter a buy price manually."
        }
    }
}

@MainActor
final class PortfolioManager {
    static let shared = PortfolioManager()

    private init() {}

    static let defaultStartingCash = 274_500.00

    /// The single source of truth for cash. Creating it here — and nowhere else —
    /// keeps buys, sells and manual edits from each inserting their own row.
    @discardableResult
    func settings(in modelContext: ModelContext) -> UserSettings {
        let rows = (try? modelContext.fetch(FetchDescriptor<UserSettings>())) ?? []

        if let canonical = rows.max(by: { $0.availableCash < $1.availableCash }) {
            // Older builds could insert a second row from two different code paths.
            // `@Query` has no defined order, so leaving both makes the balance vary
            // per launch. Keep the largest so consolidation can never take cash away.
            for duplicate in rows where duplicate !== canonical {
                modelContext.delete(duplicate)
            }
            if rows.count > 1 { save(modelContext) }
            return canonical
        }

        let created = UserSettings(availableCash: Self.defaultStartingCash)
        modelContext.insert(created)
        modelContext.insert(
            CashAdjustment(
                amount: Self.defaultStartingCash,
                balanceAfter: Self.defaultStartingCash,
                note: "Opening balance"
            )
        )
        save(modelContext)
        return created
    }

    /// Records a manual change to the cash balance and applies it.
    func adjustCash(to newBalance: Double, note: String = "Manual adjustment", modelContext: ModelContext) {
        let appSettings = settings(in: modelContext)
        let delta = newBalance - appSettings.availableCash
        guard delta != 0 else { return }

        appSettings.availableCash = newBalance
        modelContext.insert(
            CashAdjustment(amount: delta, balanceAfter: newBalance, note: note)
        )
        save(modelContext)
    }

    /// Total capital put in by hand — the denominator for any honest return figure.
    ///
    /// Installs that predate cash logging have no adjustment rows, so the starting
    /// balance is assumed rather than backfilled.
    func netDeposits(in modelContext: ModelContext) -> Double {
        let adjustments = (try? modelContext.fetch(FetchDescriptor<CashAdjustment>())) ?? []
        guard !adjustments.isEmpty else { return Self.defaultStartingCash }
        return adjustments.reduce(0) { $0 + $1.amount }
    }

    func addStock(
        symbol: String,
        companyName: String,
        quantity: Int,
        buyPrice: Double,
        thesis: String = "",
        modelContext: ModelContext
    ) async throws {
        guard quantity > 0 else { throw PortfolioError.invalidQuantity }
        guard buyPrice > 0, buyPrice.isFinite else { throw PortfolioError.invalidPrice }

        let totalCost = Double(quantity) * buyPrice
        let appSettings = settings(in: modelContext)

        guard totalCost <= appSettings.availableCash else {
            throw PortfolioError.insufficientFunds(
                required: totalCost,
                available: appSettings.availableCash
            )
        }

        if let holding = fetchHolding(symbol: symbol, modelContext: modelContext) {
            let totalQuantity = holding.quantity + quantity
            let dynamicTotalCost = (Double(holding.quantity) * holding.avgBuyPrice) + totalCost
            holding.quantity = totalQuantity
            holding.avgBuyPrice = dynamicTotalCost / Double(totalQuantity)
        } else {
            let newHolding = PortfolioHolding(
                symbol: symbol,
                companyName: companyName,
                quantity: quantity,
                avgBuyPrice: buyPrice,
                currentPrice: buyPrice
            )
            modelContext.insert(newHolding)
        }

        appSettings.availableCash -= totalCost

        modelContext.insert(
            Trade(
                symbol: symbol,
                companyName: companyName,
                isBuy: true,
                quantity: quantity,
                price: buyPrice,
                thesis: thesis
            )
        )

        save(modelContext)

        // The trade is already committed — a failed quote refresh must not surface
        // as an order failure, so this stays best-effort.
        if let liveCurrentPrice = try? await MarketAPIService.shared.fetchStockPrice(symbol: symbol) {
            updateCurrentPrice(symbol: symbol, currentPrice: liveCurrentPrice, modelContext: modelContext)
        }
    }

    /// Sells all or part of a position at its last known price.
    ///
    /// Partial sales keep `avgBuyPrice` untouched: under average-cost accounting the
    /// per-share basis of what remains is unchanged by selling some of it.
    func sellStock(
        _ holding: PortfolioHolding,
        quantity: Int,
        thesis: String = "",
        modelContext: ModelContext
    ) throws {
        guard quantity > 0 else { throw PortfolioError.invalidQuantity }
        guard quantity <= holding.quantity else {
            throw PortfolioError.insufficientShares(requested: quantity, available: holding.quantity)
        }

        let proceeds = Double(quantity) * holding.currentPrice
        let realizedPnL = (holding.currentPrice - holding.avgBuyPrice) * Double(quantity)

        // Always resolve through `settings(in:)`. The old code refunded only when a
        // settings row happened to exist, so selling on a fresh install deleted the
        // position and silently destroyed the proceeds.
        let appSettings = settings(in: modelContext)
        appSettings.availableCash += proceeds

        // Book the result before anything is deleted — once the holding is gone, the
        // cost basis needed to work out what it made is gone with it.
        modelContext.insert(
            Trade(
                symbol: holding.symbol,
                companyName: holding.companyName,
                isBuy: false,
                quantity: quantity,
                price: holding.currentPrice,
                thesis: thesis,
                realizedPnL: realizedPnL
            )
        )

        if quantity == holding.quantity {
            modelContext.delete(holding)
        } else {
            holding.quantity -= quantity
        }

        save(modelContext)
    }

    func updateCurrentPrice(symbol: String, currentPrice: Double, modelContext: ModelContext) {
        guard let holding = fetchHolding(symbol: symbol, modelContext: modelContext) else { return }
        holding.currentPrice = currentPrice
        save(modelContext)
    }

    // MARK: - Performance history

    /// Yahoo's ticker for the NIFTY 50, used as the benchmark.
    static let benchmarkSymbol = "^NSEI"

    /// Marks what the account is worth today, along with the benchmark level.
    ///
    /// Idempotent per calendar day — repeated calls update today's mark rather than
    /// appending, so the value tracks the latest prices as the day goes on.
    func recordDailySnapshot(modelContext: ModelContext) async {
        let holdings = (try? modelContext.fetch(FetchDescriptor<PortfolioHolding>())) ?? []
        let cash = settings(in: modelContext).availableCash
        let netWorth = holdings.reduce(cash) { $0 + $1.currentValue }
        let deposits = netDeposits(in: modelContext)

        let benchmarkLevel = try? await MarketAPIService.shared
            .fetchIndexQuote(symbol: Self.benchmarkSymbol).price

        let today = Calendar.current.startOfDay(for: Date())
        let existing = ((try? modelContext.fetch(FetchDescriptor<PortfolioSnapshot>())) ?? [])
            .first { Calendar.current.isDate($0.day, inSameDayAs: today) }

        if let existing {
            existing.netWorth = netWorth
            existing.netDeposits = deposits
            // Keep the level we already had if this fetch failed.
            if let benchmarkLevel { existing.niftyLevel = benchmarkLevel }
        } else {
            modelContext.insert(
                PortfolioSnapshot(
                    day: today,
                    netWorth: netWorth,
                    netDeposits: deposits,
                    niftyLevel: benchmarkLevel
                )
            )
        }

        save(modelContext)
    }

    // MARK: - Live prices

    private var refreshTask: Task<Void, Never>?
    private var lastRefresh: Date?

    /// Minimum gap between automatic refreshes. Dashboard and Portfolio both refresh
    /// when they appear, so without this, tab-switching would re-hit the quote API
    /// on every appearance.
    private static let minimumRefreshInterval: TimeInterval = 30

    /// Refreshes every holding's price from one place, so the Dashboard and the
    /// Portfolio tab can never disagree about what a position is worth.
    ///
    /// Concurrent callers join the in-flight refresh rather than starting a second one.
    /// - Parameter force: bypasses the throttle, for an explicit user-initiated refresh.
    func refreshPrices(modelContext: ModelContext, force: Bool = false) async {
        if let existing = refreshTask {
            await existing.value
            return
        }

        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.minimumRefreshInterval {
            return
        }

        let symbols = ((try? modelContext.fetch(FetchDescriptor<PortfolioHolding>())) ?? [])
            .map(\.symbol)
        guard !symbols.isEmpty else {
            lastRefresh = Date()
            return
        }

        let task = Task { @MainActor in
            // Fetch concurrently — the old per-view loop awaited each quote in turn,
            // so a 20-position portfolio meant 20 sequential round-trips.
            let quotes = await withTaskGroup(of: (String, Double?).self) { group in
                for symbol in symbols {
                    group.addTask {
                        (symbol, try? await MarketAPIService.shared.fetchStockPrice(symbol: symbol))
                    }
                }

                var collected: [String: Double] = [:]
                for await (symbol, price) in group {
                    if let price { collected[symbol] = price }
                }
                return collected
            }

            guard !quotes.isEmpty else { return }

            for (symbol, price) in quotes {
                fetchHolding(symbol: symbol, modelContext: modelContext)?.currentPrice = price
            }
            save(modelContext)
        }

        refreshTask = task
        await task.value
        refreshTask = nil
        lastRefresh = Date()
    }

    private func fetchHolding(symbol: String, modelContext: ModelContext) -> PortfolioHolding? {
        let descriptor = FetchDescriptor<PortfolioHolding>(
            predicate: #Predicate { $0.symbol == symbol }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func save(_ modelContext: ModelContext) {
        do {
            try modelContext.save()
        } catch {
            print("Could not save portfolio changes: \(error)")
        }
    }
}
