//
//  MarketExplorerView.swift
//  TradeX
//
//  Created by vedant jagdale on 02/07/26.
//

import SwiftUI
import SwiftData

struct IndexData: Identifiable {
    let id = UUID()
    let title: String
    let price: Double
    let change: Double
    let isPositive: Bool
}

struct MarketExplorerView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = MarketExplorerViewModel()
    
    
    @State private var showingQuantityAlert = false
    @State private var selectedStockForPortfolio: NSEStock? = nil
    @State private var enteredQuantityString = "1"
    @State private var enteredBuyPriceString = ""
    @State private var alertMessageDetail = ""
    
    let mockIndices = [
        IndexData(title: "NIFTY 50", price: 23450.75, change: 112.40, isPositive: true),
        IndexData(title: "SENSEX", price: 77100.30, change: -240.15, isPositive: false)
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                
                if viewModel.searchText.isEmpty {
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(mockIndices) { index in
                                indexCard(for: index)
                            }
                        }
                    }
                    
                    Text("Popular Stocks")
                        .font(.title3)
                        .bold()
                }
                
                if viewModel.isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                }
                
                
                VStack(spacing: 0) {
                    ForEach(viewModel.filteredStocks) { stock in
                        NavigationLink(destination: StockDetailView(stock: stock)) {
                            nseStockRow(for: stock)
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        if stock.id != viewModel.filteredStocks.last?.id {
                            Divider()
                        }
                    }
                    
                    if viewModel.filteredStocks.isEmpty && !viewModel.isSearching {
                        ContentUnavailableView.search(text: viewModel.searchText)
                            .padding(.top, 40)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Explore")
        .searchable(text: $viewModel.searchText, prompt: "Search 2,000+ NSE stocks...")
        
        
        .alert("Add Position", isPresented: $showingQuantityAlert, presenting: selectedStockForPortfolio) { stock in
            TextField("Quantity", text: $enteredQuantityString)
                .keyboardType(.numberPad)
            
            TextField("Average Buy Price (or leave blank for Live)", text: $enteredBuyPriceString)
                .keyboardType(.decimalPad)
            
            Button("Cancel", role: .cancel) {
                resetAddPositionInputs()
            }
            
            Button("Add Position") {
                let normalizedBuyPrice = enteredBuyPriceString.replacingOccurrences(of: ",", with: "")
                let quantity = Int(enteredQuantityString) ?? 1
                
                Task {
                    var targetBuyPrice: Double = 0.0
                    
                    
                    if normalizedBuyPrice.isEmpty || (Double(normalizedBuyPrice) ?? 0.0) <= 0 {
                        do {
                            targetBuyPrice = try await MarketAPIService.shared.fetchStockPrice(symbol: stock.symbol)
                        } catch {
                            print("Fallback tracking failed: \(error)")
                            targetBuyPrice = 100.0
                        }
                    } else {
                        
                        targetBuyPrice = Double(normalizedBuyPrice) ?? 0.0
                    }
                    
                    if quantity > 0 && targetBuyPrice > 0 {
                        await PortfolioManager.shared.addStock(
                            symbol: stock.symbol,
                            companyName: stock.name,
                            quantity: quantity,
                            buyPrice: targetBuyPrice,
                            modelContext: modelContext
                        )
                    }
                }
                resetAddPositionInputs()
            }
        } message: { stock in
            Text("\(alertMessageDetail)\n\nLeave the price field blank to automatically buy at the live current market price, or enter your custom price manually below.")
        }
    }
}


private extension MarketExplorerView {
    
    func resetAddPositionInputs() {
        enteredQuantityString = "1"
        enteredBuyPriceString = ""
        alertMessageDetail = ""
    }
    
    func indexCard(for index: IndexData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(index.title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            Text("₹\(index.price, specifier: "%.2f")")
                .font(.headline)
            
            HStack(spacing: 2) {
                Image(systemName: index.isPositive ? "arrow.up" : "arrow.down")
                Text("\(index.isPositive ? "+" : "")\(index.change, specifier: "%.2f")")
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(index.isPositive ? .green : .red)
        }
        .padding()
        .frame(width: 160, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    func nseStockRow(for stock: NSEStock) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(stock.symbol)
                    .font(.headline)
                Text(stock.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            
            Button {
                selectedStockForPortfolio = stock
                resetAddPositionInputs()
                
                
                Task {
                    do {
                        let livePrice = try await MarketAPIService.shared.fetchStockPrice(symbol: stock.symbol)
                        await MainActor.run {
                            self.alertMessageDetail = "Live Market Price: ₹\(String(format: "%.2f", livePrice))"
                            self.showingQuantityAlert = true
                        }
                    } catch {
                        await MainActor.run {
                            self.alertMessageDetail = "Live price fetch unavailable right now."
                            self.showingQuantityAlert = true
                        }
                    }
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundColor(.green)
                    .padding(.leading, 8)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        MarketExplorerView()
    }
}
