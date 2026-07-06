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
    @State private var holdingPendingRemoval: PortfolioHolding?
    
    
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
                            Task { await updateLivePrices() }
                        }
                }
            }.padding(.vertical, 4)) {
                
                ForEach(holdings) { holding in
                    holdingRow(for: holding)
                        .listRowBackground(Color(.secondarySystemBackground))
                    
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                holdingPendingRemoval = holding
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Portfolio")
        .alert("Remove Stock", isPresented: removeStockAlertBinding, presenting: holdingPendingRemoval) { holding in
            Button("Cancel", role: .cancel) {
                holdingPendingRemoval = nil
            }
            Button("Remove", role: .destructive) {
                PortfolioManager.shared.removeStock(holding, modelContext: modelContext)
                holdingPendingRemoval = nil
            }
        } message: { holding in
            Text("Remove \(holding.symbol) from your portfolio?")
        }
        .task {
            await updateLivePrices()
        }
    }
}


private extension PortfolioView {
    
    var removeStockAlertBinding: Binding<Bool> {
        Binding(
            get: { holdingPendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    holdingPendingRemoval = nil
                }
            }
        )
    }
    
    func updateLivePrices() async {
        guard !isLoading else { return }
        isLoading = true
        
        for holding in holdings {
            do {
                let freshPrice = try await MarketAPIService.shared.fetchStockPrice(symbol: holding.symbol)
                PortfolioManager.shared.updateCurrentPrice(
                    symbol: holding.symbol,
                    currentPrice: freshPrice,
                    modelContext: modelContext
                )
            } catch {
                print("Could not refresh price for \(holding.symbol): \(error)")
            }
        }
        
        isLoading = false
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
