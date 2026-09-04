//
//  TradeHistoryView.swift
//  TradeX
//

import SwiftUI
import SwiftData

struct TradeHistoryView: View {
    @Query(sort: \Trade.timestamp, order: .reverse) private var trades: [Trade]
    @Query(sort: \CashAdjustment.timestamp, order: .reverse) private var cashAdjustments: [CashAdjustment]

    /// Only sells book a result, so realised performance is measured over those alone.
    private var closedTrades: [Trade] {
        trades.filter(\.isClosingTrade)
    }

    private var totalRealizedPnL: Double {
        closedTrades.reduce(0) { $0 + ($1.realizedPnL ?? 0) }
    }

    private var winRate: Double {
        guard !closedTrades.isEmpty else { return 0 }
        let wins = closedTrades.filter { ($0.realizedPnL ?? 0) > 0 }.count
        return (Double(wins) / Double(closedTrades.count)) * 100
    }

    private var isNetProfit: Bool { totalRealizedPnL >= 0 }

    /// Capital actually put in. Falls back to the default opening balance for installs
    /// that predate cash logging and so have no adjustment rows.
    private var netDeposits: Double {
        cashAdjustments.isEmpty
            ? PortfolioManager.defaultStartingCash
            : cashAdjustments.reduce(0) { $0 + $1.amount }
    }

    /// Realised return measured against deposited capital, so topping up the balance
    /// can't flatter the number.
    private var realizedReturnPercent: Double {
        guard netDeposits > 0 else { return 0 }
        return (totalRealizedPnL / netDeposits) * 100
    }

    private var manualAdjustmentCount: Int {
        cashAdjustments.filter { $0.note != "Opening balance" }.count
    }

    var body: some View {
        Group {
            if trades.isEmpty {
                ContentUnavailableView(
                    "No Trades Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Every buy and sell you make will be recorded here, so you can review how your decisions actually played out.")
                )
            } else {
                List {
                    Section {
                        summaryCard
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    Section("All Trades (\(trades.count))") {
                        ForEach(trades) { trade in
                            tradeRow(for: trade)
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }
        }
        .navigationTitle("Trade History")
        .navigationBarTitleDisplayMode(.inline)
    }
}


private extension TradeHistoryView {

    var summaryCard: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Realised P&L")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("\(isNetProfit ? "+" : "")₹\(totalRealizedPnL, specifier: "%.2f")")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(closedTrades.isEmpty ? .primary : (isNetProfit ? Theme.profit : Theme.loss))
                Text("Booked across \(closedTrades.count) closed position\(closedTrades.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                statTile(title: "Win Rate", value: closedTrades.isEmpty ? "—" : String(format: "%.0f%%", winRate))
                Spacer()
                statTile(title: "Buys", value: "\(trades.filter(\.isBuy).count)")
                Spacer()
                statTile(title: "Sells", value: "\(closedTrades.count)")
            }

            Divider()

            HStack(alignment: .top) {
                currencyTile(title: "Capital Deposited", amount: netDeposits)
                Spacer()
                statTile(
                    title: "Return on Capital",
                    value: closedTrades.isEmpty ? "—" : String(format: "%@%.2f%%", realizedReturnPercent >= 0 ? "+" : "", realizedReturnPercent)
                )
            }

            if manualAdjustmentCount > 0 {
                Text("Includes \(manualAdjustmentCount) manual cash adjustment\(manualAdjustmentCount == 1 ? "" : "s"). Return is measured against deposited capital, so top-ups don't inflate it.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
        }
    }

    /// Currency must go through `Text`'s specifier interpolation, not `String(format:)`
    /// — only the former applies the locale's digit grouping (₹2,74,500.00 in en_IN).
    func currencyTile(title: String, amount: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text("₹\(amount, specifier: "%.2f")")
                .font(.headline)
        }
    }

    func tradeRow(for trade: Trade) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: trade.isBuy ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                .font(.title3)
                .foregroundStyle(trade.isBuy ? Theme.buySide : Theme.sellSide)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(trade.isBuy ? "BOUGHT" : "SOLD")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(trade.isBuy ? Theme.buySide : Theme.sellSide)
                    Text(trade.symbol)
                        .font(.headline)
                }

                Text("\(trade.quantity) @ ₹\(trade.price, specifier: "%.2f")")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(trade.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if !trade.thesis.isEmpty {
                    Text("\u{201C}\(trade.thesis)\u{201D}")
                        .font(.caption)
                        .italic()
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("₹\(trade.totalValue, specifier: "%.2f")")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                if let realizedPnL = trade.realizedPnL {
                    Text("\(realizedPnL >= 0 ? "+" : "")₹\(realizedPnL, specifier: "%.2f")")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(realizedPnL >= 0 ? Theme.profit : Theme.loss)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        TradeHistoryView()
    }
}
