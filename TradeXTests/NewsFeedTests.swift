//
//  NewsFeedTests.swift
//  TradeXTests
//

import Foundation
import Testing
@testable import TradeX

/// Shaped like a real Google News item, captured from the live feed.
private func feed(_ items: [(title: String, source: String, date: String, link: String)]) -> Data {
    let body = items.map { item in
        """
        <item><title>\(item.title) - \(item.source)</title>\
        <link>\(item.link)</link>\
        <guid isPermaLink="false">x</guid>\
        <pubDate>\(item.date)</pubDate>\
        <description>&lt;a href="\(item.link)"&gt;\(item.title)&lt;/a&gt;</description>\
        <source url="https://example.com">\(item.source)</source></item>
        """
    }.joined()
    return Data("""
    <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel>\
    <title>"Reliance Industries" share - Google News</title>\(body)</channel></rss>
    """.utf8)
}

/// Thu, 24 Sep 2026 12:00:00 GMT
private let now = Date(timeIntervalSince1970: 1_790_251_200)

private func rfc822(hoursAgo: Double) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: now.addingTimeInterval(-hoursAgo * 3_600))
}


struct NewsQueryTests {

    @Test("The legal suffix is dropped from the search phrase")
    func suffixStripped() {
        #expect(NewsFeed.searchName(forCompany: "Reliance Industries Limited") == "Reliance Industries")
        #expect(NewsFeed.searchName(forCompany: "Infosys Ltd.") == "Infosys")
        #expect(NewsFeed.searchName(forCompany: "HDFC Bank Ltd") == "HDFC Bank")
        #expect(NewsFeed.searchName(forCompany: "Tata Consultancy Services") == "Tata Consultancy Services")
    }

    @Test("A name that is only a suffix yields no search")
    func emptyName() {
        #expect(NewsFeed.searchName(forCompany: "Limited") == "")
        #expect(NewsFeed.feedURL(forCompany: "Limited") == nil)
        #expect(NewsFeed.feedURL(forCompany: "   ") == nil)
    }

    @Test("The query quotes the name and restricts to recent Indian coverage")
    func queryShape() throws {
        let url = try #require(NewsFeed.feedURL(forCompany: "Reliance Industries Limited"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let q = try #require(items.first { $0.name == "q" }?.value)

        #expect(url.scheme == "https")
        #expect(url.host == "news.google.com")
        #expect(q == "\"Reliance Industries\" share when:14d")
        #expect(items.first { $0.name == "gl" }?.value == "IN")
    }

    @Test("An ampersand in a name stays inside the search")
    func ampersandSurvives() throws {
        let url = try #require(NewsFeed.feedURL(forCompany: "Mahindra & Mahindra Limited"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        // Were the & left raw, the query would split and search for "Mahindra ".
        #expect(items.first { $0.name == "q" }?.value == "\"Mahindra & Mahindra\" share when:14d")
        #expect(items.count == 4)
    }
}


struct NewsParsingTests {

    @Test("Items are read from a real-shaped feed")
    func parsesItems() {
        let raw = NewsFeed.parse(feed([
            ("Reliance Industries down 2%, at 17-month low", "business-standard.com",
             "Thu, 24 Sep 2026 06:30:00 GMT", "https://news.google.com/rss/articles/A1?oc=5"),
            ("Reliance eyes Rs 10,000 cr debt fundraise", "The Economic Times",
             "Thu, 24 Sep 2026 09:00:00 GMT", "https://news.google.com/rss/articles/B2?oc=5")
        ]))

        #expect(raw.count == 2)
        #expect(raw[0].source == "business-standard.com")
        #expect(raw[0].link == "https://news.google.com/rss/articles/A1?oc=5")
        #expect(raw[0].title.hasSuffix(" - business-standard.com"))
    }

    @Test("The channel's own title is not mistaken for an item")
    func channelTitleIgnored() {
        let raw = NewsFeed.parse(feed([]))
        #expect(raw.isEmpty)
    }

    @Test("Garbage input yields nothing rather than crashing")
    func malformedInput() {
        #expect(NewsFeed.parse(Data("not xml at all".utf8)).isEmpty)
        #expect(NewsFeed.parse(Data()).isEmpty)
    }

    @Test("RFC 822 dates are read in their own time zone")
    func dates() throws {
        let gmt = try #require(NewsFeed.date(fromRFC822: "Thu, 24 Sep 2026 12:00:00 GMT"))
        #expect(gmt == now)
        #expect(NewsFeed.date(fromRFC822: "yesterday") == nil)
    }
}


struct NewsCurationTests {

    private func raw(_ title: String, source: String = "Livemint", hoursAgo: Double = 1,
                     link: String? = nil) -> NewsFeed.RawItem {
        NewsFeed.RawItem(
            title: "\(title) - \(source)",
            link: link ?? "https://news.google.com/rss/articles/\(abs(title.hashValue))",
            pubDate: rfc822(hoursAgo: hoursAgo),
            source: source
        )
    }

    @Test("The publisher suffix Google appends is removed")
    func titleCleaned() {
        #expect(NewsFeed.cleanTitle("Stock hits low - business-standard.com",
                                    source: "business-standard.com") == "Stock hits low")
    }

    @Test("A dash inside a real headline is left alone")
    func innerDashKept() {
        // Cutting at the last " - " would have truncated this headline.
        let title = "Q1 results - revenue up 23% - Autopunditz"
        #expect(NewsFeed.cleanTitle(title, source: "Autopunditz") == "Q1 results - revenue up 23%")
        #expect(NewsFeed.cleanTitle("Buy - or wait?", source: "Mint") == "Buy - or wait?")
    }

    @Test("Newest first, whatever order the feed used")
    func sortedByDate() {
        // The live feed put a four-hour-old story beside one from seven weeks earlier.
        let items = NewsFeed.curate([
            raw("Middle", hoursAgo: 30), raw("Newest", hoursAgo: 2), raw("Oldest", hoursAgo: 200)
        ], now: now)

        #expect(items.map(\.title) == ["Newest", "Middle", "Oldest"])
    }

    @Test("Coverage older than two weeks is dropped")
    func staleDropped() {
        let items = NewsFeed.curate([
            raw("Fresh", hoursAgo: 5), raw("Stale", hoursAgo: 24 * 15)
        ], now: now)
        #expect(items.map(\.title) == ["Fresh"])
    }

    @Test("A timestamp from the future is treated as malformed")
    func futureDropped() {
        let items = NewsFeed.curate([raw("From tomorrow", hoursAgo: -30)], now: now)
        #expect(items.isEmpty)
    }

    @Test("Price-prediction pieces are filtered out")
    func predictionBaitDropped() {
        let items = NewsFeed.curate([
            raw("Reliance Industries Share Price Prediction for Tomorrow: 16 Sep", hoursAgo: 1),
            raw("Reliance Industries down 2%, at 17-month low", hoursAgo: 2)
        ], now: now)

        #expect(items.map(\.title) == ["Reliance Industries down 2%, at 17-month low"])
    }

    @Test("The same story syndicated twice appears once")
    func duplicatesCollapsed() {
        let items = NewsFeed.curate([
            raw("IT dividend heavyweights compared: TCS, Infosys", source: "Livemint", hoursAgo: 1),
            raw("IT Dividend Heavyweights Compared — TCS, Infosys!", source: "Mint", hoursAgo: 3)
        ], now: now)

        #expect(items.count == 1)
        #expect(items.first?.source == "Livemint")   // the newer copy is kept
    }

    @Test("Only https links are kept")
    func insecureLinksDropped() {
        let items = NewsFeed.curate([
            raw("Plain http", link: "http://example.com/a"),
            raw("Script", link: "javascript:alert(1)"),
            raw("Fine", link: "https://example.com/b")
        ], now: now)

        #expect(items.map(\.title) == ["Fine"])
    }

    @Test("Items without a readable date are dropped")
    func undatedDropped() {
        var item = raw("No date")
        item.pubDate = "sometime"
        #expect(NewsFeed.curate([item], now: now).isEmpty)
    }

    @Test("The result is capped")
    func limited() {
        let many = (0..<30).map { raw("Story \($0)", hoursAgo: Double($0)) }
        #expect(NewsFeed.curate(many, now: now, limit: 5).count == 5)
    }

    @Test("The whole pipeline turns a real-shaped feed into clean headlines")
    func endToEnd() {
        let items = NewsFeed.curate(NewsFeed.parse(feed([
            ("Reliance Industries down 2%, at 17-month low", "business-standard.com",
             rfc822(hoursAgo: 11), "https://news.google.com/rss/articles/A1"),
            ("Reliance Industries Share Price Prediction for Tomorrow", "Univest",
             rfc822(hoursAgo: 2), "https://news.google.com/rss/articles/B2"),
            ("Reliance eyes Rs 10,000 cr debt fundraise", "The Economic Times",
             rfc822(hoursAgo: 4), "https://news.google.com/rss/articles/C3")
        ])), now: now)

        #expect(items.map(\.title) == [
            "Reliance eyes Rs 10,000 cr debt fundraise",
            "Reliance Industries down 2%, at 17-month low"
        ])
        #expect(items.map(\.source) == ["The Economic Times", "business-standard.com"])
    }
}


struct NewsMergeTests {

    private func item(_ title: String, hoursAgo: Double) -> NewsItem {
        NewsItem(title: title, source: "Mint",
                 published: now.addingTimeInterval(-hoursAgo * 3_600),
                 url: URL(string: "https://example.com/\(abs(title.hashValue))")!)
    }

    @Test("Holdings' coverage interleaves by time, each tagged with its symbol")
    func interleaves() {
        let merged = NewsFeed.merge([
            "RELIANCE": [item("R new", hoursAgo: 1), item("R old", hoursAgo: 10)],
            "INFY": [item("I mid", hoursAgo: 5)]
        ], limit: 10)

        #expect(merged.map(\.item.title) == ["R new", "I mid", "R old"])
        #expect(merged.map(\.symbol) == ["RELIANCE", "INFY", "RELIANCE"])
    }

    @Test("A story covering two holdings is shown once")
    func sharedStoryOnce() {
        let merged = NewsFeed.merge([
            "TCS": [item("IT stocks slide on US visa news", hoursAgo: 2)],
            "INFY": [item("IT stocks slide on US visa news", hoursAgo: 2)]
        ], limit: 10)
        #expect(merged.count == 1)
    }

    @Test("The merged stream is capped")
    func capped() {
        let merged = NewsFeed.merge([
            "A": (0..<10).map { item("A\($0)", hoursAgo: Double($0)) },
            "B": (0..<10).map { item("B\($0)", hoursAgo: Double($0) + 0.5) }
        ], limit: 6)
        #expect(merged.count == 6)
    }
}
