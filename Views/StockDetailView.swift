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

    /// The day quote, fetched on its own at a one-day range.
    ///
    /// It used to be taken from whichever range the chart was showing, but Yahoo moves
    /// `chartPreviousClose` with the range — so on the 1MO tab "Today" was reporting
    /// the month's move, sign and all.
    @State private var quote: StockQuote?

    /// The close this range is measured from, and what the chart is coloured against.
    @State private var rangeBaseline: Double?

    @State private var chartStyle: ChartStyle = .line
    @State private var showsVolume = true

    /// Measured, because bar widths have to be given in points.
    ///
    /// `.ratio` sizes a bar against an inferred category step, which a continuous date
    /// axis does not provide — the bars collapse to nothing and the volume strip renders
    /// empty. Seeded at roughly a phone's plot width so the first frame is not blank.
    @State private var plotWidth: CGFloat = 320

    enum ChartStyle: String, CaseIterable, Identifiable {
        case line, candle
        var id: String { rawValue }
        var symbol: String { self == .line ? "chart.xyaxis.line" : "chart.bar.fill" }
    }

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
    /// The band the price itself occupies — the area fill's floor, and the ceiling
    /// the volume bars stop at.
    private var priceBand: ClosedRange<Double> {
        // Candles are drawn to their wicks, so a band built from closes alone would
        // clip them. The baseline is included too, or the reference line can fall
        // outside the plot and simply not appear.
        var lows = chartData.map { $0.low ?? $0.price }
        var highs = chartData.map { $0.high ?? $0.price }
        if let rangeBaseline {
            lows.append(rangeBaseline)
            highs.append(rangeBaseline)
        }

        let low = (lows.min() ?? 0) * 0.99
        let high = (highs.max() ?? 100) * 1.01
        guard low < high else { return low...(low + 1) }
        return low...high
    }

    /// The whole plot: the price band, plus the strip below it given over to volume.
    ///
    /// The two are kept apart deliberately. Filling the area down to the chart's floor
    /// instead of the price band's painted the gradient straight over the volume bars
    /// and hid them completely.
    private var priceDomain: ClosedRange<Double> {
        let band = priceBand
        guard plotsVolume else { return band }
        let floor = band.lowerBound - (band.upperBound - band.lowerBound) * Self.volumeBandShare
        return floor...band.upperBound
    }

    /// The share of the plot height given over to volume bars.
    private static let volumeBandShare = 0.22

    private var plotsVolume: Bool {
        showsVolume && chartData.contains { ($0.volume ?? 0) > 0 }
    }

    private var maxVolume: Double {
        Double(chartData.compactMap(\.volume).max() ?? 0)
    }

    /// One bar's share of the plot, leaving a gap between neighbours.
    private func barWidth(_ fill: CGFloat) -> MarkDimension {
        .fixed(max(1, plotWidth / CGFloat(max(chartData.count, 1)) * fill))
    }

    /// Maps a bar's volume into the strip reserved for it, so the busiest bar reaches
    /// exactly the foot of the price band and none of them intrude on it.
    private func volumeHeight(_ volume: Int?) -> Double {
        let floor = priceDomain.lowerBound
        guard plotsVolume, maxVolume > 0, let volume, volume > 0 else { return floor }
        return floor + (priceBand.lowerBound - floor) * (Double(volume) / maxVolume)
    }

    /// Where this position was bought, when it is held — the line that turns an
    /// abstract price chart into "am I up on this".
    private var averageCost: Double? {
        let holdings = (try? modelContext.fetch(FetchDescriptor<PortfolioHolding>())) ?? []
        return holdings.first { $0.symbol == stock.symbol }?.avgBuyPrice
    }

    /// Date formatting that suits the window on screen.
    private var axisFormat: Date.FormatStyle {
        switch selectedRange {
        case "1d": return .dateTime.hour().minute()
        case "5d": return .dateTime.weekday(.abbreviated)
        case "1mo": return .dateTime.day().month(.abbreviated)
        default: return .dateTime.month(.abbreviated)
        }
    }

    /// Change from the point being scrubbed back to the start of the range.
    private var scrubbedChange: (amount: Double, percent: Double)? {
        guard let scrubbed, let first = chartData.first?.price, first > 0 else { return nil }
        let amount = scrubbed.price - first
        return (amount, amount / first * 100)
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
                        // While scrubbing, the change line gives way to the moment being
                        // inspected and how far it sits from the start of the range.
                        HStack(spacing: 6) {
                            if let move = scrubbedChange {
                                Text("\(Theme.sign(move.amount))₹\(abs(move.amount), specifier: "%.2f") (\(String(format: "%.2f", move.percent))%)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Theme.pnl(move.amount))
                            }

                            Text(scrubbed.date.formatted(
                                date: .abbreviated,
                                time: selectedRange == "1d" ? .shortened : .omitted
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
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

                HStack(spacing: 12) {
                    Picker("Range", selection: $selectedRange) {
                        ForEach(ranges, id: \.self) { range in
                            Text(range.uppercased()).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)

                    Menu {
                        Picker("Style", selection: $chartStyle) {
                            Label("Line", systemImage: "chart.xyaxis.line").tag(ChartStyle.line)
                            Label("Candles", systemImage: "chart.bar.fill").tag(ChartStyle.candle)
                        }
                        Toggle("Volume", isOn: $showsVolume)
                    } label: {
                        Image(systemName: chartStyle.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                    .fill(Color.secondary.opacity(0.15))
                            )
                    }
                }
                .padding(.horizontal)

                ZStack {
                    if isLoading {
                        ProgressView()
                            .frame(height: 220)
                    } else if !chartData.isEmpty {
                        priceChart
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

    /// The price chart: line or candles, with volume along the foot, the range's
    /// baseline, and your own entry when you hold the stock.
    var priceChart: some View {
        Chart {
            if plotsVolume {
                ForEach(chartData) { point in
                    BarMark(
                        x: .value("Time", point.date),
                        yStart: .value("Base", priceDomain.lowerBound),
                        yEnd: .value("Volume", volumeHeight(point.volume)),
                        width: barWidth(0.55)
                    )
                    .foregroundStyle((point.isUp ? Theme.profit : Theme.loss).opacity(0.22))
                }
            }

            // The close the range is measured from. Above it the period is a gain,
            // which is otherwise something you have to infer from the shape.
            if let rangeBaseline {
                RuleMark(y: .value("Previous close", rangeBaseline))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            if let averageCost, priceDomain.contains(averageCost) {
                RuleMark(y: .value("Your cost", averageCost))
                    .foregroundStyle(Theme.accent.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Your cost")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
            }

            switch chartStyle {
            case .line:
                ForEach(chartData) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Low", priceBand.lowerBound),
                        yEnd: .value("Price", point.price)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [(isPositive ? Theme.profit : Theme.loss).opacity(0.22), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Price", point.price)
                    )
                    .foregroundStyle(isPositive ? Theme.profit : Theme.loss)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

            case .candle:
                ForEach(chartData) { point in
                    if let high = point.high, let low = point.low {
                        RuleMark(
                            x: .value("Time", point.date),
                            yStart: .value("Low", low),
                            yEnd: .value("High", high)
                        )
                        .foregroundStyle(point.isUp ? Theme.profit : Theme.loss)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    }

                    if let open = point.open {
                        // A doji closes where it opened, which as a rectangle would be
                        // invisible; the floor gives it a body thin enough to read as flat.
                        let span = abs(point.price - open)
                        let pad = max(span, (priceDomain.upperBound - priceDomain.lowerBound) * 0.002) / 2
                        let mid = (point.price + open) / 2

                        RectangleMark(
                            x: .value("Time", point.date),
                            yStart: .value("Open", mid - pad),
                            yEnd: .value("Close", mid + pad),
                            width: barWidth(0.65)
                        )
                        .foregroundStyle(point.isUp ? Theme.profit : Theme.loss)
                    }
                }
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
                .symbolSize(110)
            }
        }
        .chartYScale(domain: priceDomain)
        .chartXAxis {
            // Dates were hidden entirely before, which left a month of trading with no
            // way to tell when anything happened.
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: axisFormat)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel {
                    if let price = value.as(Double.self) {
                        // The volume strip sits below every real price, so its ticks
                        // would otherwise label the chart with prices never traded.
                        if price >= priceBand.lowerBound {
                            Text(price, format: .number.precision(.fractionLength(0)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(height: 260)
        .chartPlotStyle { plot in
            plot.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
        }
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
            rangeBaseline = series.rangeBaseline
            if let price = series.displayPrice {
                currentPrice = price
            }

            // Key Metrics describe *today*, so they come from a one-day quote of their
            // own rather than from whichever range the chart happens to be showing.
            // This request is cached, so flicking between ranges does not re-fetch it.
            quote = try? await MarketAPIService.shared.fetchQuote(symbol: stock.symbol)
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
