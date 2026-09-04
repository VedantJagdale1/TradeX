//
//  PerformanceReconstructor.swift
//  TradeX
//

import Foundation
import SwiftData

/// Rebuilds performance history from the trade ledger.
///
/// Snapshots are only written going forward, so the Performance screen is empty until
/// the app has been opened on two separate days. But every trade records its symbol,
/// quantity, price and timestamp — which is enough to know exactly what was held on any
/// past date. Combined with historical closes, the whole curve can be recovered from
/// data already on the device.
@MainActor
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

    /// Recomputes daily marks back to the first trade.
    ///
    /// Existing snapshots are left alone — those were taken from live prices and are
    /// more accurate than a reconstruction from daily closes.
    /// - Returns: how many days were added.
    @discardableResult
    static func rebuild(modelContext: ModelContext) async throws -> Int {
        let trades = (try? modelContext.fetch(
            FetchDescriptor<Trade>(sortBy: [SortDescriptor(\.timestamp)])
        )) ?? []
        guard let firstTrade = trades.first else { throw ReconstructionError.noTrades }

        let adjustments = (try? modelContext.fetch(
            FetchDescriptor<CashAdjustment>(sortBy: [SortDescriptor(\.timestamp)])
        )) ?? []

        let start = min(firstTrade.timestamp, adjustments.first?.timestamp ?? firstTrade.timestamp)
        let range = yahooRange(covering: start)

        // The benchmark doubles as the trading calendar: its closes tell us which days
        // the market was actually open, so no snapshot is invented for a weekend.
        guard let benchmark = try? await MarketAPIService.shared.fetchIndexHistory(
            symbol: PortfolioManager.benchmarkSymbol,
            range: range
        ), !benchmark.points.isEmpty else {
            throw ReconstructionError.benchmarkUnavailable
        }

        // Anchor to the present. Whatever the ledger cannot account for must have
        // existed before it started, so it is carried as an opening position rather
        // than treated as zero — otherwise holdings created before the journal existed
        // vanish from the past and the curve invents a crash that never happened.
        let holdings = (try? modelContext.fetch(FetchDescriptor<PortfolioHolding>())) ?? []

        var openingQuantities: [String: Int] = [:]
        for holding in holdings { openingQuantities[holding.symbol] = holding.quantity }
        for trade in trades {
            openingQuantities[trade.symbol, default: 0] += trade.isBuy ? -trade.quantity : trade.quantity
        }

        // Same reconciliation for cash: replaying every flow from the opening balance
        // must land exactly on today's balance.
        let tradedCash = trades.reduce(0.0) { total, trade in
            total + (trade.isBuy ? -1 : 1) * Double(trade.quantity) * trade.price
        }
        let totalAdjustments = adjustments.reduce(0.0) { $0 + $1.amount }
        let openingCash = PortfolioManager.shared.settings(in: modelContext).availableCash
            - totalAdjustments - tradedCash

        let symbols = Set(trades.map(\.symbol)).union(openingQuantities.filter { $0.value > 0 }.keys)
        let histories = await closes(for: symbols, range: range)

        let calendar = tradingCalendar()
        let allSnapshots = (try? modelContext.fetch(FetchDescriptor<PortfolioSnapshot>())) ?? []

        // Clear previous reconstructions so a rebuild can correct itself; marks taken
        // from live prices are kept, being more accurate than daily closes.
        for snapshot in allSnapshots where snapshot.isReconstructed {
            modelContext.delete(snapshot)
        }

        let liveDays = Set(
            allSnapshots
                .filter { !$0.isReconstructed }
                .map { calendar.startOfDay(for: $0.day) }
        )

        let startDay = calendar.startOfDay(for: start)
        var added = 0

        for point in benchmark.points {
            let day = calendar.startOfDay(for: point.date)
            guard day >= startDay, !liveDays.contains(day) else { continue }

            // Everything that had happened by the end of this day.
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let tradesSoFar = trades.filter { $0.timestamp < endOfDay }
            let adjustmentsSoFar = adjustments.filter { $0.timestamp < endOfDay }

            let deposits = adjustmentsSoFar.isEmpty
                ? PortfolioManager.defaultStartingCash
                : adjustmentsSoFar.reduce(0) { $0 + $1.amount }

            var cash = openingCash + adjustmentsSoFar.reduce(0.0) { $0 + $1.amount }
            var quantities = openingQuantities
            for trade in tradesSoFar {
                let value = Double(trade.quantity) * trade.price
                if trade.isBuy {
                    cash -= value
                    quantities[trade.symbol, default: 0] += trade.quantity
                } else {
                    cash += value
                    quantities[trade.symbol, default: 0] -= trade.quantity
                }
            }

            var equity = 0.0
            for (symbol, quantity) in quantities where quantity > 0 {
                guard let close = histories[symbol]?.close(onOrBefore: day) else { continue }
                equity += Double(quantity) * close
            }

            modelContext.insert(
                PortfolioSnapshot(
                    day: day,
                    netWorth: cash + equity,
                    netDeposits: deposits,
                    niftyLevel: point.price,
                    isReconstructed: true
                )
            )
            added += 1
        }

        try? modelContext.save()
        return added
    }
}


private extension PerformanceReconstructor {

    /// Daily closes keyed by day, with the ability to carry the last one forward.
    struct DailyCloses {
        let sorted: [(day: Date, close: Double)]

        /// The close on `day`, or the most recent one before it.
        ///
        /// A symbol has no close on a day it didn't trade — a holiday, a halt, or before
        /// it listed. Carrying the previous close forward is what a broker's statement
        /// does; skipping the position would make the portfolio appear to shrink.
        func close(onOrBefore day: Date) -> Double? {
            var match: Double?
            for entry in sorted {
                if entry.day <= day { match = entry.close } else { break }
            }
            return match
        }
    }

    static func tradingCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketSession.exchangeTimeZone
        return calendar
    }

    static func closes(for symbols: Set<String>, range: String) async -> [String: DailyCloses] {
        let calendar = tradingCalendar()

        return await withTaskGroup(of: (String, DailyCloses?).self) { group in
            for symbol in symbols {
                group.addTask {
                    guard let series = try? await MarketAPIService.shared.fetchHistoricalData(
                        symbol: symbol,
                        range: range
                    ) else { return (symbol, nil) }

                    let entries = series.points
                        .map { (day: calendar.startOfDay(for: $0.date), close: $0.price) }
                        .sorted { $0.day < $1.day }
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

    /// The smallest Yahoo range that still reaches back to `start`.
    static func yahooRange(covering start: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0
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
}
