//
//  StockDetailView.swift
//  TradeX
//
//  Created by vedant jagdale on 04/07/26.
//

import SwiftUI
import Charts

struct StockDetailView: View {
    let stock: NSEStock
    
    @State private var chartData: [ChartPoint] = []
    @State private var currentPrice: Double = 0.0
    @State private var selectedRange = "1mo"
    @State private var isLoading = true
    
    let ranges = ["1d", "5d", "1mo", "6mo", "1y"]
    
    var priceChange: Double {
        guard let firstPrice = chartData.first?.price else { return 0.0 }
        return currentPrice - firstPrice
    }
    
    var priceChangePercentage: Double {
        guard let firstPrice = chartData.first?.price, firstPrice > 0 else { return 0.0 }
        return (priceChange / firstPrice) * 100
    }
    
    var isPositive: Bool { priceChange >= 0 }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stock.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("₹\(currentPrice, specifier: "%.2f")")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    
                    HStack(spacing: 4) {
                        Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.left")
                        Text("\(isPositive ? "+" : "")₹\(abs(priceChange), specifier: "%.2f") (\(String(format: "%.2f", priceChangePercentage))%)")
                    }
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(isPositive ? .green : .red)
                }
                .padding(.horizontal)
                
                Picker("Range", selection: $selectedRange) {
                    ForEach(ranges, id: \.self) { range in
                        Text(range.uppercased()).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: selectedRange) { _, _ in
                    Task { await loadTimelineMetrics() }
                }
                
                ZStack {
                    if isLoading {
                        ProgressView()
                            .frame(height: 220)
                    } else if !chartData.isEmpty {
                        Chart {
                            ForEach(chartData) { point in
                                LineMark(
                                    x: .value("Time", point.date),
                                    y: .value("Price", point.price)
                                )
                                .foregroundStyle(isPositive ? Color.green : Color.red)
                                .interpolationMethod(.catmullRom)
                                
                                AreaMark(
                                    x: .value("Time", point.date),
                                    y: .value("Price", point.price)
                                )
                                .foregroundStyle(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            isPositive ? Color.green.opacity(0.2) : Color.red.opacity(0.2),
                                            Color.clear
                                        ]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartYScale(domain: minPrice()...maxPrice())
                        .frame(height: 220)
                        .padding(.horizontal)
                    } else {
                        ContentUnavailableView("No Chart Data", systemImage: "chart.line.flurry")
                            .frame(height: 220)
                    }
                }
                
                
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
        .task {
            await loadTimelineMetrics()
        }
    }
}

private extension StockDetailView {
    
    func loadTimelineMetrics() async {
        isLoading = true
        do {
            let points = try await MarketAPIService.shared.fetchHistoricalData(symbol: stock.symbol, range: selectedRange)
            await MainActor.run {
                self.chartData = points
                if let lastPrice = points.last?.price {
                    self.currentPrice = lastPrice
                }
                self.isLoading = false
            }
        } catch {
            print("Failed compiling chart timeline points: \(error)")
            isLoading = false
        }
    }
    
    func minPrice() -> Double {
        let prices = chartData.map { $0.price }
        return (prices.min() ?? 0.0) * 0.99
    }
    
    func maxPrice() -> Double {
        let prices = chartData.map { $0.price }
        return (prices.max() ?? 100.0) * 1.01
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
