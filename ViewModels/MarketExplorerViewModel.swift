//
//  MarketExplorerViewModel.swift
//  TradeX
//
//  Created by vedant jagdale on 03/07/26.
//

import Foundation
import SwiftUI
import Combine

@MainActor
class MarketExplorerViewModel: ObservableObject {
    @Published var searchText: String = "" {
        didSet {
            triggerDebouncedSearch()
        }
    }
    @Published var filteredStocks: [NSEStock] = []
    @Published var isSearching: Bool = false

    /// Curated shortlist shown when the search field is empty.
    /// TATAMOTORS was removed from the NSE list by the Tata Motors demerger and now
    /// 404s on the quote API; TMCV ("Tata Motors Limited") is its successor.
    /// TMPV covers the passenger-vehicle entity if you prefer that one.
    private static let popularSymbols = ["RELIANCE", "TCS", "INFY", "HDFCBANK", "TMCV"]

    private var allStocks: [NSEStock] = []
    private var stocksBySymbol: [String: NSEStock] = [:]
    private var searchTask: Task<Void, Never>? = nil

    init() {
        self.allStocks = CSVParser.loadNSEStocks()
        self.stocksBySymbol = Dictionary(
            allStocks.map { ($0.symbol, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        setupInitialList()
    }

    /// Looks up the full CSV record for a symbol, so a watchlist row can push a detail
    /// screen with the real name, series and ISIN rather than a stub.
    func stock(for symbol: String) -> NSEStock? {
        stocksBySymbol[symbol]
    }

    private func setupInitialList() {
        // Resolved through the symbol index so the curated order is preserved, and so a
        // symbol that isn't in the CSV trips an assertion in debug instead of silently
        // shortening the list the way the old `allStocks.filter` did.
        self.filteredStocks = Self.popularSymbols.compactMap { symbol in
            guard let stock = stocksBySymbol[symbol] else {
                assertionFailure("Popular symbol '\(symbol)' is missing from stock_list.csv")
                return nil
            }
            return stock
        }
    }

    private func triggerDebouncedSearch() {
        searchTask?.cancel()
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedSearchText.isEmpty {
            setupInitialList()
            isSearching = false
            return
        }

        isSearching = true
        let query = trimmedSearchText.lowercased()

        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)

                guard !Task.isCancelled else { return }

                let results = allStocks.filter { stock in
                    stock.symbol.lowercased().contains(query) ||
                    stock.name.lowercased().contains(query)
                }

                guard !Task.isCancelled else { return }

                self.filteredStocks = results
                self.isSearching = false

            } catch {

            }
        }
    }
}
