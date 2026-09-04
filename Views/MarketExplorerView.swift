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

    @Query private var settings: [UserSettings]

    @State private var orderTicket: OrderTicket?
    @State private var pendingStock: NSEStock?
    @State private var loadingQuoteFor: UUID?

    @State private var indices = MarketIndex.tracked

    @Query(sort: \WatchlistItem.addedAt, order: .reverse) private var watchlist: [WatchlistItem]
    @State private var watchlistQuotes: [String: Double] = [:]

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

                    if !watchlist.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Watchlist")
                                .font(.title3)
                                .bold()

                            VStack(spacing: 0) {
                                ForEach(watchlist) { item in
                                    watchlistRow(for: item)

                                    if item.symbol != watchlist.last?.symbol {
                                        Divider()
                                    }
                                }
                            }
                            .card(padding: 12)
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
        .task(id: watchlist.count) {
            await loadWatchlistQuotes()
        }

        .sheet(item: $orderTicket) { ticket in
            OrderTicketView(ticket: ticket) { quantity, thesis in
                await placeBuy(quantity: quantity, thesis: thesis)
            }
        }
    }
}


private extension MarketExplorerView {

    /// Fetches a live quote, then opens the ticket for that stock. The symbol and its
    /// price travel together, so a slow response can't label itself with another row.
    func openTicket(for stock: NSEStock) {
        loadingQuoteFor = stock.id
        Task { @MainActor in
            let price = try? await MarketAPIService.shared.fetchStockPrice(symbol: stock.symbol)
            loadingQuoteFor = nil
            guard let price else { return }
            pendingStock = stock
            orderTicket = .buy(
                symbol: stock.symbol,
                companyName: stock.name,
                price: price,
                availableCash: settings.first?.availableCash ?? 0
            )
        }
    }

    /// Returns a message on failure, nil on success — the ticket renders it inline.
    func placeBuy(quantity: Int, thesis: String) async -> String? {
        guard let stock = pendingStock, let ticket = orderTicket else {
            return "Could not price that order. Try again."
        }
        do {
            try await PortfolioManager.shared.addStock(
                symbol: stock.symbol,
                companyName: stock.name,
                quantity: quantity,
                buyPrice: ticket.price,
                thesis: thesis,
                modelContext: modelContext
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func watchlistRow(for item: WatchlistItem) -> some View {
        NavigationLink {
            StockDetailView(stock: viewModel.stock(for: item.symbol)
                ?? NSEStock(symbol: item.symbol, name: item.companyName, series: "EQ", isin: ""))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.symbol)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(item.companyName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let price = watchlistQuotes[item.symbol] {
                    MoneyText(amount: price, font: .subheadline.weight(.semibold))
                } else {
                    ProgressView()
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Watchlist.remove(symbol: item.symbol, in: modelContext)
            } label: {
                Label("Remove from Watchlist", systemImage: "star.slash")
            }
        }
    }

    /// Quotes for watched symbols, fetched together rather than one after another.
    func loadWatchlistQuotes() async {
        let symbols = watchlist.map(\.symbol)
        guard !symbols.isEmpty else { return }

        let quotes = await withTaskGroup(of: (String, Double?).self) { group in
            for symbol in symbols {
                group.addTask {
                    (symbol, try? await MarketAPIService.shared.fetchStockPrice(symbol: symbol))
                }
            }
            var collected: [String: Double] = [:]
            for await (symbol, price) in group {
                if let price { collected[symbol] = price }
            }
            return collected
        }

        watchlistQuotes.merge(quotes) { _, new in new }
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
                .foregroundColor(quote.isPositive ? Theme.profit : Theme.loss)
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
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
                openTicket(for: stock)
            } label: {
                Group {
                    if loadingQuoteFor == stock.id {
                        ProgressView()
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.profit)
                    }
                }
                .frame(width: 28, height: 28)
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
