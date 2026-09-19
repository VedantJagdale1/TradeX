//
//  ProtectPositionSheet.swift
//  TradeX
//

import SwiftUI
import SwiftData

/// Attaches an exit plan to a position you already hold: a target above and a stop
/// below, of which only one can ever fill.
///
/// A position with only a stop caps the loss but never books the gain; one with only a
/// target rides the loss down forever. Deciding both at once — while nothing is moving
/// and there is nothing to feel — is the whole point, so the sheet insists on both and
/// shows what you are risking to make what.
struct ProtectPositionSheet: View {
    let holding: PortfolioHolding
    let freeQuantity: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private enum Protection: String, CaseIterable, Identifiable {
        case stop, trailing
        var id: String { rawValue }
        var label: String { self == .stop ? "Fixed Stop" : "Trailing Stop" }
    }

    @State private var quantityString: String
    @State private var targetString: String
    @State private var stopString: String
    @State private var trailString = "8"
    @State private var protection: Protection = .stop
    @State private var thesis = ""
    @State private var failure: String?
    @State private var isPlacing = false

    init(holding: PortfolioHolding, freeQuantity: Int) {
        self.holding = holding
        self.freeQuantity = freeQuantity
        _quantityString = State(initialValue: String(freeQuantity))
        // Seeded at a conventional 10% up / 5% down, which is a 2:1 plan — a starting
        // point to argue with, not a recommendation.
        _targetString = State(initialValue: Self.round(holding.currentPrice * 1.10))
        _stopString = State(initialValue: Self.round(holding.currentPrice * 0.95))
    }

    var body: some View {
        NavigationStack {
            Form {
                positionHeader

                Section("Quantity") {
                    HStack {
                        TextField("Shares", text: $quantityString)
                            .keyboardType(.numberPad)
                        Spacer()
                        Text("of \(freeQuantity) free")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                targetSection
                protectionSection

                if let plan = plan {
                    riskRewardSection(plan)
                }

                Section {
                    TextField("Why this exit plan? (optional)", text: $thesis, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Both orders rest until one fills. Whichever the market reaches first cancels the other.")
                }

                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(Theme.loss)
                }
            }
            .navigationTitle("Protect Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Place") { place() }
                        .fontWeight(.semibold)
                        .disabled(isPlacing || plan == nil)
                }
            }
        }
    }
}


private extension ProtectPositionSheet {

    /// The numbers behind the readout, or nil while the inputs don't form a real plan.
    struct ExitPlan {
        let quantity: Int
        let target: Double
        let stop: Double
        let reward: Double
        let risk: Double

        /// How many rupees of upside per rupee risked. Below 1 you need to be right
        /// more than half the time just to break even.
        var ratio: Double { risk > 0 ? reward / risk : 0 }
    }

    var quantity: Int { Int(quantityString) ?? 0 }
    var target: Double { Double(targetString) ?? 0 }

    /// A trailing stop's initial trigger sits `trailPercent` below today's price.
    var effectiveStop: Double {
        switch protection {
        case .stop: return Double(stopString) ?? 0
        case .trailing:
            let percent = Double(trailString) ?? 0
            return holding.currentPrice * (1 - percent / 100)
        }
    }

    var plan: ExitPlan? {
        let stop = effectiveStop
        guard quantity > 0, quantity <= freeQuantity,
              target > holding.currentPrice,
              stop > 0, stop < holding.currentPrice else { return nil }

        return ExitPlan(
            quantity: quantity,
            target: target,
            stop: stop,
            reward: (target - holding.currentPrice) * Double(quantity),
            risk: (holding.currentPrice - stop) * Double(quantity)
        )
    }

    static func round(_ value: Double) -> String {
        String(format: "%.2f", (value * 20).rounded() / 20)
    }

    var positionHeader: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(holding.symbol)
                        .font(.headline)
                    Text("\(holding.quantity) shares · avg \(CurrencyFormatter.rupees(holding.avgBuyPrice))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    MoneyText(amount: holding.currentPrice, font: .headline)
                    Text("last traded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    var targetSection: some View {
        Section {
            HStack {
                Text("₹")
                    .foregroundStyle(.secondary)
                TextField("Target", text: $targetString)
                    .keyboardType(.decimalPad)
                Spacer()
                Text(offsetLabel(for: target))
                    .font(.caption)
                    .foregroundStyle(Theme.profit)
            }
            percentChips(of: [5, 10, 15, 25], sign: 1) { targetString = Self.round($0) }
        } header: {
            Text("Take Profit")
        } footer: {
            Text("A sell limit above the market. Fills at your price or better.")
        }
    }

    var protectionSection: some View {
        Section {
            Picker("Protection", selection: $protection) {
                ForEach(Protection.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)

            switch protection {
            case .stop:
                HStack {
                    Text("₹")
                        .foregroundStyle(.secondary)
                    TextField("Stop", text: $stopString)
                        .keyboardType(.decimalPad)
                    Spacer()
                    Text(offsetLabel(for: Double(stopString) ?? 0))
                        .font(.caption)
                        .foregroundStyle(Theme.loss)
                }
                percentChips(of: [3, 5, 8, 12], sign: -1) { stopString = Self.round($0) }

            case .trailing:
                HStack {
                    TextField("Trail %", text: $trailString)
                        .keyboardType(.decimalPad)
                    Spacer()
                    Text("triggers at \(CurrencyFormatter.rupees(effectiveStop))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Downside")
        } footer: {
            Text(protection == .stop
                 ? "A sell stop below the market. Becomes a market order when touched, so the fill can be worse than the trigger."
                 : "Follows the high water mark up and never back down, locking in gains as the position runs.")
        }
    }

    func riskRewardSection(_ plan: ExitPlan) -> some View {
        Section("If It Works · If It Doesn't") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Target hit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MoneyText(amount: plan.reward, font: .headline,
                              color: Theme.profit, showsSign: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Stop hit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MoneyText(amount: -plan.risk, font: .headline,
                              color: Theme.loss, showsSign: true)
                }
            }
            .padding(.vertical, 2)

            HStack {
                Text("Risk / reward")
                Spacer()
                Text(String(format: "1 : %.2f", plan.ratio))
                    .fontWeight(.semibold)
                    .foregroundStyle(plan.ratio >= 1.5 ? Theme.profit
                                     : (plan.ratio >= 1 ? Theme.caution : Theme.loss))
            }

            // The break-even hit rate is the honest version of "is this a good trade":
            // at 1:1 you must be right more than half the time, at 1:3 only a quarter.
            Text(breakEvenNote(plan))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func breakEvenNote(_ plan: ExitPlan) -> String {
        guard plan.ratio > 0 else { return "" }
        let hitRate = 100 / (1 + plan.ratio)
        return String(
            format: "You need to be right %.0f%% of the time for this shape of trade to break even.",
            hitRate
        )
    }

    func offsetLabel(for price: Double) -> String {
        guard holding.currentPrice > 0, price > 0 else { return "" }
        let percent = (price / holding.currentPrice - 1) * 100
        return String(format: "%@%.1f%%", Theme.sign(percent), percent)
    }

    func percentChips(of offsets: [Double], sign: Double, apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(offsets, id: \.self) { offset in
                Button {
                    apply(holding.currentPrice * (1 + sign * offset / 100))
                } label: {
                    Text(String(format: "%@%.0f%%", sign > 0 ? "+" : "−", offset))
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(Color.secondary.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    func place() {
        isPlacing = true
        defer { isPlacing = false }

        let message = LimitOrderService.protectPosition(
            holding: holding,
            quantity: quantity,
            targetPrice: target,
            stopPrice: protection == .stop ? Double(stopString) : nil,
            trailPercent: protection == .trailing ? Double(trailString) : nil,
            thesis: thesis,
            modelContext: modelContext
        )

        if let message {
            failure = message
        } else {
            dismiss()
        }
    }
}
