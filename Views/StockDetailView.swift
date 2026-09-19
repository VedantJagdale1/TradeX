//
//  StockDetailView.swift
//  TradeX
//
//  Created by vedant jagdale on 04/07/26.
//

import SwiftUI
import SwiftData
import Charts

struct StockDetailView: View {
    let stock: NSEStock

    @Environment(\.modelContext) private var modelContext

    @Query private var settings: [UserSettings]
    @State private var orderTicket: OrderTicket?

    /// The point under the user's finger while scrubbing, or nil when not scrubbing.
    @State private var scrubbed: ChartPoint?
    @State private var showingNewAlert = false

    @Query private var watchlist: [WatchlistItem]

    private var isWatched: Bool {
        watchlist.contains { $0.symbol == stock.symbol }
    }

    @State private var chartData: [ChartPoint] = []
    @State private var currentPrice: Double = 0.0
    @State private var selectedRange = "1mo"
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var quote: StockQuote?

    let ranges = ["1d", "5d", "1mo", "6mo", "1y"]

    /// Human label for the window the change below the price is measured over.
    private var rangeCaption: String {
        switch selectedRange {
        case "1d": return "Today"
        case "5d": return "Past 5 days"
        case "1mo": return "Past month"
        case "6mo": return "Past 6 months"
        case "1y": return "Past year"
        default: return ""
        }
    }

    var priceChange: Double {
        guard let firstPrice = chartData.first?.price else { return 0.0 }
        return currentPrice - firstPrice
    }

    var priceChangePercentage: Double {
        guard let firstPrice = chartData.first?.price, firstPrice > 0 else { return 0.0 }
        return (priceChange / firstPrice) * 100
    }

    var isPositive: Bool { priceChange >= 0 }

    /// The y-axis window. Also supplies the area fill's floor — an `AreaMark` created with
    /// `y:` alone fills down to zero, which sits far outside this domain and spills the
    /// gradient past the chart's frame and over the rest of the screen.
    private var priceDomain: ClosedRange<Double> {
        let prices = chartData.map(\.price)
        let low = (prices.min() ?? 0) * 0.99
        let high = (prices.max() ?? 100) * 1.01
        guard low < high else { return low...(low + 1) }
        return low...high
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stock.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    MoneyText(amount: scrubbed?.price ?? currentPrice, font: Theme.Typography.hero)

                    if let scrubbed {
                        // While scrubbing, the change line gives way to the timestamp of
                        // the point being inspected.
                        Text(scrubbed.date.formatted(
                            date: .abbreviated,
                            time: selectedRange == "1d" ? .shortened : .omitted
                        ))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.left")
                                Text("\(isPositive ? "+" : "")₹\(abs(priceChange), specifier: "%.2f") (\(String(format: "%.2f", priceChangePercentage))%)")
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(isPositive ? Theme.profit : Theme.loss)

                            Text(rangeCaption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)

                Picker("Range", selection: $selectedRange) {
                    ForEach(ranges, id: \.self) { range in
                        Text(range.uppercased()).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                ZStack {
                    if isLoading {
                        ProgressView()
                            .frame(height: 220)
                    } else if !chartData.isEmpty {
                        Chart {
                            ForEach(chartData) { point in
                                // Area first so the line draws on top of it.
                                AreaMark(
                                    x: .value("Time", point.date),
                                    yStart: .value("Low", priceDomain.lowerBound),
                                    yEnd: .value("Price", point.price)
                                )
                                .foregroundStyle(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            isPositive ? Theme.profit.opacity(0.25) : Theme.loss.opacity(0.25),
                                            Color.clear
                                        ]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .interpolationMethod(.catmullRom)

                                LineMark(
                                    x: .value("Time", point.date),
                                    y: .value("Price", point.price)
                                )
                                .foregroundStyle(isPositive ? Theme.profit : Theme.loss)
                                .interpolationMethod(.catmullRom)
                            }

                            if let scrubbed {
                                RuleMark(x: .value("Time", scrubbed.date))
                                    .foregroundStyle(Color.secondary.opacity(0.5))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                                PointMark(
                                    x: .value("Time", scrubbed.date),
                                    y: .value("Price", scrubbed.price)
                                )
                                .foregroundStyle(isPositive ? Theme.profit : Theme.loss)
                                .symbolSize(120)
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartYScale(domain: priceDomain)
                        .frame(height: 220)
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                Rectangle()
                                    .fill(.clear)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { drag in
                                                updateScrub(at: drag.location, proxy: proxy, geometry: geometry)
                                            }
                                            .onEnded { _ in scrubbed = nil }
                                    )
                            }
                        }
                        .padding(.horizontal)
                    } else {
                        chartUnavailableView
                            .frame(height: 220)
                    }
                }

                Button {
                    orderTicket = .buy(
                        symbol: stock.symbol,
                        companyName: stock.name,
                        price: currentPrice,
                        availableCash: PortfolioManager.shared.freeCash(in: modelContext),
                        costs: PortfolioManager.shared.settings(in: modelContext).costSchedule
                    )
                } label: {
                    Label("Buy \(stock.symbol)", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.profit)
                .disabled(currentPrice <= 0)
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Key Metrics")
                        .font(.headline)
                        .padding(.horizontal)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        if let change = quote?.dayChangePercent {
                            metricTile(
                                title: "Today",
                                value: String(format: "%@%.2f%%", Theme.sign(change), change),
                                tint: Theme.pnl(change)
                            )
                        }
                        if let high = quote?.dayHigh, let low = quote?.dayLow {
                            metricTile(title: "Day Range",
                                       value: "\(CurrencyFormatter.rupees(low)) – \(CurrencyFormatter.rupees(high))")
                        }
                        if let high = quote?.fiftyTwoWeekHigh, let low = quote?.fiftyTwoWeekLow {
                            metricTile(title: "52-Week Range",
                                       value: "\(CurrencyFormatter.rupees(low)) – \(CurrencyFormatter.rupees(high))")
                        }
                        if let volume = quote?.volume {
                            metricTile(title: "Volume", value: Self.compactVolume.string(from: NSNumber(value: volume)) ?? "\(volume)")
                        }
                        metricTile(title: "Sector", value: Sector.forSymbol(stock.symbol).rawValue)
                        metricTile(title: "ISIN", value: stock.isin.isEmpty ? "N/A" : stock.isin)
                    }
                    .padding(.horizontal)

                    // Where today sits between the yearly extremes — the one number that
                    // says whether a price is high or low without needing a chart.
                    if let position = quote?.positionInYearRange,
                       let high = quote?.fiftyTwoWeekHigh, let low = quote?.fiftyTwoWeekLow {
                        VStack(alignment: .leading, spacing: 6) {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.2))
                                    Circle()
                                        .fill(Theme.accent)
                                        .frame(width: 10, height: 10)
                                        .offset(x: max(0, geometry.size.width * position - 5))
                                }
                            }
                            .frame(height: 10)

                            HStack {
                                Text(CurrencyFormatter.rupees(low))
                                Spacer()
                                Text("\(position * 100, specifier: "%.0f")% of 52-week range")
                                Spacer()
                                Text(CurrencyFormatter.rupees(high))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(stock.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewAlert = true
                } label: {
                    Image(systemName: "bell")
                }
                .accessibilityLabel("Set a price alert")
                .disabled(currentPrice <= 0)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Watchlist.toggle(
                        symbol: stock.symbol,
                        companyName: stock.name,
                        in: modelContext
                    )
                } label: {
                    Image(systemName: isWatched ? "star.fill" : "star")
                        .foregroundStyle(isWatched ? Theme.caution : Theme.accent)
                }
                .accessibilityLabel(isWatched ? "Remove from watchlist" : "Add to watchlist")
                .sensoryFeedback(.selection, trigger: isWatched)
            }
        }
        // Keyed on the range so switching cancels the in-flight load. Without that, a slow
        // response for one range could land after a faster one and show the wrong series.
        .sensoryFeedback(.selection, trigger: scrubbed?.id)
        .task(id: selectedRange) {
            await loadTimelineMetrics()
        }
        .sheet(isPresented: $showingNewAlert) {
            NewAlertSheet(
                symbol: stock.symbol,
                companyName: stock.name,
                currentPrice: currentPrice
            )
        }
        .sheet(item: $orderTicket) { ticket in
            OrderTicketView(ticket: ticket) { request in
                await placeBuy(request)
            }
        }
    }
}

private extension StockDetailView {

    /// Maps a touch position to the nearest point in the series.
    func updateScrub(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let xInPlot = location.x - geometry[plotFrame].origin.x

        guard let touchedDate: Date = proxy.value(atX: xInPlot),
              let nearest = chartData.min(by: {
                  abs($0.date.timeIntervalSince(touchedDate)) < abs($1.date.timeIntervalSince(touchedDate))
              })
        else { return }

        if nearest.id != scrubbed?.id {
            scrubbed = nearest
        }
    }

    /// Returns a message on failure, nil on success — the ticket renders it inline.
    func placeBuy(_ request: OrderRequest) async -> String? {
        if let limitPrice = request.limitPrice {
            let failure = await LimitOrderService.submit(
                symbol: stock.symbol,
                companyName: stock.name,
                isBuy: true,
                quantity: request.quantity,
                limitPrice: limitPrice,
                marketPrice: currentPrice,
                kind: request.kind,
                trailPercent: request.trailPercent,
                thesis: request.thesis,
                timeInForce: request.timeInForce,
                holding: nil,
                modelContext: modelContext
            )
            if failure == nil { await PriceAlertService.requestAuthorization() }
            return failure
        }

        do {
            try await PortfolioManager.shared.addStock(
                symbol: stock.symbol,
                companyName: stock.name,
                quantity: request.quantity,
                buyPrice: currentPrice,
                thesis: request.thesis,
                modelContext: modelContext
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @ViewBuilder
    var chartUnavailableView: some View {
        if loadFailed {
            ContentUnavailableView {
                Label("Couldn't Load Chart", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Retry") {
                    Task { await loadTimelineMetrics() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "No Chart Data",
                systemImage: "chart.line.flurry",
                description: Text("This stock has no price history for the selected range.")
            )
        }
    }

    func loadTimelineMetrics() async {
        isLoading = true
        loadFailed = false

        do {
            let series = try await MarketAPIService.shared.fetchHistoricalData(
                symbol: stock.symbol,
                range: selectedRange
            )

            guard !Task.isCancelled else { return }

            chartData = series.points
            quote = series.quote
            if let price = series.displayPrice {
                currentPrice = price
            }
        } catch {
            guard !Task.isCancelled else { return }
            print("Failed compiling chart timeline points: \(error)")
            chartData = []
            loadFailed = true
        }

        isLoading = false
    }

    static let compactVolume: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    func metricTile(title: String, value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
