//
//  DashboardView.swift
//  TradeX
//
//  Created by vedant jagdale on 02/07/26.
//

import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PortfolioHolding.symbol) private var holdings: [PortfolioHolding]
    @Query private var settings: [UserSettings]
    
    
    @State private var showingCashSheet = false
    
    
    var cashBalance: Double {
        settings.first?.availableCash ?? 274500.00
    }
    
    
    var totalInvested: Double { holdings.reduce(0) { $0 + $1.investedAmount } }
    var totalStockValue: Double { holdings.reduce(0) { $0 + $1.currentValue } }
    var totalPortfolioValue: Double { totalStockValue + cashBalance }
    
    var totalPnL: Double { totalStockValue - totalInvested }
    var pnlPercentage: Double { totalInvested > 0 ? (totalPnL / totalInvested) * 100 : 0 }
    var isProfit: Bool { totalPnL >= 0 }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                
                
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total Net Worth")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            MoneyText(amount: totalPortfolioValue, font: Theme.Typography.hero)
                        }
                        Spacer()
                        
                        
                        PercentText(value: pnlPercentage, font: .headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isProfit ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }
                    
                    Divider()
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stocks Value")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            MoneyText(amount: totalStockValue, font: .headline)
                        }
                        
                        Spacer()
                        
                        
                        Button(action: {
                            showingCashSheet = true
                        }) {
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                    Text("Available Cash")
                                        .font(.caption)
                                }
                                .foregroundColor(.purple)
                                
                                MoneyText(amount: cashBalance, font: .headline)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .card()
                
                
                if !holdings.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Portfolio Distribution")
                            .font(.headline)
                        
                        Chart(holdings) { holding in
                            SectorMark(
                                angle: .value("Value", holding.currentValue),
                                innerRadius: .ratio(0.7),
                                angularInset: 2.0
                            )
                            .foregroundStyle(by: .value("Stock", holding.symbol))
                        }
                        .frame(height: 150)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("My Positions")
                        .font(.title3)
                        .bold()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if holdings.isEmpty {
                        Text("No stock positions found. Go to Explore to add some!")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(holdings) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.symbol)
                                        .font(.headline)
                                    Text("\(item.quantity) Shares")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                
                                let weight = totalStockValue > 0 ? (item.currentValue / totalStockValue) : 0
                                Text(String(format: "%.0f%% wt", weight * 100))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(.systemBackground))
                                    .cornerRadius(6)
                                
                                Spacer()
                                
                                VStack(alignment: .trailing, spacing: 4) {
                                    MoneyText(amount: item.currentValue, font: .subheadline.weight(.semibold))
                                    PercentText(value: item.pnlPercentage)
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Dashboard")
        // Net worth here is computed from each holding's stored `currentPrice`. Without
        // this the numbers stayed frozen until the Portfolio tab happened to refresh
        // them, so the two tabs could show different values for the same positions.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PerformanceView()
                } label: {
                    Label("Performance", systemImage: "chart.xyaxis.line")
                }
            }
        }
        .task {
            await PortfolioManager.shared.refreshPrices(modelContext: modelContext)
            // Marked after the refresh so the day's value reflects current prices.
            await PortfolioManager.shared.recordDailySnapshot(modelContext: modelContext)
        }
        .sheet(isPresented: $showingCashSheet) {
            CashSheet(currentBalance: cashBalance) { newBalance, note in
                PortfolioManager.shared.adjustCash(
                    to: newBalance,
                    note: note,
                    modelContext: modelContext
                )
            }
        }
    }
}


/// Deposit and withdraw cash.
///
/// Framed as a flow of money in or out rather than "set the balance", because that is
/// what actually gets recorded: every change becomes a `CashAdjustment`, and the
/// Performance screen divides by deposited capital so a top-up dilutes returns instead
/// of flattering them.
struct CashSheet: View {
    let currentBalance: Double
    let onSubmit: (Double, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isDeposit = true
    @State private var amountString = ""
    @FocusState private var amountFocused: Bool

    private static let quickAmounts: [Double] = [10_000, 50_000, 100_000]

    private var amount: Double {
        Double(amountString.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private var resultingBalance: Double {
        isDeposit ? currentBalance + amount : currentBalance - amount
    }

    /// Only an actual over-withdrawal is an error. An empty field is merely incomplete,
    /// so the resulting balance shouldn't be tinted red just because nothing is typed.
    private var isOverdrawn: Bool {
        !isDeposit && amount > currentBalance
    }

    private var blockingReason: String? {
        guard amount > 0 else { return "Enter an amount." }
        if !isDeposit, amount > currentBalance {
            return "You only have \(CurrencyFormatter.rupees(currentBalance)) in cash."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Available cash")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        MoneyText(amount: currentBalance, font: Theme.Typography.hero)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    Picker("Direction", selection: $isDeposit) {
                        Text("Deposit").tag(true)
                        Text("Withdraw").tag(false)
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Amount")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("0.00", text: $amountString)
                            .keyboardType(.decimalPad)
                            .focused($amountFocused)
                            .font(Theme.Typography.figure)

                        HStack(spacing: 8) {
                            ForEach(Self.quickAmounts, id: \.self) { value in
                                Button {
                                    amountString = String(format: "%.0f", value)
                                } label: {
                                    Text("\(isDeposit ? "+" : "")\(CurrencyFormatter.rupees(value).replacingOccurrences(of: ".00", with: ""))")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                                .fill(Theme.accent.opacity(0.15))
                                        )
                                        .foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    HStack {
                        Text("New balance")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        MoneyText(
                            amount: max(resultingBalance, 0),
                            font: .headline,
                            color: isOverdrawn ? Theme.loss : .primary
                        )
                    }
                    .card()

                    if let blockingReason {
                        Text(blockingReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("Recorded as a cash adjustment. Returns are measured against deposited capital, so adding cash never counts as a gain.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle(isDeposit ? "Deposit Cash" : "Withdraw Cash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") { amountFocused = false }.fontWeight(.semibold)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onSubmit(resultingBalance, isDeposit ? "Deposit" : "Withdrawal")
                    dismiss()
                } label: {
                    Text(isDeposit ? "Add Cash" : "Withdraw")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(blockingReason == nil ? Theme.accent : Color.secondary.opacity(0.3))
                        )
                        .foregroundStyle(blockingReason == nil ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(blockingReason != nil)
                .padding()
                .background(.bar)
                .animation(Theme.Motion.layout, value: blockingReason == nil)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
