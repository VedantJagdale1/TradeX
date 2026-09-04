//
//  PerformanceReconstructor.swift
//  TradeX
//

import Foundation
import SwiftData

/// A trade, stripped of SwiftData so the replay can be reasoned about and tested
/// without a model container.
struct LedgerTrade: Sendable {
    let symbol: String
    let isBuy: Bool
    let quantity: Int
    let price: Double
    let timestamp: Date

    var cashFlow: Double {
        (isBuy ? -1 : 1) * Double(quantity) * price
    }

    var quantityChange: Int {
        isBuy ? quantity : -quantity
    }
}

/// Money paid in or taken out by hand.
struct LedgerCashFlow: Sendable {
    let amount: Double
    let timestamp: Date
}

/// What the account looked like before the ledger began.
struct OpeningState: Equatable, Sendable {
    var cash: Double
    var quantities: [String: Int]
}

/// One reconstructed day.
struct ReconstructedDay: Equatable, Sendable {
    let netWorth: Double
    let netDeposits: Double
}

/// Daily closes with carry-forward.
struct DailyCloses: Sendable {
    let sorted: [(day: Date, close: Double)]

    nonisolated init(sorted: [(day: Date, close: Double)]) {
        self.sorted = sorted.sorted { $0.day < $1.day }
    }

    /// The close on `day`, or the most recent one before it.
    ///
    /// A symbol has no close on a day it didn't trade — a holiday, a halt, or before it
    /// listed. Carrying the previous close forward is what a broker's statement does;
    /// dropping the position would make the portfolio appear to shrink.
    func close(onOrBefore day: Date) -> Double? {
        var match: Double?
        for entry in sorted {
            if entry.day <= day { match = entry.close } else { break }
        }
        return match
    }
}


/// Rebuilds performance history from the trade ledger.
///
/// Snapshots are only written going forward, so the Performance screen is empty until
/// the app has been opened on two separate days. But every trade records its symbol,
/// quantity, price and timestamp — which is enough to know exactly what was held on any
/// past date. Combined with historical closes, the whole curve can be recovered from
/// data already on the device.
enum PerformanceReconstructor {

    enum ReconstructionError: LocalizedError {
        case noTrades
        case benchmarkUnavailable

        var errorDescription: String? {
            switch self {
            case .noTrades:
                return "There are no trades to rebuild from yet."
            case .benchmarkUnavailable:
                return "Couldn't load NIFTY 50 history. Check your connection and try again."
            }
        }
    }

    // MARK: - Pure replay

    /// Derives the state the account must have been in before the ledger started.
    ///
    /// Anything today's holdings and cash contain that the ledger cannot account for —
    /// positions created before the journal existed, or a balance the trades don't
    /// explain — has to have been there all along. Replaying every flow forward from
    /// this state lands exactly on the present.
    static func openingState(
        currentQuantities: [String: Int],
        currentCash: Double,
        trades: [LedgerTrade],
        adjustments: [LedgerCashFlow]
    ) -> OpeningState {
        var quantities = currentQuantities
        for trade in trades {
            quantities[trade.symbol, default: 0] -= trade.quantityChange
        }

        let tradedCash = trades.reduce(0.0) { $0 + $1.cashFlow }
        let deposited = adjustments.reduce(0.0) { $0 + $1.amount }

        return OpeningState(
            cash: currentCash - deposited - tradedCash,
            quantities: quantities.filter { $0.value != 0 }
        )
    }

    /// Values the account at the end of `day`.
    static func state(
        on day: Date,
        endOfDay: Date,
        opening: OpeningState,
        trades: [LedgerTrade],
        adjustments: [LedgerCashFlow],
        closes: [String: DailyCloses],
        fallbackDeposits: Double
    ) -> ReconstructedDay {
        let tradesSoFar = trades.filter { $0.timestamp < endOfDay }
        let adjustmentsSoFar = adjustments.filter { $0.timestamp < endOfDay }

        let deposits = adjustmentsSoFar.isEmpty
            ? fallbackDeposits
            : adjustmentsSoFar.reduce(0.0) { $0 + $1.amount }

        var cash = opening.cash + adjustmentsSoFar.reduce(0.0) { $0 + $1.amount }
        var quantities = opening.quantities
        for trade in tradesSoFar {
            cash += trade.cashFlow
            quantities[trade.symbol, default: 0] += trade.quantityChange
        }

        var equity = 0.0
        for (symbol, quantity) in quantities where quantity > 0 {
            guard let close = closes[symbol]?.close(onOrBefore: day) else { continue }
            equity += Double(quantity) * close
        }

        return ReconstructedDay(netWorth: cash + equity, netDeposits: deposits)
    }

    /// The smallest Yahoo range that still reaches back to `start`.
    static func yahooRange(covering start: Date, now: Date = Date()) -> String {
        let days = Calendar.current.dateComponents([.day], from: start, to: now).day ?? 0
        switch days {
        case ..<25: return "1mo"
        case ..<80: return "3mo"
        case ..<170: return "6mo"
        case ..<350: return "1y"
        case ..<700: return "2y"
        case ..<1800: return "5y"
        default: return "max"
        }
    }

    // MARK: - Rebuild

    /// Recomputes daily marks back to the first trade.
    /// - Returns: how many days were written.
    @MainActor
    @discardableResult
    static func rebuild(modelContext: ModelContext) async throws -> Int {
        let storedTrades = (try? modelContext.fetch(
            FetchDescriptor<Trade>(sortBy: [SortDescriptor(\.timestamp)])
        )) ?? []
        guard let firstTrade = storedTrades.first else { throw ReconstructionError.noTrades }

        let storedAdjustments = (try? modelContext.fetch(
            FetchDescriptor<CashAdjustment>(sortBy: [SortDescriptor(\.timestamp)])
        )) ?? []

        let trades = storedTrades.map {
            LedgerTrade(
                symbol: $0.symbol,
                isBuy: $0.isBuy,
                quantity: $0.quantity,
                price: $0.price,
                timestamp: $0.timestamp
            )
        }
        let adjustments = storedAdjustments.map {
            LedgerCashFlow(amount: $0.amount, timestamp: $0.timestamp)
        }

        let start = min(firstTrade.timestamp, storedAdjustments.first?.timestamp ?? firstTrade.timestamp)
        let range = yahooRange(covering: start)

        // The benchmark doubles as the trading calendar: its closes tell us which days
        // the market was actually open, so no mark is invented for a weekend.
        guard let benchmark = try? await MarketAPIService.shared.fetchIndexHistory(
            symbol: PortfolioManager.benchmarkSymbol,
            range: range
        ), !benchmark.points.isEmpty else {
            throw ReconstructionError.benchmarkUnavailable
        }

        let holdings = (try? modelContext.fetch(FetchDescriptor<PortfolioHolding>())) ?? []
        var currentQuantities: [String: Int] = [:]
        for holding in holdings { currentQuantities[holding.symbol] = holding.quantity }

        let opening = openingState(
            currentQuantities: currentQuantities,
            currentCash: PortfolioManager.shared.settings(in: modelContext).availableCash,
            trades: trades,
            adjustments: adjustments
        )

        let symbols = Set(trades.map(\.symbol)).union(opening.quantities.keys)
        let histories = await closes(for: symbols, range: range)

        let calendar = tradingCalendar()
        let allSnapshots = (try? modelContext.fetch(FetchDescriptor<PortfolioSnapshot>())) ?? []

        // Clear previous reconstructions so a rebuild can correct itself; marks taken
        // from live prices are kept, being more accurate than daily closes.
        for snapshot in allSnapshots where snapshot.isReconstructed {
            modelContext.delete(snapshot)
        }

        let liveDays = Set(
            allSnapshots.filter { !$0.isReconstructed }.map { calendar.startOfDay(for: $0.day) }
        )
        let startDay = calendar.startOfDay(for: start)
        var added = 0

        for point in benchmark.points {
            let day = calendar.startOfDay(for: point.date)
            guard day >= startDay, !liveDays.contains(day) else { continue }

            let endOfDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let value = state(
                on: day,
                endOfDay: endOfDay,
                opening: opening,
                trades: trades,
                adjustments: adjustments,
                closes: histories,
                fallbackDeposits: PortfolioManager.defaultStartingCash
            )

            modelContext.insert(
                PortfolioSnapshot(
                    day: day,
                    netWorth: value.netWorth,
                    netDeposits: value.netDeposits,
                    niftyLevel: point.price,
                    isReconstructed: true
                )
            )
            added += 1
        }

        try? modelContext.save()
        return added
    }

    static func tradingCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketSession.exchangeTimeZone
        return calendar
    }

    private static func closes(for symbols: Set<String>, range: String) async -> [String: DailyCloses] {
        let calendar = tradingCalendar()

        return await withTaskGroup(of: (String, DailyCloses?).self) { group in
            for symbol in symbols {
                group.addTask {
                    guard let series = try? await MarketAPIService.shared.fetchHistoricalData(
                        symbol: symbol,
                        range: range
                    ) else { return (symbol, nil) }

                    let entries = series.points.map {
                        (day: calendar.startOfDay(for: $0.date), close: $0.price)
                    }
                    return (symbol, DailyCloses(sorted: entries))
                }
            }

            var collected: [String: DailyCloses] = [:]
            for await (symbol, closes) in group {
                if let closes { collected[symbol] = closes }
            }
            return collected
        }
    }
}
