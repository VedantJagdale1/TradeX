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
    
    private var allStocks: [NSEStock] = []
    private var searchTask: Task<Void, Never>? = nil
    
    init() {
        self.allStocks = CSVParser.loadNSEStocks()
        setupInitialList()
    }
    
    private func setupInitialList() {
        let popular = ["RELIANCE", "TCS", "INFY", "HDFCBANK", "TATAMOTORS"]
        self.filteredStocks = allStocks.filter { popular.contains($0.symbol) }
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
