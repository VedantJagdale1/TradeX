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
        
        
        let bars = chartResult.indicators?.quote?.first

        var points: [ChartPoint] = []
        for (index, timestamp) in timestamps.enumerated() {
            guard index < closePrices.count, let price = closePrices[index] else { continue }

            // Each series is indexed in step with the timestamps, but a gap in one does
            // not imply a gap in another, so every lookup is bounds-checked on its own.
            func value<T>(_ series: [T?]?) -> T? {
                guard let series, index < series.count else { return nil }
                return series[index]
            }

            points.append(
                ChartPoint(
                    date: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                    price: price,
                    open: value(bars?.open),
                    high: value(bars?.high),
                    low: value(bars?.low),
                    volume: value(bars?.volume)
                )
            )
        }

        return ChartSeries(
            points: points,
            quote: try? StockQuote(meta: chartResult.meta),
            rangeBaseline: chartResult.meta.chartPreviousClose
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

    /// Splits and bonus issues reported for a symbol.
    ///
    /// Not cached: this is checked at most once a day and a stale answer here silently
    /// corrupts a cost basis, which is worse than an extra request.
    func fetchSplits(symbol: String, range: String = "2y") async throws -> [SplitEvent] {
        let yahooSymbol = symbol.hasSuffix(".NS") ? symbol : "\(symbol).NS"
        let urlString = "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol)?range=\(range)&interval=1d&events=split"

        guard let url = URL(string: urlString) else { throw NetworkError.invalidURL }

        let data = try await get(url)
        let result = try JSONDecoder().decode(YahooChartResponse.self, from: data)

        guard let splits = result.chart.result?.first?.events?.splits else { return [] }

        return splits.values
            .compactMap { raw -> SplitEvent? in
                guard raw.numerator > 0, raw.denominator > 0 else { return nil }
                return SplitEvent(
                    date: Date(timeIntervalSince1970: TimeInterval(raw.date)),
                    numerator: raw.numerator,
                    denominator: raw.denominator
                )
            }
            .sorted { $0.date < $1.date }
    }

    /// A full quote for one stock, shared through the cache.
    ///
    /// Pass `maxAge: 0` for a user-initiated refresh that must hit the network.
    func fetchQuote(symbol: String, maxAge: TimeInterval = QuoteCache.defaultMaxAge) async throws -> StockQuote {
        try await QuoteCache.shared.quote(for: symbol, maxAge: maxAge) {
            try await self.fetchQuoteUncached(symbol: symbol)
        }
    }

    /// Just the price, for the many callers that need nothing else.
    func fetchStockPrice(symbol: String, maxAge: TimeInterval = QuoteCache.defaultMaxAge) async throws -> Double {
        try await fetchQuote(symbol: symbol, maxAge: maxAge).price
    }

    private func fetchQuoteUncached(symbol: String) async throws -> StockQuote {
        let yahooSymbol = symbol.hasSuffix(".NS") ? symbol : "\(symbol).NS"
        let urlString = "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol)?interval=1d&range=1d"
        
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }
        
        let data = try await get(url)
        let result = try JSONDecoder().decode(YahooChartResponse.self, from: data)

        guard let meta = result.chart.result?.first?.meta else {
            throw NetworkError.decodingError
        }

        return try StockQuote(meta: meta)
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
    let events: YahooEvents?
}

struct YahooEvents: Decodable {
    let splits: [String: YahooSplit]?
}

struct YahooSplit: Decodable {
    let date: Int
    let numerator: Double
    let denominator: Double
}

/// A split or bonus issue: `numerator` new shares for every `denominator` held.
struct SplitEvent: Sendable, Equatable {
    let date: Date
    let numerator: Double
    let denominator: Double

    /// How many shares each existing share becomes. Above 1 for a split or bonus,
    /// below 1 for a consolidation.
    var shareMultiplier: Double { numerator / denominator }

    var ratioDescription: String {
        "\(Int(numerator)):\(Int(denominator))"
    }
}

struct YahooChartMeta: Decodable {
    let regularMarketPrice: Double?
    let chartPreviousClose: Double?
    let previousClose: Double?
    let regularMarketDayHigh: Double?
    let regularMarketDayLow: Double?
    let regularMarketVolume: Int?
    let fiftyTwoWeekHigh: Double?
    let fiftyTwoWeekLow: Double?
    let longName: String?
}

/// Everything one quote tells us.
///
/// All of this arrives with every price request and used to be discarded, so the day
/// change and the 52-week range cost nothing beyond reading fields already downloaded.
struct StockQuote: Sendable {
    let price: Double
    let previousClose: Double?
    let dayHigh: Double?
    let dayLow: Double?
    let fiftyTwoWeekHigh: Double?
    let fiftyTwoWeekLow: Double?
    let volume: Int?
    let longName: String?

    nonisolated init(meta: YahooChartMeta) throws {
        guard let price = meta.regularMarketPrice else { throw NetworkError.decodingError }
        self.price = price
        // `chartPreviousClose` is what the chart is drawn against; `previousClose` is
        // the fallback for ranges that don't carry it.
        self.previousClose = meta.chartPreviousClose ?? meta.previousClose
        self.dayHigh = meta.regularMarketDayHigh
        self.dayLow = meta.regularMarketDayLow
        self.fiftyTwoWeekHigh = meta.fiftyTwoWeekHigh
        self.fiftyTwoWeekLow = meta.fiftyTwoWeekLow
        self.volume = meta.regularMarketVolume
        self.longName = meta.longName
    }

    /// A quote with nothing but a price, for callers that only need the number.
    nonisolated init(
        price: Double,
        previousClose: Double? = nil,
        dayHigh: Double? = nil,
        dayLow: Double? = nil,
        fiftyTwoWeekHigh: Double? = nil,
        fiftyTwoWeekLow: Double? = nil,
        volume: Int? = nil,
        longName: String? = nil
    ) {
        self.price = price
        self.previousClose = previousClose
        self.dayHigh = dayHigh
        self.dayLow = dayLow
        self.fiftyTwoWeekHigh = fiftyTwoWeekHigh
        self.fiftyTwoWeekLow = fiftyTwoWeekLow
        self.volume = volume
        self.longName = longName
    }

    var dayChange: Double? { previousClose.map { price - $0 } }

    var dayChangePercent: Double? {
        guard let previousClose, previousClose > 0 else { return nil }
        return ((price - previousClose) / previousClose) * 100
    }

    /// Where today's price sits in the yearly range: 0 at the low, 1 at the high.
    var positionInYearRange: Double? {
        guard let high = fiftyTwoWeekHigh, let low = fiftyTwoWeekLow, high > low else { return nil }
        return min(1, max(0, (price - low) / (high - low)))
    }
}

struct YahooIndicators: Decodable {
    let quote: [YahooQuoteArray]?
}

struct YahooQuoteArray: Decodable {
    let close: [Double?]?
    let open: [Double?]?
    let high: [Double?]?
    let low: [Double?]?
    let volume: [Int?]?
}


struct ChartPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let price: Double

    /// The rest of the bar. Yahoo returns these alongside the close, and without them a
    /// chart can only draw a line — no candles, no volume, no true range high and low.
    /// Nil when the payload omitted them for this bar.
    var open: Double?
    var high: Double?
    var low: Double?
    var volume: Int?

    /// A bar that closed above where it opened. Falls back to flat when the open is
    /// unknown, so an incomplete bar is never coloured as a decline it didn't have.
    var isUp: Bool { (open.map { price >= $0 }) ?? true }

    /// True when this bar carries a full high/low range worth drawing a wick for.
    var hasRange: Bool {
        guard let high, let low else { return false }
        return high.isFinite && low.isFinite && high >= low
    }
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

    /// The quote that came back alongside the series, when the payload carried one.
    ///
    /// Its `previousClose` is the close before *this range* began, not yesterday's —
    /// Yahoo moves `chartPreviousClose` with the range. Reading a day change off it was
    /// how the detail view came to label a month's decline as today's.
    let quote: StockQuote?

    /// The close the range is measured from: the line above which the period is a gain.
    let rangeBaseline: Double?

    var latestPrice: Double? { quote?.price }

    /// The highest and lowest traded prices across the range, when the bars carry them.
    var rangeHigh: ChartPoint? { points.filter(\.hasRange).max { ($0.high ?? 0) < ($1.high ?? 0) } }
    var rangeLow: ChartPoint? {
        points.filter(\.hasRange).min { ($0.low ?? .infinity) < ($1.low ?? .infinity) }
    }

    /// True when enough bars carry volume to be worth plotting.
    var hasVolume: Bool { points.contains { ($0.volume ?? 0) > 0 } }

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

    private var quotes: [String: Entry<StockQuote>] = [:]
    private var indexQuotes: [String: Entry<IndexQuote>] = [:]
    private var histories: [String: Entry<ChartSeries>] = [:]

    /// In-flight fetches, so concurrent callers for one symbol share a single request.
    private var quoteTasks: [String: Task<StockQuote, Error>] = [:]
    private var indexTasks: [String: Task<IndexQuote, Error>] = [:]
    private var historyTasks: [String: Task<ChartSeries, Error>] = [:]

    private var backoffUntil: Date?

    func quote(
        for symbol: String,
        maxAge: TimeInterval,
        fetch: @escaping @Sendable () async throws -> StockQuote
    ) async throws -> StockQuote {
        if let entry = quotes[symbol], Date().timeIntervalSince(entry.fetchedAt) < maxAge {
            return entry.value
        }

        if let stale = try rateLimitFallback(quotes[symbol]?.value) {
            return stale
        }

        if let existing = quoteTasks[symbol] {
            return try await existing.value
        }

        let task = Task { try await fetch() }
        quoteTasks[symbol] = task

        do {
            let value = try await task.value
            quoteTasks[symbol] = nil
            quotes[symbol] = Entry(value: value, fetchedAt: Date())
            return value
        } catch {
            quoteTasks[symbol] = nil
            noteFailure(error)
            // A stale quote beats no quote: the caller would otherwise see nil and
            // silently skip an alert or an order check.
            if let stale = quotes[symbol]?.value { return stale }
            throw error
        }
    }

    /// Price-only convenience, so existing callers and tests stay terse.
    func price(
        for symbol: String,
        maxAge: TimeInterval,
        fetch: @escaping @Sendable () async throws -> Double
    ) async throws -> Double {
        try await quote(for: symbol, maxAge: maxAge) {
            StockQuote(price: try await fetch())
        }.price
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
        quotes.removeAll()
        indexQuotes.removeAll()
        histories.removeAll()
        backoffUntil = nil
    }
}
