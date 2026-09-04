//
//  PortfolioView.swift
//  TradeX
//
//  Created by vedant jagdale on 02/07/26.
//

import SwiftUI
import SwiftData

struct PortfolioView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PortfolioHolding.symbol) private var holdings: [PortfolioHolding]
    @State private var isLoading = false

    /// The sell ticket presents as a sheet; failures render inside it, so there is no
    /// second alert racing the first one's dismissal.
    @State private var orderTicket: OrderTicket?
    @State private var pendingHolding: PortfolioHolding?


    var totalInvested: Double { holdings.reduce(0) { $0 + $1.investedAmount } }
    var totalCurrent: Double { holdings.reduce(0) { $0 + $1.currentValue } }
    var totalPNL: Double { totalCurrent - totalInvested }
    var totalPNLPercentage: Double { totalInvested > 0 ? (totalPNL / totalInvested) * 100 : 0 }
    var isOverallProfit: Bool { totalPNL >= 0 }

    var body: some View {
        List {

            Section {
                performanceMetricCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }


            Section(header: HStack {
                Text("Open Positions (\(holdings.count))")
                    .font(.headline)
                    .foregroundColor(.primary)
                    .textCase(nil)
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .onTapGesture {
                            Task { await updateLivePrices(force: true) }
                        }
                }
            }.padding(.vertical, 4)) {

                ForEach(holdings) { holding in
                    holdingRow(for: holding)
                        .listRowBackground(Color(.secondarySystemBackground))

                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            // Labelled "Sell", not "Remove": this credits the proceeds
                            // back to cash and books a realised P&L, so calling it a
                            // delete misrepresented what it does.
                            Button(role: .destructive) {
                                pendingHolding = holding
                                orderTicket = .sell(holding: holding)
                            } label: {
                                Label("Sell", systemImage: "indianrupeesign.circle")
                            }
                        }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Portfolio")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TradeHistoryView()
                } label: {
                    Label("Trade History", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .sheet(item: $orderTicket) { ticket in
            OrderTicketView(ticket: ticket) { quantity, thesis in
                await placeSell(quantity: quantity, thesis: thesis)
            }
        }
        .task {
            await updateLivePrices(force: false)
        }
    }
}


private extension PortfolioView {

    /// Returns a message on failure, nil on success — the ticket renders it inline.
    func placeSell(quantity: Int, thesis: String) async -> String? {
        guard let holding = pendingHolding else { return "That position is no longer open." }
        do {
            try PortfolioManager.shared.sellStock(
                holding,
                quantity: quantity,
                thesis: thesis,
                modelContext: modelContext
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func updateLivePrices(force: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await PortfolioManager.shared.refreshPrices(modelContext: modelContext, force: force)
    }


    var performanceMetricCard: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current Value")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    MoneyText(amount: totalCurrent, font: Theme.Typography.hero)
                }
                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Total Returns")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    MoneyText(amount: totalPNL, font: .headline, color: Theme.pnl(totalPNL), showsSign: true)
                    PercentText(value: totalPNLPercentage)
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Invested Capital")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    MoneyText(amount: totalInvested, font: .headline)
                }
                Spacer()
            }
        }
        .card()
    }


    func holdingRow(for holding: PortfolioHolding) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(holding.symbol)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text("\(holding.quantity) Shares")
                    Text("•")
                    Text("Avg: ₹\(holding.avgBuyPrice, specifier: "%.1f")")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                MoneyText(amount: holding.currentValue, font: .headline)

                HStack(spacing: 4) {
                    Image(systemName: holding.isProfit ? "arrow.up" : "arrow.down")
                    Text("\(Theme.sign(holding.pnlPercentage))\(holding.pnlPercentage, specifier: "%.2f")%")
                        .contentTransition(.numericText(value: holding.pnlPercentage))
                        .animation(Theme.Motion.value, value: holding.pnlPercentage)
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(holding.isProfit ? Theme.profit : Theme.loss)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        PortfolioView()
    }
}
