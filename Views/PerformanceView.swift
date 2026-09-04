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

enum PerformanceMath {
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

    @State private var isRebuilding = false
    @State private var rebuildNotice: String?

    /// There is only a past to rebuild if a trade predates today. Offering the button
    /// for an account whose first trade is today promises something it cannot deliver.
    private var canRebuild: Bool {
        guard let earliest = trades.map(\.timestamp).min() else { return false }
        return earliest < Calendar.current.startOfDay(for: Date())
    }

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

    var growthChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Growth of ₹100")
                .font(.headline)

            Chart {
                // The rebase point: anything above this line is a gain.
                RuleMark(y: .value("Start", PerformanceMath.base))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                ForEach(portfolioPoints + benchmarkPoints) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Growth", point.value)
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartForegroundStyleScale([
                PerformanceMath.portfolioSeries: Theme.accent,
                PerformanceMath.benchmarkSeries: Color.secondary
            ])
            .chartYScale(domain: growthDomain)
            .chartLegend(position: .bottom)
            .frame(height: 240)
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
