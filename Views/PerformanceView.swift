//
//  PerformanceView.swift
//  TradeX
//

import SwiftUI
import SwiftData
import Charts

/// A point on one of the two growth curves, rebased so a lakh-sized portfolio and a
/// five-figure index level can share an axis.
struct GrowthPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    let series: String
}

/// One day on which both curves have a value, which is what shading between them and
/// reading a figure off them both require.
struct PairedGrowth: Identifiable, Equatable {
    let date: Date
    let mine: Double
    let index: Double

    var id: Date { date }
    var gap: Double { mine - index }
    var isAhead: Bool { mine >= index }
}

enum PerformanceMath {

    /// Lines up the two curves by calendar day.
    ///
    /// A day present in only one series is dropped: the gap between the lines is
    /// undefined there, and inventing a value would shade a lead or a lag that was
    /// never measured.
    static func pair(portfolio: [GrowthPoint], benchmark: [GrowthPoint]) -> [PairedGrowth] {
        let calendar = Calendar.current
        let benchmarkByDay = Dictionary(
            benchmark.map { (calendar.startOfDay(for: $0.date), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )

        return portfolio.compactMap { point in
            benchmarkByDay[calendar.startOfDay(for: point.date)].map {
                PairedGrowth(date: point.date, mine: point.value, index: $0)
            }
        }
    }

    /// The measured day closest to where the finger is, since a scrub lands between them.
    static func nearest(to date: Date, in pairs: [PairedGrowth]) -> PairedGrowth? {
        pairs.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }
    static let portfolioSeries = "Your Portfolio"
    static let benchmarkSeries = "NIFTY 50"
    static let base = 100.0

    /// Time-weighted return, rebased to 100.
    ///
    /// Each period's growth removes the cash that flowed in or out during it, so paying
    /// money into the account can't be mistaken for making money. This is what makes the
    /// comparison against a passive index honest.
    static func portfolioGrowth(from snapshots: [PortfolioSnapshot]) -> [GrowthPoint] {
        guard snapshots.count >= 2 else { return [] }

        var points = [GrowthPoint(date: snapshots[0].day, value: base, series: portfolioSeries)]
        var cumulative = 1.0

        for index in 1..<snapshots.count {
            let previous = snapshots[index - 1]
            let current = snapshots[index]

            // External cash added (or removed) between the two marks.
            let flow = current.netDeposits - previous.netDeposits

            if previous.netWorth > 0 {
                cumulative *= (current.netWorth - flow) / previous.netWorth
            }

            points.append(
                GrowthPoint(date: current.day, value: cumulative * base, series: portfolioSeries)
            )
        }

        return points
    }

    /// The benchmark over the same days, rebased to the same starting value.
    static func benchmarkGrowth(from snapshots: [PortfolioSnapshot]) -> [GrowthPoint] {
        let levels = snapshots.compactMap { snapshot in
            snapshot.niftyLevel.map { (day: snapshot.day, level: $0) }
        }

        guard let start = levels.first?.level, start > 0, levels.count >= 2 else { return [] }

        return levels.map {
            GrowthPoint(date: $0.day, value: ($0.level / start) * base, series: benchmarkSeries)
        }
    }
}

struct PerformanceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PortfolioSnapshot.day) private var snapshots: [PortfolioSnapshot]
    @Query private var trades: [Trade]

    private var stats: TradingStats {
        TradingStats.make(
            closed: TradingStats.closedTrades(from: trades.map(LedgerTrade.init)),
            equityCurve: portfolioPoints.map(\.value)
        )
    }

    @State private var isRebuilding = false
    @State private var rebuildNotice: String?

    /// There is only a past to rebuild if a trade predates today. Offering the button
    /// for an account whose first trade is today promises something it cannot deliver.
    private var canRebuild: Bool {
        guard let earliest = trades.map(\.timestamp).min() else { return false }
        return earliest < Calendar.current.startOfDay(for: Date())
    }

    /// The day under the finger while scrubbing the growth chart.
    @State private var scrubbedDay: Date?

    private var portfolioPoints: [GrowthPoint] { PerformanceMath.portfolioGrowth(from: snapshots) }
    private var benchmarkPoints: [GrowthPoint] { PerformanceMath.benchmarkGrowth(from: snapshots) }

    /// Growth expressed as a percentage move from the rebased start.
    private var portfolioReturn: Double { (portfolioPoints.last?.value ?? PerformanceMath.base) - PerformanceMath.base }
    private var benchmarkReturn: Double { (benchmarkPoints.last?.value ?? PerformanceMath.base) - PerformanceMath.base }
    private var isBeatingBenchmark: Bool { portfolioReturn >= benchmarkReturn }

    /// Fits the axis to the two curves.
    ///
    /// Both series are rebased to 100 and typically move a couple of percent, so an axis
    /// anchored at zero squashes the whole comparison into a flat smear along the top.
    private var growthDomain: ClosedRange<Double> {
        let values = (portfolioPoints + benchmarkPoints).map(\.value)
        guard let low = values.min(), let high = values.max() else {
            return (PerformanceMath.base - 5)...(PerformanceMath.base + 5)
        }
        // Keep the 100 baseline in frame so above/below stays readable.
        let lower = min(low, PerformanceMath.base)
        let upper = max(high, PerformanceMath.base)
        let padding = max((upper - lower) * 0.18, 0.4)
        return (lower - padding)...(upper + padding)
    }

    var body: some View {
        Group {
            if portfolioPoints.count >= 2 {
                ScrollView {
                    VStack(spacing: 20) {
                        summaryCard
                        growthChart
                        riskCard
                        if !trades.isEmpty { costCard }
                        verdictCard
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView {
                    Label("Not Enough History Yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text(canRebuild
                         ? "Your account is marked once a day — but your trades already say what you held and when, so the past can be rebuilt from them."
                         : "Your account is marked once a day. Open TradeX again tomorrow and your performance will start plotting against the NIFTY 50.")
                } actions: {
                    if canRebuild {
                        Button {
                            Task { await rebuild() }
                        } label: {
                            if isRebuilding {
                                ProgressView()
                            } else {
                                Text("Rebuild From Trade History")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRebuilding)

                        if let rebuildNotice {
                            Text(rebuildNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
        }
        .navigationTitle("Performance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isRebuilding {
                    ProgressView()
                } else if canRebuild {
                    Button {
                        Task { await rebuild() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Rebuild from trade history")
                }
            }
        }
    }
}


private extension PerformanceView {

    /// Fills in the days before snapshots started being taken.
    func rebuild() async {
        isRebuilding = true
        rebuildNotice = nil
        defer { isRebuilding = false }

        do {
            let added = try await PerformanceReconstructor.rebuild(modelContext: modelContext)
            if added == 0 {
                rebuildNotice = "Already up to date — every trading day since your first trade is recorded."
            }
        } catch {
            rebuildNotice = error.localizedDescription
        }
    }

    /// How the return was earned, as opposed to how large it was.
    /// Everything paid to trade, and what share of the gains it took.
    var chargesPaid: Double { trades.reduce(0) { $0 + $1.charges } }

    /// Gross profit on winning trades — the pool the charges came out of.
    var grossWins: Double {
        trades.compactMap(\.realizedPnL).filter { $0 > 0 }.reduce(0, +)
    }

    var costCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The Cost of Trading")
                .font(.headline)

            HStack(alignment: .top) {
                statTile(title: "Charges Paid",
                         value: CurrencyFormatter.rupees(chargesPaid), tint: Theme.caution)
                Spacer()
                statTile(
                    title: "Per Trade",
                    value: trades.isEmpty ? "—"
                        : CurrencyFormatter.rupees(chargesPaid / Double(trades.count)),
                    tint: .primary
                )
                Spacer()
                statTile(title: "Trades", value: "\(trades.count)", tint: .primary)
            }

            // Charges as a share of what the winners made is the number that changes
            // behaviour — it turns an abstract fee into a bite out of the good trades.
            if grossWins > 0 {
                let bite = chargesPaid / grossWins * 100
                Text(String(
                    format: "Charges have taken %.1f%% of everything your winning trades made. %@",
                    bite,
                    bite > 25
                        ? "Fewer, larger trades would keep more of it."
                        : "Comfortably covered by the wins."
                ))
                .font(.caption2)
                .foregroundStyle(bite > 25 ? Theme.caution : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("STT, stamp duty, exchange and SEBI fees, GST and depository charges, applied to every trade. The flat depository fee makes small sells expensive out of all proportion.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    var riskCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Risk & Discipline")
                .font(.headline)

            HStack(alignment: .top) {
                statTile(
                    title: "Max Drawdown",
                    value: String(format: "-%.2f%%", stats.maxDrawdown),
                    tint: stats.maxDrawdown > 0 ? Theme.loss : .primary
                )
                Spacer()
                statTile(
                    title: "Expectancy",
                    value: stats.closedCount == 0 ? "—"
                        : "\(Theme.sign(stats.expectancy))\(CurrencyFormatter.rupees(stats.expectancy))",
                    tint: stats.closedCount == 0 ? .primary : Theme.pnl(stats.expectancy)
                )
            }

            Text("The deepest fall from a high, and what an average trade is worth. A record can show a gain and still have been a bad ride.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if stats.closedCount > 0 {
                Divider()

                HStack(alignment: .top) {
                    statTile(title: "Avg Win",
                             value: CurrencyFormatter.rupees(stats.averageWin), tint: Theme.profit)
                    Spacer()
                    statTile(title: "Avg Loss",
                             value: CurrencyFormatter.rupees(stats.averageLoss), tint: Theme.loss)
                    Spacer()
                    statTile(
                        title: "Profit Factor",
                        value: stats.profitFactor.map { String(format: "%.2f", $0) } ?? "—",
                        tint: .primary
                    )
                }
            }

            if let winners = stats.averageHoldWinners, let losers = stats.averageHoldLosers {
                Divider()

                HStack(alignment: .top) {
                    statTile(title: "Winners Held",
                             value: String(format: "%.1f days", winners), tint: .primary)
                    Spacer()
                    statTile(title: "Losers Held",
                             value: String(format: "%.1f days", losers), tint: .primary)
                }

                // The most common way a record goes wrong, and invisible in the return.
                Text(stats.holdsLosersLonger
                     ? "You hold losers longer than winners — cutting gains short while letting losses run."
                     : "You hold winners longer than losers, which is the way round you want it.")
                    .font(.caption2)
                    .foregroundStyle(stats.holdsLosersLonger ? Theme.caution : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    var summaryCard: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your Return")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("\(portfolioReturn >= 0 ? "+" : "")\(portfolioReturn, specifier: "%.2f")%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(portfolioReturn >= 0 ? Theme.profit : Theme.loss)
                Text("Time-weighted, so deposits don't count as gains")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                statTile(
                    title: "NIFTY 50",
                    value: String(format: "%@%.2f%%", benchmarkReturn >= 0 ? "+" : "", benchmarkReturn),
                    tint: benchmarkReturn >= 0 ? Theme.profit : Theme.loss
                )
                Spacer()
                statTile(
                    title: "Difference",
                    value: String(format: "%@%.2f%%", (portfolioReturn - benchmarkReturn) >= 0 ? "+" : "", portfolioReturn - benchmarkReturn),
                    tint: isBeatingBenchmark ? Theme.profit : Theme.loss
                )
                Spacer()
                statTile(title: "Days Tracked", value: "\(snapshots.count)", tint: .primary)
            }
        }
        .card()
    }

    func statTile(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
                .foregroundColor(tint)
        }
    }

    private var paired: [PairedGrowth] {
        PerformanceMath.pair(portfolio: portfolioPoints, benchmark: benchmarkPoints)
    }

    /// The pair nearest the scrubbed day, for the readout above the chart.
    private var scrubbedPair: PairedGrowth? {
        scrubbedDay.flatMap { PerformanceMath.nearest(to: $0, in: paired) }
    }

    var growthChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Growth of ₹100")
                    .font(.headline)
                Spacer()

                if let pair = scrubbedPair {
                    // Scrubbing answers the question the card is really asking: on that
                    // day, how far ahead or behind were you?
                    Text("\(pair.date, format: .dateTime.day().month(.abbreviated)) · \(Theme.sign(pair.gap))\(abs(pair.gap), specifier: "%.2f")")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.pnl(pair.gap))
                        .contentTransition(.numericText(value: pair.gap))
                }
            }

            Chart {
                // The rebase point: anything above this line is a gain.
                RuleMark(y: .value("Start", PerformanceMath.base))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // The gap between the two lines is the whole point of the card, and it
                // was left to the eye to estimate. Shading it states it.
                ForEach(paired) { pair in
                    AreaMark(
                        x: .value("Date", pair.date),
                        yStart: .value("Index", pair.index),
                        yEnd: .value("Mine", pair.mine)
                    )
                    .foregroundStyle((pair.isAhead ? Theme.profit : Theme.loss).opacity(0.16))
                }

                ForEach(portfolioPoints + benchmarkPoints) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Growth", point.value)
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                if let pair = scrubbedPair {
                    RuleMark(x: .value("Date", pair.date))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    PointMark(x: .value("Date", pair.date), y: .value("Mine", pair.mine))
                        .foregroundStyle(Theme.accent)
                    PointMark(x: .value("Date", pair.date), y: .value("Index", pair.index))
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartForegroundStyleScale([
                PerformanceMath.portfolioSeries: Theme.accent,
                PerformanceMath.benchmarkSeries: Color.secondary
            ])
            .chartYScale(domain: growthDomain)
            .chartLegend(position: .bottom)
            .frame(height: 240)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    guard let plot = proxy.plotFrame else { return }
                                    let x = drag.location.x - geometry[plot].origin.x
                                    scrubbedDay = proxy.value(atX: x, as: Date.self)
                                }
                                .onEnded { _ in scrubbedDay = nil }
                        )
                }
            }
        }
        .card()
    }

    var verdictCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isBeatingBenchmark ? "trophy.fill" : "info.circle.fill")
                .font(.title3)
                .foregroundStyle(isBeatingBenchmark ? Theme.profit : Theme.caution)

            VStack(alignment: .leading, spacing: 4) {
                Text(isBeatingBenchmark ? "Ahead of the index" : "Behind the index")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(isBeatingBenchmark
                     ? "You're outperforming a passive NIFTY 50 holding over this period. Check Trade History to see which decisions drove it."
                     : "A passive NIFTY 50 holding would have done better over this period. Most active traders trail the index — Trade History shows which decisions cost you.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}

#Preview {
    NavigationStack {
        PerformanceView()
    }
}
