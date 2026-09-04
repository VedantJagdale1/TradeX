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
    @Query(sort: \LimitOrder.createdAt, order: .reverse) private var limitOrders: [LimitOrder]
    private var openOrders: [LimitOrder] { limitOrders.filter(\.isOpen) }

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


            if !openOrders.isEmpty {
                Section("Pending Orders (\(openOrders.count))") {
                    ForEach(openOrders) { order in
                        pendingOrderRow(for: order)
                            .listRowBackground(Theme.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    LimitOrderService.cancel(order, modelContext: modelContext)
                                } label: {
                                    Label("Cancel", systemImage: "xmark.circle")
                                }
                            }
                    }
                }
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
            OrderTicketView(ticket: ticket) { request in
                await placeSell(request)
            }
        }
        .task {
            await updateLivePrices(force: false)
        }
    }
}


private extension PortfolioView {

    /// Returns a message on failure, nil on success — the ticket renders it inline.
    func placeSell(_ request: OrderRequest) async -> String? {
        guard let holding = pendingHolding else { return "That position is no longer open." }

        // A limit order rests instead of executing; the shares stay in the position
        // until it fills.
        if let limitPrice = request.limitPrice {
            LimitOrderService.place(
                symbol: holding.symbol,
                companyName: holding.companyName,
                isBuy: false,
                quantity: request.quantity,
                limitPrice: limitPrice,
                thesis: request.thesis,
                modelContext: modelContext
            )
            await PriceAlertService.requestAuthorization()
            return nil
        }

        do {
            try PortfolioManager.shared.sellStock(
                holding,
                quantity: request.quantity,
                thesis: request.thesis,
                modelContext: modelContext
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func pendingOrderRow(for order: LimitOrder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: order.isBuy ? "arrow.down.circle" : "arrow.up.circle")
                .font(.title3)
                .foregroundStyle(order.isBuy ? Theme.buySide : Theme.sellSide)

            VStack(alignment: .leading, spacing: 2) {
                Text(order.symbol)
                    .font(.headline)
                Text(order.conditionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Resting")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                )
        }
        .padding(.vertical, 4)
    }

    func updateLivePrices(force: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await PortfolioManager.shared.refreshPrices(modelContext: modelContext, force: force)
        await LimitOrderService.checkAll(modelContext: modelContext)
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
