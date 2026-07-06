//
//  NSEStock.swift
//  TradeX
//
//  Created by vedant jagdale on 03/07/26.
//

import Foundation
import SwiftData


struct NSEStock: Identifiable, Hashable {
    let id = UUID()
    let symbol: String
    let name: String
    let series: String
    let isin: String
    
    var formattedSymbol: String {
        return "\(symbol).NS"
    }
}


class CSVParser {
    static func loadNSEStocks() -> [NSEStock] {
        var stocks: [NSEStock] = []
        
        
        guard let url = Bundle.main.url(forResource: "stock_list", withExtension: "csv") else {
            print("Error: stock_list.csv file not found in main app bundle.")
            return []
        }
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let rows = content.components(separatedBy: "\n")
            
            for row in rows.dropFirst() {
                let columns = parseCSVRow(row)
                
                if columns.count >= 2 {
                    let symbol = columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let series = columns.indices.contains(2) ? columns[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let isin = columns.indices.contains(6) ? columns[6].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    
                    if !symbol.isEmpty && (series == "EQ" || series.isEmpty) {
                        let stock = NSEStock(symbol: symbol, name: name, series: series, isin: isin)
                        stocks.append(stock)
                    }
                }
            }
        } catch {
            print("Error parsing CSV data: \(error)")
        }
        
        return stocks
    }
    
    private static func parseCSVRow(_ row: String) -> [String] {
        var columns: [String] = []
        var currentColumn = ""
        var isInsideQuotedField = false
        var index = row.startIndex
        
        while index < row.endIndex {
            let character = row[index]
            
            if character == "\"" {
                let nextIndex = row.index(after: index)
                
                if isInsideQuotedField, nextIndex < row.endIndex, row[nextIndex] == "\"" {
                    currentColumn.append(character)
                    index = nextIndex
                } else {
                    isInsideQuotedField.toggle()
                }
            } else if character == ",", !isInsideQuotedField {
                columns.append(currentColumn)
                currentColumn = ""
            } else {
                currentColumn.append(character)
            }
            
            index = row.index(after: index)
        }
        
        columns.append(currentColumn)
        return columns
    }
}


@Model
class UserSettings {
    var availableCash: Double
    
    init(availableCash: Double = 274500.00) {
        self.availableCash = availableCash
    }
}


@Model
final class PortfolioHolding {
    @Attribute(.unique) var id: UUID
    var symbol: String
    var companyName: String
    var quantity: Int
    var avgBuyPrice: Double
    var currentPrice: Double
    
    init(
        id: UUID = UUID(),
        symbol: String,
        companyName: String,
        quantity: Int,
        avgBuyPrice: Double,
        currentPrice: Double
    ) {
        self.id = id
        self.symbol = symbol
        self.companyName = companyName
        self.quantity = quantity
        self.avgBuyPrice = avgBuyPrice
        self.currentPrice = currentPrice
    }
    
    
    var investedAmount: Double {
        return Double(quantity) * avgBuyPrice
    }
    
    var currentValue: Double {
        return Double(quantity) * currentPrice
    }
    
    var totalPNL: Double {
        return currentValue - investedAmount
    }
    
    var pnlPercentage: Double {
        guard investedAmount > 0 else { return 0.0 }
        return (totalPNL / investedAmount) * 100.0
    }
    
    var isProfit: Bool {
        return totalPNL >= 0
    }
}
