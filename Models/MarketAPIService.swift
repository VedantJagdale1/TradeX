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
    
    /// Returns the price series **and** the quote metadata from the same response.
    ///
    /// The last candle's close is not the live price. Reading `regularMarketPrice` out of
    /// the payload we already fetched keeps the detail screen consistent with the price
    /// the buy flow charges, at no extra request.
    func fetchHistoricalData(symbol: String, range: String = "1mo") async throws -> ChartSeries {
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
        
        return ChartSeries(
            points: points,
            latestPrice: chartResult.meta.regularMarketPrice,
            previousClose: chartResult.meta.chartPreviousClose
        )
    }
    
    /// Fetches a quote for a symbol used verbatim — no `.NS` suffix.
    ///
    /// Index tickers (`^NSEI`, `^BSESN`) are not NSE equities and must not be suffixed.
    /// `URL(string:)` percent-encodes the leading caret on its own.
    func fetchIndexQuote(symbol: String) async throws -> IndexQuote {
        let urlString = "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=1d"

        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NetworkError.noData
        }

        let result = try JSONDecoder().decode(YahooChartResponse.self, from: data)

        guard let meta = result.chart.result?.first?.meta,
              let price = meta.regularMarketPrice,
              let previousClose = meta.chartPreviousClose else {
            throw NetworkError.decodingError
        }

        return IndexQuote(price: price, previousClose: previousClose)
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


/// A market index level and its move since the previous close.
///
/// Index levels are point values, not rupee amounts, so they are rendered without a
/// currency symbol.
struct IndexQuote {
    let price: Double
    let previousClose: Double

    var change: Double { price - previousClose }

    var changePercent: Double {
        guard previousClose > 0 else { return 0 }
        return (change / previousClose) * 100
    }

    var isPositive: Bool { change >= 0 }
}


/// A price series plus the live quote that came back with it.
struct ChartSeries {
    let points: [ChartPoint]
    let latestPrice: Double?
    let previousClose: Double?

    /// Prefers the live quote, falling back to the most recent close.
    var displayPrice: Double? {
        latestPrice ?? points.last?.price
    }
}


/// NSE trading hours.
///
/// Fills must only happen inside a session. Yahoo returns the last close outside hours,
/// so without this an order placed on Friday would "execute" against a stale price the
/// next time the app is opened at 2am on a Sunday.
enum MarketSession {
    static let exchangeTimeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current

    private static let openMinutes = 9 * 60 + 15   // 09:15 IST
    private static let closeMinutes = 15 * 60 + 30 // 15:30 IST

    static func isOpen(at date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = exchangeTimeZone

        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)

        // Sunday is 1, so Monday...Friday is 2...6.
        guard let weekday = parts.weekday, (2...6).contains(weekday),
              let hour = parts.hour, let minute = parts.minute
        else { return false }

        let minutesIntoDay = hour * 60 + minute
        return minutesIntoDay >= openMinutes && minutesIntoDay <= closeMinutes
    }

    /// The next close after `date` — when a day order stops being live.
    ///
    /// Exchange holidays are not modelled, so a day order placed before a holiday
    /// expires at that day's nominal close rather than the next real session's.
    static func nextClose(after date: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = exchangeTimeZone

        var candidate = calendar.date(
            bySettingHour: closeMinutes / 60,
            minute: closeMinutes % 60,
            second: 0,
            of: date
        ) ?? date

        if candidate <= date {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }

        // Roll past the weekend.
        while !(2...6).contains(calendar.component(.weekday, from: candidate)) {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }

        return candidate
    }
}
