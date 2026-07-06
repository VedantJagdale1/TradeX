//
//  MarketAPIService.swift
//  TradeX
//
//  Created by vedant jagdale on 04/07/26.
//

import Foundation
enum NetworkError: Error {
    case invalidURL
    case noData
    case decodingError
}

class MarketAPIService {
    static let shared = MarketAPIService()
    private init() {}
    
    func fetchHistoricalData(symbol: String, range: String = "1mo") async throws -> [ChartPoint] {
        let yahooSymbol = symbol.hasSuffix(".NS") ? symbol : "\(symbol).NS"
        
        let interval = (range == "1d") ? "15m" : "1d"
        
        let urlString = "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol)?range=\(range)&interval=\(interval)"
        
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NetworkError.noData
        }
        
        let result = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        
        guard let chartResult = result.chart.result?.first,
              let timestamps = chartResult.timestamp,
              let closePrices = chartResult.indicators?.quote?.first?.close else {
            throw NetworkError.decodingError
        }
        
        
        var points: [ChartPoint] = []
        for (index, timestamp) in timestamps.enumerated() {
            if index < closePrices.count, let price = closePrices[index] {
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                points.append(ChartPoint(date: date, price: price))
            }
        }
        
        return points
    }
    
    func fetchStockPrice(symbol: String) async throws -> Double {
        let yahooSymbol = symbol.hasSuffix(".NS") ? symbol : "\(symbol).NS"
        let urlString = "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol)?interval=1d&range=1d"
        
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NetworkError.noData
        }
        
        let result = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        
        guard let price = result.chart.result?.first?.meta.regularMarketPrice else {
            throw NetworkError.decodingError
        }
        
        return price
    }
}



struct YahooChartResponse: Decodable {
    let chart: YahooChart
}

struct YahooChart: Decodable {
    let result: [YahooChartResult]?
}

struct YahooChartResult: Decodable {
    let meta: YahooChartMeta
    let timestamp: [Int]?
    let indicators: YahooIndicators?
}

struct YahooChartMeta: Decodable {
    let regularMarketPrice: Double?
    let chartPreviousClose: Double?
}

struct YahooIndicators: Decodable {
    let quote: [YahooQuoteArray]?
}

struct YahooQuoteArray: Decodable {
    let close: [Double?]?
}


struct ChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let price: Double
}
