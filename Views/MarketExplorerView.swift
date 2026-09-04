//
//  MarketExplorerView.swift
//  TradeX
//
//  Created by vedant jagdale on 02/07/26.
//

import SwiftUI
import SwiftData

struct MarketIndex: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var quote: IndexQuote?

    /// Yahoo's tickers for the two headline Indian indices.
    static let tracked = [
        MarketIndex(title: "NIFTY 50", symbol: "^NSEI"),
        MarketIndex(title: "SENSEX", symbol: "^BSESN")
    ]
}

struct MarketExplorerView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = MarketExplorerViewModel()

    /// One alert state for both the order ticket and its failures. Two separate
    /// `.alert` modifiers can drop one another when the second is presented as the
    /// first dismisses; a single presentation source can't.
    enum TradeAlert: Identifiable {
        case addPosition(stock: NSEStock, priceDetail: String)
        case failure(message: String)

        var id: String {
            switch self {
            case let .addPosition(stock, _): return "add-\(stock.id)"
            case let .failure(message): return "fail-\(message)"
            }
        }
    }

    @State private var activeAlert: TradeAlert?
    @State private var enteredQuantityString = "1"
    @State private var enteredBuyPriceString = ""
    @State private var enteredThesisString = ""

    @State private var indices = MarketIndex.tracked

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                if viewModel.searchText.isEmpty {

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(indices) { index in
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
        .task {
            await loadIndexLevels()
        }

        .alert(alertTitle, isPresented: alertPresentedBinding, presenting: activeAlert) { alert in
            switch alert {
            case let .addPosition(stock, _):
                TextField("Quantity", text: $enteredQuantityString)
                    .keyboardType(.numberPad)

                TextField("Average Buy Price (or leave blank for Live)", text: $enteredBuyPriceString)
                    .keyboardType(.decimalPad)

                TextField("Why this trade? (optional)", text: $enteredThesisString)

                Button("Cancel", role: .cancel) {
                    resetAddPositionInputs()
                }

                Button("Add Position") {
                    submitOrder(for: stock)
                }

            case .failure:
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case let .addPosition(_, priceDetail):
                Text("\(priceDetail)\n\nLeave the price field blank to automatically buy at the live current market price, or enter your custom price manually below.")
            case let .failure(message):
                Text(message)
            }
        }
    }
}


private extension MarketExplorerView {

    var alertTitle: String {
        switch activeAlert {
        case .addPosition: return "Add Position"
        case .failure: return "Order Not Placed"
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

    func resetAddPositionInputs() {
        enteredQuantityString = "1"
        enteredBuyPriceString = ""
        enteredThesisString = ""
    }

    /// Places the order, or reports exactly why it could not be placed. Nothing here
    /// invents a price or a quantity — a bad input or a failed quote aborts the trade.
    func submitOrder(for stock: NSEStock) {
        let quantityText = enteredQuantityString.trimmingCharacters(in: .whitespacesAndNewlines)
        let priceText = enteredBuyPriceString
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let thesisText = enteredThesisString.trimmingCharacters(in: .whitespacesAndNewlines)

        resetAddPositionInputs()

        Task { @MainActor in
            do {
                guard let quantity = Int(quantityText), quantity > 0 else {
                    throw PortfolioError.invalidQuantity
                }

                let buyPrice: Double
                if priceText.isEmpty {
                    guard let livePrice = try? await MarketAPIService.shared.fetchStockPrice(symbol: stock.symbol) else {
                        throw PortfolioError.priceUnavailable(symbol: stock.symbol)
                    }
                    buyPrice = livePrice
                } else {
                    guard let enteredPrice = Double(priceText), enteredPrice > 0 else {
                        throw PortfolioError.invalidPrice
                    }
                    buyPrice = enteredPrice
                }

                try await PortfolioManager.shared.addStock(
                    symbol: stock.symbol,
                    companyName: stock.name,
                    quantity: quantity,
                    buyPrice: buyPrice,
                    thesis: thesisText,
                    modelContext: modelContext
                )
            } catch {
                activeAlert = .failure(message: error.localizedDescription)
            }
        }
    }

    /// Loads both index levels concurrently. A failure leaves that card in its
    /// unavailable state rather than showing a stale or invented number.
    func loadIndexLevels() async {
        await withTaskGroup(of: (Int, IndexQuote?).self) { group in
            for (position, index) in indices.enumerated() {
                let symbol = index.symbol
                group.addTask {
                    (position, try? await MarketAPIService.shared.fetchIndexQuote(symbol: symbol))
                }
            }

            for await (position, quote) in group where quote != nil {
                indices[position].quote = quote
            }
        }
    }

    func indexCard(for index: MarketIndex) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(index.title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)

            if let quote = index.quote {
                // No ₹ symbol: an index is a level in points, not a rupee amount.
                Text("\(quote.price, specifier: "%.2f")")
                    .font(.headline)

                HStack(spacing: 2) {
                    Image(systemName: quote.isPositive ? "arrow.up" : "arrow.down")
                    Text("\(quote.isPositive ? "+" : "")\(quote.change, specifier: "%.2f") (\(quote.changePercent, specifier: "%.2f")%)")
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(quote.isPositive ? .green : .red)
            } else {
                Text("—")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Text("Level unavailable")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
                resetAddPositionInputs()

                // The stock and its quote travel together into the alert, so a slow
                // response for one row can no longer label itself with another row's stock.
                Task { @MainActor in
                    let priceDetail: String
                    if let livePrice = try? await MarketAPIService.shared.fetchStockPrice(symbol: stock.symbol) {
                        priceDetail = "Live Market Price: \(CurrencyFormatter.rupees(livePrice))"
                    } else {
                        priceDetail = "Live price unavailable right now — enter a buy price manually."
                    }
                    activeAlert = .addPosition(stock: stock, priceDetail: priceDetail)
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
