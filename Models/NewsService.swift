//
//  NewsService.swift
//  TradeX
//

import Foundation

/// One headline, cleaned up for display.
struct NewsItem: Identifiable, Sendable, Equatable {
    let title: String
    let source: String
    let published: Date
    let url: URL

    var id: URL { url }
}


/// Finds, parses and curates coverage of a listed company.
///
/// Sourced from Google News search RSS. Yahoo was tried first and is unusable for the
/// NSE: it returns nothing for `.NS` tickers, and searching "RELIANCE" returns American
/// companies — Reliance Steel, among others — which is worse than returning nothing.
/// Neither is a licensed feed; like the price data, this can change without notice and
/// is fit for a personal app, not a published one.
nonisolated enum NewsFeed {

    /// How far back coverage is still worth reading next to a live price.
    static let maxAgeDays = 14

    // MARK: Query

    /// Words that only make a search noisier. "Reliance Industries Limited" in quotes
    /// misses every article that says "Reliance Industries", which is nearly all of them.
    private static let corporateSuffixes: Set<String> = ["limited", "ltd", "ltd.", "ltd,"]

    /// The phrase to search for: the company's name without its legal suffix.
    static func searchName(forCompany name: String) -> String {
        var words = name.split(separator: " ").map(String.init)
        while let last = words.last, corporateSuffixes.contains(last.lowercased()) {
            words.removeLast()
        }
        return words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// The feed for a company, restricted to recent Indian coverage.
    ///
    /// The name is quoted and paired with "share", which in testing kept 86–98% of
    /// results about the company rather than merely mentioning it.
    static func feedURL(forCompany name: String) -> URL? {
        let phrase = searchName(forCompany: name)
        guard !phrase.isEmpty else { return nil }

        var components = URLComponents(string: "https://news.google.com/rss/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "\"\(phrase)\" share when:\(maxAgeDays)d"),
            URLQueryItem(name: "hl", value: "en-IN"),
            URLQueryItem(name: "gl", value: "IN"),
            URLQueryItem(name: "ceid", value: "IN:en")
        ]
        return components?.url
    }

    // MARK: Parsing

    /// An `<item>` as it arrives, before any curation.
    struct RawItem: Equatable {
        var title = ""
        var link = ""
        var pubDate = ""
        var source = ""
    }

    static func parse(_ data: Data) -> [RawItem] {
        let delegate = RSSItemCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        // A truncated feed still yields the items read before the break.
        return delegate.items
    }

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func date(fromRFC822 string: String) -> Date? {
        rfc822.date(from: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Curation

    /// Google appends the publisher to every title — "… at 17-month low - business-
    /// standard.com" — and shows the publisher separately as well.
    static func cleanTitle(_ title: String, source: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = " - \(source)"
        // Only the exact publisher suffix is removed. Titles legitimately contain
        // " - ", and cutting at the last one would truncate real headlines.
        guard !source.isEmpty, trimmed.hasSuffix(suffix) else { return trimmed }
        return String(trimmed.dropLast(suffix.count))
    }

    /// Price-prediction pieces are not news. "Share Price Prediction for Tomorrow"
    /// made up about one result in ten, and it is the kind of item that prompts a
    /// trade rather than explaining one.
    static func isPredictionBait(_ title: String) -> Bool {
        title.lowercased().contains("prediction")
    }

    /// For spotting the same story syndicated under slightly different punctuation.
    static func fingerprint(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// Turns raw feed items into what is worth showing: newest first, recent, secure,
    /// de-duplicated, and without prediction bait.
    ///
    /// Sorting matters more than it sounds — the feed arrives in relevance order, and
    /// in testing a four-hour-old story sat beside one from seven weeks earlier.
    static func curate(_ raw: [RawItem], now: Date = Date(), limit: Int = 20) -> [NewsItem] {
        let oldest = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)

        let candidates: [NewsItem] = raw.compactMap { item in
            guard let url = URL(string: item.link.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme == "https",
                  let published = date(fromRFC822: item.pubDate),
                  published >= oldest,
                  // A timestamp from the future is a malformed item, not breaking news.
                  published <= now.addingTimeInterval(3_600)
            else { return nil }

            let title = cleanTitle(item.title, source: item.source)
            guard !title.isEmpty, !isPredictionBait(title) else { return nil }

            return NewsItem(
                title: title,
                source: item.source.isEmpty ? (url.host ?? "") : item.source,
                published: published,
                url: url
            )
        }

        var seen = Set<String>()
        return candidates
            .sorted { $0.published > $1.published }
            .filter { seen.insert(fingerprint($0.title)).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Several companies' coverage as one stream, each item kept with its symbol.
    static func merge(_ feeds: [String: [NewsItem]], limit: Int) -> [(symbol: String, item: NewsItem)] {
        var seen = Set<String>()
        return feeds
            .flatMap { symbol, items in items.map { (symbol: symbol, item: $0) } }
            .sorted { $0.item.published > $1.item.published }
            // The same story often covers two holdings — a sector move, a merger —
            // and showing it twice reads as two separate events.
            .filter { seen.insert(fingerprint($0.item.title)).inserted }
            .prefix(limit)
            .map { $0 }
    }
}


/// Collects `<item>` elements from an RSS document.
nonisolated private final class RSSItemCollector: NSObject, XMLParserDelegate {
    var items: [NewsFeed.RawItem] = []

    private var current: NewsFeed.RawItem?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "item" { current = NewsFeed.RawItem() }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "title": current?.title = value
        case "link": current?.link = value
        case "pubDate": current?.pubDate = value
        case "source": current?.source = value
        case "item":
            if let current { items.append(current) }
            current = nil
        default: break
        }
        text = ""
    }
}


/// Fetches coverage with its own cache and its own back-off.
///
/// Kept apart from QuoteCache on purpose: news comes from a different host with
/// different limits, and a refusal from Google must never stall price quotes from
/// Yahoo — or the other way round.
actor NewsService {
    static let shared = NewsService()

    /// Coverage moves in hours, not seconds.
    static let maxAge: TimeInterval = 15 * 60

    private var cache: [String: (items: [NewsItem], fetchedAt: Date)] = [:]
    private var inFlight: [String: Task<[NewsItem], Error>] = [:]

    func headlines(forCompany name: String) async throws -> [NewsItem] {
        let key = NewsFeed.searchName(forCompany: name).lowercased()

        if let entry = cache[key], Date().timeIntervalSince(entry.fetchedAt) < Self.maxAge {
            return entry.items
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task { try await Self.fetch(company: name) }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let items = try await task.value
            cache[key] = (items, Date())
            return items
        } catch {
            // Yesterday's headlines are still better than an error where they were.
            if let stale = cache[key]?.items { return stale }
            throw error
        }
    }

    private static func fetch(company: String) async throws -> [NewsItem] {
        guard let url = NewsFeed.feedURL(forCompany: company) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.noData }
        if http.statusCode == 429 { throw NetworkError.rateLimited }
        guard http.statusCode == 200 else { throw NetworkError.noData }

        return NewsFeed.curate(NewsFeed.parse(data))
    }
}
