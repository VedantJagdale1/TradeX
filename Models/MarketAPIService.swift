//
//  MarketAPIService.swift
//  TradeX
//
//  Created by vedant jagdale on 04/07/26.
//

import Foundation
enum NetworkError: Error, LocalizedError {
    case invalidURL
    case noData
    case decodingError
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That symbol produced an invalid request."
        case .noData: return "The market data service didn't respond."
        case .decodingError: return "The market data service returned something unexpected."
        case .rateLimited: return "Too many requests to the market data service. Prices will refresh shortly."
        }
    }
}

class MarketAPIService {
    static let shared = MarketAPIService()
    private init() {}

    /// Every request goes through here.
    ///
    /// Yahoo's chart endpoint is undocumented and unauthenticated; it answers more
    /// reliably with a browser-shaped User-Agent, and it rate-limits, which the callers
    /// need to be able to distinguish from "no data".
    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.noData
        }
        if httpResponse.statusCode == 429 {
            throw NetworkError.rateLimited
        }
        guard httpResponse.statusCode == 200 else {
            throw NetworkError.noData
        }
        return data
    }
    
    /// Returns the price series **and** the quote metadata from the same response.
    ///
    /// The last candle's close is not the live price. Reading `regularMarketPrice` out of
    /// the payload we already fetched keeps the detail screen consistent with the price
    /// the buy flow charges, at no extra request.
    func fetchHistoricalData(symbol: String, range: String = "1mo") async throws -> ChartSeries {
        try await chartSeries(yahooSymbol: symbol.hasSuffix(".NS") ? symbol : "\(symbol).NS", range: range)
    }

    /// History for a symbol used verbatim — index tickers must not be suffixed.
    func fetchIndexHistory(symbol: String, range: String) async throws -> ChartSeries {
        try await chartSeries(yahooSymbol: symbol, range: range)
    }

    private func chartSeries(yahooSymbol: String, range: String) async throws -> ChartSeries {
        // Flipping between ranges and back re-requests the same series; charts are also
        // the largest payloads the app fetches, so they hold longer than a quote.
        try await QuoteCache.shared.series(
            for: "\(yahooSymbol)|\(range)",
            maxAge: QuoteCache.historyMaxAge
        ) {
            try await self.chartSeriesUncached(yahooSymbol: yahooSymbol, range: range)
        }
    }

    private func chartSeriesUncached(yahooSymbol: String, range: String) async throws -> ChartSeries {
        let interval = (range == "1d") ? "15m" : "1d"
        
        let urlString = "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol)?range=\(range)&interval=\(interval)"
        
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }
        
        let data = try await get(url)
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
    func fetchIndexQuote(symbol: String, maxAge: TimeInterval = QuoteCache.defaultMaxAge) async throws -> IndexQuote {
        try await QuoteCache.shared.indexQuote(for: symbol, maxAge: maxAge) {
            try await self.fetchIndexQuoteUncached(symbol: symbol)
        }
    }

    private func fetchIndexQuoteUncached(symbol: String) async throws -> IndexQuote {
        let urlString = "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=1d"

        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }

        let data = try await get(url)
        let result = try JSONDecoder().decode(YahooChartResponse.self, from: data)

        guard let meta = result.chart.result?.first?.meta,
              let price = meta.regularMarketPrice,
              let previousClose = meta.chartPreviousClose else {
            throw NetworkError.decodingError
        }

        return IndexQuote(price: price, previousClose: previousClose)
    }

    /// A quote for one stock, shared through the cache.
    ///
    /// Pass `maxAge: 0` for a user-initiated refresh that must hit the network.
    func fetchStockPrice(symbol: String, maxAge: TimeInterval = QuoteCache.defaultMaxAge) async throws -> Double {
        try await QuoteCache.shared.price(for: symbol, maxAge: maxAge) {
            try await self.fetchStockPriceUncached(symbol: symbol)
        }
    }

    private func fetchStockPriceUncached(symbol: String) async throws -> Double {
        let yahooSymbol = symbol.hasSuffix(".NS") ? symbol : "\(symbol).NS"
        let urlString = "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol)?interval=1d&range=1d"
        
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }
        
        let data = try await get(url)
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


struct ChartPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let price: Double
}


/// A market index level and its move since the previous close.
///
/// Index levels are point values, not rupee amounts, so they are rendered without a
/// currency symbol.
struct IndexQuote: Sendable {
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
struct ChartSeries: Sendable {
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

    /// NSE trading holidays, as yyyy-MM-dd in IST.
    ///
    /// A hardcoded list rather than a feed: the exchange publishes these annually and
    /// they rarely move, and a wrong holiday only ever means an order rests a day longer
    /// than it should. Needs extending each year — a date past the end of the list is
    /// treated as a normal session.
    static let holidays: Set<String> = [
        // 2026
        "2026-01-26", // Republic Day
        "2026-03-04", // Holi
        "2026-03-21", // Id-Ul-Fitr
        "2026-04-01", // Mahavir Jayanti
        "2026-04-03", // Good Friday
        "2026-04-14", // Dr. Ambedkar Jayanti
        "2026-05-01", // Maharashtra Day
        "2026-05-27", // Bakri Id
        "2026-08-15", // Independence Day
        "2026-08-26", // Ganesh Chaturthi
        "2026-10-02", // Gandhi Jayanti
        "2026-10-21", // Diwali Laxmi Pujan
        "2026-11-05", // Guru Nanak Jayanti
        "2026-12-25", // Christmas
        // 2027
        "2027-01-26",
        "2027-03-25",
        "2027-08-15",
        "2027-10-02",
        "2027-11-09",
        "2027-12-25",
    ]

    private static let holidayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func isHoliday(_ date: Date) -> Bool {
        holidays.contains(holidayFormatter.string(from: date))
    }

    /// A weekday the exchange actually trades.
    static func isTradingDay(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = exchangeTimeZone
        let weekday = calendar.component(.weekday, from: date)
        return (2...6).contains(weekday) && !isHoliday(date)
    }

    static func isOpen(at date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = exchangeTimeZone

        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)

        // Sunday is 1, so Monday...Friday is 2...6.
        guard let weekday = parts.weekday, (2...6).contains(weekday),
              !isHoliday(date),
              let hour = parts.hour, let minute = parts.minute
        else { return false }

        let minutesIntoDay = hour * 60 + minute
        return minutesIntoDay >= openMinutes && minutesIntoDay <= closeMinutes
    }

    /// The next close after `date` — when a day order stops being live.
    ///
    /// Weekends and the published holiday list are both skipped.
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

        // Roll past weekends and holidays alike — a day order placed before Diwali
        // should expire at the next real session's close, not on the holiday itself.
        var guardRail = 0
        while !isTradingDay(candidate), guardRail < 30 {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            guardRail += 1
        }

        return candidate
    }
}


/// Shared quote cache sitting in front of the market API.
///
/// Nine call sites poll for prices — holdings refresh, daily snapshot, price alerts,
/// limit orders, the watchlist, index cards. Without this, opening the Dashboard fetches
/// the same symbol several times within a second, and a rate-limit response degrades
/// every one of them silently and independently.
actor QuoteCache {
    static let shared = QuoteCache()

    /// How long a quote stays fresh. Long enough to collapse one app-open into a single
    /// request per symbol, short enough that prices still feel live.
    static let defaultMaxAge: TimeInterval = 30

    /// Price history changes far more slowly than a quote, and costs more to fetch.
    static let historyMaxAge: TimeInterval = 300

    /// How long to stop asking after being rate-limited.
    private static let backoffDuration: TimeInterval = 120

    private struct Entry<Value> {
        let value: Value
        let fetchedAt: Date
    }

    private var prices: [String: Entry<Double>] = [:]
    private var indexQuotes: [String: Entry<IndexQuote>] = [:]
    private var histories: [String: Entry<ChartSeries>] = [:]

    /// In-flight fetches, so concurrent callers for one symbol share a single request.
    private var priceTasks: [String: Task<Double, Error>] = [:]
    private var indexTasks: [String: Task<IndexQuote, Error>] = [:]
    private var historyTasks: [String: Task<ChartSeries, Error>] = [:]

    private var backoffUntil: Date?

    func price(
        for symbol: String,
        maxAge: TimeInterval,
        fetch: @escaping @Sendable () async throws -> Double
    ) async throws -> Double {
        if let entry = prices[symbol], Date().timeIntervalSince(entry.fetchedAt) < maxAge {
            return entry.value
        }

        if let stale = try rateLimitFallback(prices[symbol]?.value) {
            return stale
        }

        if let existing = priceTasks[symbol] {
            return try await existing.value
        }

        let task = Task { try await fetch() }
        priceTasks[symbol] = task

        do {
            let value = try await task.value
            priceTasks[symbol] = nil
            prices[symbol] = Entry(value: value, fetchedAt: Date())
            return value
        } catch {
            priceTasks[symbol] = nil
            noteFailure(error)
            // A stale quote beats no quote: the caller would otherwise see nil and
            // silently skip an alert or an order check.
            if let stale = prices[symbol]?.value { return stale }
            throw error
        }
    }

    func indexQuote(
        for symbol: String,
        maxAge: TimeInterval,
        fetch: @escaping @Sendable () async throws -> IndexQuote
    ) async throws -> IndexQuote {
        if let entry = indexQuotes[symbol], Date().timeIntervalSince(entry.fetchedAt) < maxAge {
            return entry.value
        }

        if let stale = try rateLimitFallback(indexQuotes[symbol]?.value) {
            return stale
        }

        if let existing = indexTasks[symbol] {
            return try await existing.value
        }

        let task = Task { try await fetch() }
        indexTasks[symbol] = task

        do {
            let value = try await task.value
            indexTasks[symbol] = nil
            indexQuotes[symbol] = Entry(value: value, fetchedAt: Date())
            return value
        } catch {
            indexTasks[symbol] = nil
            noteFailure(error)
            if let stale = indexQuotes[symbol]?.value { return stale }
            throw error
        }
    }

    /// Price history, keyed by symbol and range.
    func series(
        for key: String,
        maxAge: TimeInterval,
        fetch: @escaping @Sendable () async throws -> ChartSeries
    ) async throws -> ChartSeries {
        if let entry = histories[key], Date().timeIntervalSince(entry.fetchedAt) < maxAge {
            return entry.value
        }

        if let stale = try rateLimitFallback(histories[key]?.value) {
            return stale
        }

        if let existing = historyTasks[key] {
            return try await existing.value
        }

        let task = Task { try await fetch() }
        historyTasks[key] = task

        do {
            let value = try await task.value
            historyTasks[key] = nil
            histories[key] = Entry(value: value, fetchedAt: Date())
            return value
        } catch {
            historyTasks[key] = nil
            noteFailure(error)
            if let stale = histories[key]?.value { return stale }
            throw error
        }
    }

    /// While backed off, serve what we have and otherwise fail fast — continuing to ask
    /// only extends the limit.
    private func rateLimitFallback<Value>(_ stale: Value?) throws -> Value? {
        guard let backoffUntil else { return nil }

        if Date() >= backoffUntil {
            self.backoffUntil = nil
            return nil
        }

        if let stale { return stale }
        throw NetworkError.rateLimited
    }

    private func noteFailure(_ error: Error) {
        if case NetworkError.rateLimited = error {
            backoffUntil = Date().addingTimeInterval(Self.backoffDuration)
        }
    }

    /// Testing and manual refresh: drop everything held.
    func invalidate() {
        prices.removeAll()
        indexQuotes.removeAll()
        histories.removeAll()
        backoffUntil = nil
    }
}
