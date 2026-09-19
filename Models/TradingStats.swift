//
//  TradingStats.swift
//  TradeX
//

import Foundation

/// A closed trade reduced to what the statistics need.
struct ClosedTrade: Sendable {
    let symbol: String
    let realizedPnL: Double
    let closedAt: Date
    /// When the position this closed was first opened, when the ledger can say.
    let openedAt: Date?

    var isWin: Bool { realizedPnL > 0 }

    var holdingDays: Double? {
        openedAt.map { closedAt.timeIntervalSince($0) / 86_400 }
    }
}

/// Risk and discipline measures over a trading record.
///
/// Return says how it went; these say how it was done. Drawdown is the number most
/// worth knowing — a strategy that doubles and then halves is not the same as one that
/// grinds upward, and the return alone cannot tell them apart.
struct TradingStats: Sendable {
    let maxDrawdown: Double
    let winRate: Double
    let averageWin: Double
    let averageLoss: Double
    let expectancy: Double
    let profitFactor: Double?
    let averageHoldWinners: Double?
    let averageHoldLosers: Double?
    let closedCount: Int

    static let empty = TradingStats(
        maxDrawdown: 0, winRate: 0, averageWin: 0, averageLoss: 0,
        expectancy: 0, profitFactor: nil,
        averageHoldWinners: nil, averageHoldLosers: nil, closedCount: 0
    )

    /// True when losers are held longer than winners — cutting gains short while letting
    /// losses run, the most common way a trading record goes wrong.
    var holdsLosersLonger: Bool {
        guard let winners = averageHoldWinners, let losers = averageHoldLosers else { return false }
        return losers > winners
    }

    // MARK: - Drawdown

    /// The deepest peak-to-trough fall in an equity curve, as a positive percentage.
    ///
    /// Measured on the rebased curve rather than raw net worth, so money paid in can't
    /// disguise a decline as growth.
    static func maxDrawdown(of curve: [Double]) -> Double {
        var peak = -Double.greatestFiniteMagnitude
        var worst = 0.0

        for value in curve {
            peak = max(peak, value)
            guard peak > 0 else { continue }
            worst = max(worst, (peak - value) / peak)
        }
        return worst * 100
    }

    // MARK: - Trade record

    static func make(closed: [ClosedTrade], equityCurve: [Double]) -> TradingStats {
        let drawdown = maxDrawdown(of: equityCurve)
        guard !closed.isEmpty else {
            return TradingStats(
                maxDrawdown: drawdown, winRate: 0, averageWin: 0, averageLoss: 0,
                expectancy: 0, profitFactor: nil,
                averageHoldWinners: nil, averageHoldLosers: nil, closedCount: 0
            )
        }

        let winners = closed.filter(\.isWin)
        let losers = closed.filter { !$0.isWin }

        let grossProfit = winners.reduce(0) { $0 + $1.realizedPnL }
        // Losses are negative; the magnitude is what the ratios need.
        let grossLoss = abs(losers.reduce(0) { $0 + $1.realizedPnL })

        let winRate = Double(winners.count) / Double(closed.count)
        let averageWin = winners.isEmpty ? 0 : grossProfit / Double(winners.count)
        let averageLoss = losers.isEmpty ? 0 : grossLoss / Double(losers.count)

        // What the average trade is worth. Positive means the record makes money over
        // time even when most individual trades don't.
        let expectancy = (winRate * averageWin) - ((1 - winRate) * averageLoss)

        return TradingStats(
            maxDrawdown: drawdown,
            winRate: winRate * 100,
            averageWin: averageWin,
            averageLoss: averageLoss,
            expectancy: expectancy,
            profitFactor: grossLoss > 0 ? grossProfit / grossLoss : nil,
            averageHoldWinners: averageHold(of: winners),
            averageHoldLosers: averageHold(of: losers),
            closedCount: closed.count
        )
    }

    private static func averageHold(of trades: [ClosedTrade]) -> Double? {
        let days = trades.compactMap(\.holdingDays)
        guard !days.isEmpty else { return nil }
        return days.reduce(0, +) / Double(days.count)
    }

    // MARK: - Reading the ledger

    /// Turns the trade ledger into closed trades with their holding periods.
    ///
    /// A sell's holding period runs from when the position was *opened*, not from the
    /// last top-up — so the ledger is replayed per symbol and the open date is stamped
    /// each time a position goes from flat to held. Averaging cost across top-ups makes
    /// any other answer arbitrary.
    static func closedTrades(from trades: [LedgerTrade]) -> [ClosedTrade] {
        var openedAt: [String: Date] = [:]
        var held: [String: Int] = [:]
        var closed: [ClosedTrade] = []

        for trade in trades.sorted(by: { $0.timestamp < $1.timestamp }) {
            let before = held[trade.symbol] ?? 0

            if trade.isBuy {
                if before <= 0 { openedAt[trade.symbol] = trade.timestamp }
                held[trade.symbol] = before + trade.quantity
                continue
            }

            if let realized = trade.realizedPnL {
                closed.append(
                    ClosedTrade(
                        symbol: trade.symbol,
                        realizedPnL: realized,
                        closedAt: trade.timestamp,
                        openedAt: openedAt[trade.symbol]
                    )
                )
            }

            let after = before - trade.quantity
            held[trade.symbol] = max(0, after)
            // Flat again, so the next buy starts a new position with a new open date.
            if after <= 0 { openedAt[trade.symbol] = nil }
        }

        return closed
    }
}
