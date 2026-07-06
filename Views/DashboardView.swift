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
    
    
    @State private var showingCashAlert = false
    @State private var enteredCashString = ""
    
    
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
                            
                            Text("₹\(totalPortfolioValue, specifier: "%.2f")")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .id(cashBalance)
                        }
                        Spacer()
                        
                        
                        Text("\(isProfit ? "+" : "")\(pnlPercentage, specifier: "%.2f")%")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(isProfit ? .green : .red)
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
                            Text("₹\(totalStockValue, specifier: "%.2f")")
                                .font(.headline)
                        }
                        
                        Spacer()
                        
                        
                        Button(action: {
                            enteredCashString = String(format: "%.2f", cashBalance)
                            showingCashAlert = true
                        }) {
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                    Text("Available Cash")
                                        .font(.caption)
                                }
                                .foregroundColor(.purple)
                                
                                Text("₹\(cashBalance, specifier: "%.2f")")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                
                
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
                                    Text("₹\(item.currentValue, specifier: "%.2f")")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("\(item.isProfit ? "+" : "")\(item.pnlPercentage, specifier: "%.2f")%")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(item.isProfit ? .green : .red)
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
        
        .alert("Edit Available Cash", isPresented: showingQuantityAlertBinding) {
            TextField("Cash Amount", text: $enteredCashString)
                .keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let cleanString = enteredCashString.replacingOccurrences(of: ",", with: "")
                if let value = Double(cleanString), value >= 0 {
                    if let existing = settings.first {
                        existing.availableCash = value
                    } else {
                        let newSettings = UserSettings(availableCash: value)
                        modelContext.insert(newSettings)
                    }
                    
                    
                    try? modelContext.save()
                    
                    
                    enteredCashString = ""
                }
            }
        }
    }
}


private extension DashboardView {
    var showingQuantityAlertBinding: Binding<Bool> {
        Binding(
            get: { showingCashAlert },
            set: { showingCashAlert = $0 }
        )
    }
}
