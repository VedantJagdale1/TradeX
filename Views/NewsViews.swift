//
//  NewsViews.swift
//  TradeX
//

import SwiftUI

/// One headline: who published it, when, and what it says. Opens the article in Safari.
struct HeadlineRow: View {
    let item: NewsItem

    /// Shown when the row sits in a stream covering several companies.
    var symbol: String?

    var body: some View {
        Link(destination: item.url) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let symbol {
                        Text(symbol)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Theme.accent.opacity(0.15))
                            )
                    }

                    Text(item.source)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    Text("·")
                    Text(item.published, format: .relative(presentation: .named))
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)

                // Headlines are third-party text, so they are drawn verbatim — never
                // interpreted as markdown, and never handed to the assistant as context.
                Text(verbatim: item.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the article in Safari")
    }
}


/// Where coverage came from and what was left out, stated once under each list.
private struct NewsAttribution: View {
    var body: some View {
        Text("Headlines from Google News, last two weeks. Price-prediction pieces are left out. Coverage is not a recommendation.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}


/// Recent coverage of one company, on its detail screen.
///
/// Placed below the chart and the numbers on purpose: it is there to explain a move
/// you have already seen, not to be the first thing that prompts a trade.
struct StockNewsSection: View {
    let companyName: String

    @State private var items: [NewsItem] = []
    @State private var phase: Phase = .loading
    @State private var showsAll = false

    private enum Phase { case loading, loaded, failed }

    private static let collapsedCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("In the News")
                .font(.headline)
                .padding(.bottom, 4)

            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)

            case .failed:
                Label("Couldn't load coverage right now.", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)

            case .loaded where items.isEmpty:
                Text("No coverage in the last two weeks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)

            case .loaded:
                let visible = showsAll ? items : Array(items.prefix(Self.collapsedCount))
                ForEach(visible) { item in
                    HeadlineRow(item: item)
                    if item.id != visible.last?.id { Divider() }
                }

                if items.count > Self.collapsedCount {
                    Button(showsAll ? "Show fewer" : "Show \(items.count - Self.collapsedCount) more") {
                        withAnimation(Theme.Motion.layout) { showsAll.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 6)
                }
            }

            NewsAttribution()
                .padding(.top, 8)
        }
        .card()
        .task(id: companyName) {
            do {
                items = try await NewsService.shared.headlines(forCompany: companyName)
                phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed
            }
        }
    }
}


/// Coverage of the positions you hold, as one stream.
///
/// This is the version of a news feed that fits the app: not the market at large,
/// which invites reacting to whatever is loudest, but only the companies you have
/// money in.
struct HoldingsNewsCard: View {
    /// Symbol and company name for each position, largest first.
    let holdings: [(symbol: String, companyName: String)]

    /// One request per position, so a long portfolio is limited to its biggest names.
    static let maxCompanies = 5
    private static let shownCount = 5

    @State private var stream: [(symbol: String, item: NewsItem)] = []
    @State private var isLoading = true

    private var key: String {
        holdings.prefix(Self.maxCompanies).map(\.symbol).joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Holdings in the News")
                .font(.headline)
                .padding(.bottom, 4)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if stream.isEmpty {
                Text("No recent coverage of what you hold.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(stream, id: \.item.id) { entry in
                    HeadlineRow(item: entry.item, symbol: entry.symbol)
                    if entry.item.id != stream.last?.item.id { Divider() }
                }
            }

            NewsAttribution()
                .padding(.top, 8)
        }
        .card()
        .task(id: key) { await load() }
    }

    private func load() async {
        let companies = Array(holdings.prefix(Self.maxCompanies))

        let feeds = await withTaskGroup(of: (String, [NewsItem]).self) { group in
            for company in companies {
                group.addTask {
                    // One company's failure shouldn't blank the others' coverage.
                    let items = (try? await NewsService.shared.headlines(forCompany: company.companyName)) ?? []
                    return (company.symbol, items)
                }
            }
            var collected: [String: [NewsItem]] = [:]
            for await (symbol, items) in group { collected[symbol] = items }
            return collected
        }

        guard !Task.isCancelled else { return }
        stream = NewsFeed.merge(feeds, limit: Self.shownCount)
        isLoading = false
    }
}
