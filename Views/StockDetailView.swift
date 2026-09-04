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

    /// The detail screen already shows a live price, so its ticket only needs a size and
    /// a reason — no "leave blank for live price" step like the Explore list needs.
    enum BuyAlert: Identifiable {
        case ticket
        case failure(message: String)

        var id: String {
            switch self {
            case .ticket: return "ticket"
            case let .failure(message): return "fail-\(message)"
            }
        }
    }

    @State private var activeAlert: BuyAlert?
    @State private var enteredQuantityString = "1"
    @State private var enteredThesisString = ""

    @State private var chartData: [ChartPoint] = []
    @State private var currentPrice: Double = 0.0
    @State private var selectedRange = "1mo"
    @State private var isLoading = true
    @State private var loadFailed = false

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

                    Text("₹\(currentPrice, specifier: "%.2f")")
                        .font(.system(size: 36, weight: .bold, design: .rounded))

                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.left")
                            Text("\(isPositive ? "+" : "")₹\(abs(priceChange), specifier: "%.2f") (\(String(format: "%.2f", priceChangePercentage))%)")
                        }
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(isPositive ? .green : .red)

                        Text(rangeCaption)
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                                            isPositive ? Color.green.opacity(0.25) : Color.red.opacity(0.25),
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
                                .foregroundStyle(isPositive ? Color.green : Color.red)
                                .interpolationMethod(.catmullRom)
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartYScale(domain: priceDomain)
                        .frame(height: 220)
                        .padding(.horizontal)
                    } else {
                        chartUnavailableView
                            .frame(height: 220)
                    }
                }

                Button {
                    enteredQuantityString = "1"
                    enteredThesisString = ""
                    activeAlert = .ticket
                } label: {
                    Label("Buy \(stock.symbol)", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(currentPrice <= 0)
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Key Metrics")
                        .font(.headline)
                        .padding(.horizontal)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        metricTile(title: "Symbol", value: stock.symbol)
                        metricTile(title: "Exchange", value: "NSE")
                        metricTile(title: "ISIN", value: stock.isin.isEmpty ? "N/A" : stock.isin)
                        metricTile(title: "Series", value: stock.series.isEmpty ? "EQ" : stock.series)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(stock.symbol)
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on the range so switching cancels the in-flight load. Without that, a slow
        // response for one range could land after a faster one and show the wrong series.
        .task(id: selectedRange) {
            await loadTimelineMetrics()
        }
        .alert(buyAlertTitle, isPresented: buyAlertBinding, presenting: activeAlert) { alert in
            switch alert {
            case .ticket:
                TextField("Quantity", text: $enteredQuantityString)
                    .keyboardType(.numberPad)

                TextField("Why this trade? (optional)", text: $enteredThesisString)

                Button("Cancel", role: .cancel) {}

                Button("Buy") { submitOrder() }

            case .failure:
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case .ticket:
                Text("Buying \(stock.symbol) at \(CurrencyFormatter.rupees(currentPrice)) per share.")
            case let .failure(message):
                Text(message)
            }
        }
    }
}

private extension StockDetailView {

    var buyAlertTitle: String {
        switch activeAlert {
        case .ticket: return "Buy \(stock.symbol)"
        case .failure: return "Order Not Placed"
        case nil: return ""
        }
    }

    var buyAlertBinding: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { isPresented in
                if !isPresented { activeAlert = nil }
            }
        )
    }

    /// Buys at the price already on screen, so what the user sees is what they pay.
    func submitOrder() {
        let quantityText = enteredQuantityString.trimmingCharacters(in: .whitespacesAndNewlines)
        let thesisText = enteredThesisString.trimmingCharacters(in: .whitespacesAndNewlines)
        let price = currentPrice

        Task { @MainActor in
            do {
                guard let quantity = Int(quantityText), quantity > 0 else {
                    throw PortfolioError.invalidQuantity
                }
                try await PortfolioManager.shared.addStock(
                    symbol: stock.symbol,
                    companyName: stock.name,
                    quantity: quantity,
                    buyPrice: price,
                    thesis: thesisText,
                    modelContext: modelContext
                )
            } catch {
                activeAlert = .failure(message: error.localizedDescription)
            }
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

    func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
}
