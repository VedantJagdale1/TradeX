//
//  AlertsView.swift
//  TradeX
//

import SwiftUI
import SwiftData

struct AlertsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PriceAlert.createdAt, order: .reverse) private var alerts: [PriceAlert]

    @State private var isCheckingNow = false
    @State private var notificationsDenied = false

    private var armed: [PriceAlert] { alerts.filter(\.isArmed) }
    private var triggered: [PriceAlert] { alerts.filter(\.isTriggered) }

    var body: some View {
        Group {
            if alerts.isEmpty {
                ContentUnavailableView {
                    Label("No Price Alerts", systemImage: "bell.slash")
                } description: {
                    Text("Open any stock and tap the bell to be told when it reaches a price you care about.")
                }
            } else {
                List {
                    if notificationsDenied {
                        Section {
                            Label(
                                "Notifications are turned off for TradeX. Alerts will still trigger in the app, but you won't be told about them.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(Theme.caution)
                        }
                    }

                    if !armed.isEmpty {
                        Section("Watching (\(armed.count))") {
                            ForEach(armed) { alert in
                                row(for: alert)
                            }
                            .onDelete { delete($0, from: armed) }
                        }
                    }

                    if !triggered.isEmpty {
                        Section("Triggered (\(triggered.count))") {
                            ForEach(triggered) { alert in
                                row(for: alert)
                            }
                            .onDelete { delete($0, from: triggered) }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }
        }
        .navigationTitle("Price Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isCheckingNow {
                    ProgressView()
                } else {
                    Button {
                        Task { await checkNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(armed.isEmpty)
                }
            }
        }
        .task {
            notificationsDenied = await !PriceAlertService.requestAuthorization()
        }
    }
}


private extension AlertsView {

    func row(for alert: PriceAlert) -> some View {
        HStack(spacing: 12) {
            Image(systemName: alert.isTriggered
                  ? "bell.badge.fill"
                  : (alert.isAbove ? "arrow.up.circle" : "arrow.down.circle"))
                .font(.title3)
                .foregroundStyle(alert.isTriggered ? Theme.caution : Theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.symbol)
                    .font(.headline)

                Text(alert.conditionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let triggeredAt = alert.triggeredAt, let price = alert.triggeredPrice {
                    Text("Hit \(CurrencyFormatter.rupees(price)) on \(triggeredAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(Theme.caution)
                }
            }

            Spacer()

            if !alert.isTriggered {
                Toggle("", isOn: Binding(
                    get: { alert.isEnabled },
                    set: { alert.isEnabled = $0; try? modelContext.save() }
                ))
                .labelsHidden()
            }
        }
        .padding(.vertical, 4)
    }

    func delete(_ offsets: IndexSet, from group: [PriceAlert]) {
        for index in offsets {
            modelContext.delete(group[index])
        }
        try? modelContext.save()
    }

    func checkNow() async {
        isCheckingNow = true
        defer { isCheckingNow = false }
        // Tapping refresh should ask the market, not re-read a cached quote.
        await PriceAlertService.checkAll(modelContext: modelContext, quoteMaxAge: 0)
    }
}


/// Creates an alert for one stock. Presented from the stock's detail screen, so the
/// current price is already known and can seed a sensible target.
struct NewAlertSheet: View {
    let symbol: String
    let companyName: String
    let currentPrice: Double

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isAbove = true
    @State private var targetString = ""
    @FocusState private var targetFocused: Bool

    private var target: Double {
        Double(targetString.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// How far the target sits from the current price, which is the sanity check that
    /// matters most when typing one in.
    private var distancePercent: Double {
        guard currentPrice > 0, target > 0 else { return 0 }
        return ((target - currentPrice) / currentPrice) * 100
    }

    private var blockingReason: String? {
        guard target > 0 else { return "Enter a target price." }
        if isAbove, target <= currentPrice {
            return "A rise alert needs a target above \(CurrencyFormatter.rupees(currentPrice))."
        }
        if !isAbove, target >= currentPrice {
            return "A fall alert needs a target below \(CurrencyFormatter.rupees(currentPrice))."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(companyName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        MoneyText(amount: currentPrice, font: Theme.Typography.hero)
                        Text("Current price")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    Picker("Direction", selection: $isAbove) {
                        Text("Rises to").tag(true)
                        Text("Falls to").tag(false)
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Target price")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("0.00", text: $targetString)
                            .keyboardType(.decimalPad)
                            .focused($targetFocused)
                            .font(Theme.Typography.figure)

                        if target > 0, blockingReason == nil {
                            Text("\(Theme.sign(distancePercent))\(distancePercent, specifier: "%.2f")% from here")
                                .font(.caption)
                                .foregroundStyle(Theme.pnl(distancePercent))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    if let blockingReason {
                        Text(blockingReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("TradeX checks prices when you open the app and periodically in the background. iOS decides background timing, so an alert can arrive later than the moment the price is hit.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Alert for \(symbol)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") { targetFocused = false }.fontWeight(.semibold)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    createAlert()
                } label: {
                    Text("Create Alert")
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
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func createAlert() {
        modelContext.insert(
            PriceAlert(
                symbol: symbol,
                companyName: companyName,
                targetPrice: target,
                isAbove: isAbove
            )
        )
        try? modelContext.save()

        // Permission is asked for here, where the user has just shown they want to be told.
        Task { await PriceAlertService.requestAuthorization() }
        dismiss()
    }
}
