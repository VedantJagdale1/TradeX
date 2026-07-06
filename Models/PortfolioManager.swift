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
    
        func addStock(
            symbol: String,
            companyName: String,
            quantity: Int,
            buyPrice: Double,
            modelContext: ModelContext
        ) async {
            let totalCost = Double(quantity) * buyPrice
            let holding = fetchHolding(symbol: symbol, modelContext: modelContext)
            
      
            let settingsDescriptor = FetchDescriptor<UserSettings>()
            let appSettings = try? modelContext.fetch(settingsDescriptor).first
            
            if let holding {
                let totalQuantity = holding.quantity + quantity
                let dynamicTotalCost = (Double(holding.quantity) * holding.avgBuyPrice) + totalCost
                holding.quantity = totalQuantity
                holding.avgBuyPrice = dynamicTotalCost / Double(totalQuantity)
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
            
     
            if let appSettings {
                appSettings.availableCash = max(0, appSettings.availableCash - totalCost)
            } else {
                
                let defaultStartingCash = 274500.00
                let newSettings = UserSettings(availableCash: max(0, defaultStartingCash - totalCost))
                modelContext.insert(newSettings)
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
            let refundAmount = holding.currentValue
            
            
            let settingsDescriptor = FetchDescriptor<UserSettings>()
            if let appSettings = try? modelContext.fetch(settingsDescriptor).first {
                appSettings.availableCash += refundAmount
            }
            
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
