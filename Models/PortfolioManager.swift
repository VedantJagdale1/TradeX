//
//  PortfolioManager.swift
//  TradeX
//
//  Created by vedant jagdale on 04/07/26.
//

import Foundation
import SwiftData

@MainActor
final class PortfolioManager {
    static let shared = PortfolioManager()
    
    private init() {}
    
    /// Adds a stock to the portfolio or increments quantity if it already exists.
    /// The holding appears immediately, then current price updates if live data is available.
    func addStock(
        symbol: String,
        companyName: String,
        quantity: Int,
        buyPrice: Double,
        modelContext: ModelContext
    ) async {
        let holding = fetchHolding(symbol: symbol, modelContext: modelContext)
        
        if let holding {
            let totalQuantity = holding.quantity + quantity
            let totalCost = (Double(holding.quantity) * holding.avgBuyPrice) + (Double(quantity) * buyPrice)
            holding.quantity = totalQuantity
            holding.avgBuyPrice = totalCost / Double(totalQuantity)
        } else {
            let newHolding = PortfolioHolding(
                symbol: symbol,
                companyName: companyName,
                quantity: quantity,
                avgBuyPrice: buyPrice,
                currentPrice: buyPrice
            )
            modelContext.insert(newHolding)
        }
        
        save(modelContext)
        
        do {
            let liveCurrentPrice = try await MarketAPIService.shared.fetchStockPrice(symbol: symbol)
            updateCurrentPrice(symbol: symbol, currentPrice: liveCurrentPrice, modelContext: modelContext)
        } catch {
            print("Could not fetch current price for \(symbol): \(error)")
        }
    }
    
    func removeStock(_ holding: PortfolioHolding, modelContext: ModelContext) {
        modelContext.delete(holding)
        save(modelContext)
    }
    
    func updateCurrentPrice(symbol: String, currentPrice: Double, modelContext: ModelContext) {
        guard let holding = fetchHolding(symbol: symbol, modelContext: modelContext) else { return }
        holding.currentPrice = currentPrice
        save(modelContext)
    }
    
    private func fetchHolding(symbol: String, modelContext: ModelContext) -> PortfolioHolding? {
        let descriptor = FetchDescriptor<PortfolioHolding>(
            predicate: #Predicate { $0.symbol == symbol }
        )
        return try? modelContext.fetch(descriptor).first
    }
    
    private func save(_ modelContext: ModelContext) {
        do {
            try modelContext.save()
        } catch {
            print("Could not save portfolio changes: \(error)")
        }
    }
}
