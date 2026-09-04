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

    /// Single presentation source for the sell ticket and its failures, so the error
    /// can't be swallowed by the ticket's own dismissal.
    enum SellAlert: Identifiable {
        case ticket(holding: PortfolioHolding)
        case failure(message: String)

        var id: String {
            switch self {
            case let .ticket(holding): return "sell-\(holding.id)"
            case let .failure(message): return "fail-\(message)"
            }
        }
    }

    @State private var activeAlert: SellAlert?
    @State private var sellQuantityString = ""
    @State private var sellThesisString = ""


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
                        .foregroundColor(.purple)
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
                                sellQuantityString = "\(holding.quantity)"
                                sellThesisString = ""
                                activeAlert = .ticket(holding: holding)
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
        .alert(alertTitle, isPresented: alertPresentedBinding, presenting: activeAlert) { alert in
            switch alert {
            case let .ticket(holding):
                TextField("Quantity to sell", text: $sellQuantityString)
                    .keyboardType(.numberPad)

                TextField("Why sell? (optional)", text: $sellThesisString)

                Button("Cancel", role: .cancel) {}

                Button("Sell", role: .destructive) {
                    submitSell(holding, quantityText: sellQuantityString, thesis: sellThesisString)
                }

            case .failure:
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case let .ticket(holding):
                Text("You hold \(holding.quantity) \(holding.symbol) at ₹\(holding.currentPrice, specifier: "%.2f") (avg cost ₹\(holding.avgBuyPrice, specifier: "%.2f")).\n\nSell fewer than \(holding.quantity) to close part of the position.")
            case let .failure(message):
                Text(message)
            }
        }
        .task {
            await updateLivePrices(force: false)
        }
    }
}


private extension PortfolioView {

    var alertTitle: String {
        switch activeAlert {
        case let .ticket(holding): return "Sell \(holding.symbol)"
        case .failure: return "Sale Not Completed"
        case nil: return ""
        }
    }

    var alertPresentedBinding: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { isPresented in
                if !isPresented { activeAlert = nil }
            }
        )
    }

    func submitSell(_ holding: PortfolioHolding, quantityText: String, thesis: String) {
        let trimmedQuantity = quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThesis = thesis.trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor in
            // Let the ticket finish dismissing first. Presenting a second alert in the
            // same turn as the first one's dismissal drops it.
            try? await Task.sleep(nanoseconds: 350_000_000)

            do {
                guard let quantity = Int(trimmedQuantity) else {
                    throw PortfolioError.invalidQuantity
                }
                try PortfolioManager.shared.sellStock(
                    holding,
                    quantity: quantity,
                    thesis: trimmedThesis,
                    modelContext: modelContext
                )
            } catch {
                activeAlert = .failure(message: error.localizedDescription)
            }
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
                    Text("₹\(totalCurrent, specifier: "%.2f")")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                }
                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Total Returns")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(isOverallProfit ? "+" : "")₹\(totalPNL, specifier: "%.2f")")
                        .font(.headline)
                        .foregroundColor(isOverallProfit ? .green : .red)
                    Text(String(format: "%.2f%%", totalPNLPercentage))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(isOverallProfit ? .green : .red)
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Invested Capital")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("₹\(totalInvested, specifier: "%.2f")")
                        .font(.headline)
                }
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
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
                Text("₹\(holding.currentValue, specifier: "%.2f")")
                    .font(.headline)

                HStack(spacing: 4) {
                    Image(systemName: holding.isProfit ? "arrow.up" : "arrow.down")
                    Text("\(holding.isProfit ? "+" : "")\(holding.pnlPercentage, specifier: "%.2f")%")
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(holding.isProfit ? .green : .red)
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
