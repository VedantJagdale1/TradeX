//
//  OrderTicketView.swift
//  TradeX
//

import SwiftUI

/// Everything the ticket needs to price and validate an order before it is placed.
struct OrderTicket: Identifiable {
    enum Side {
        case buy
        case sell
    }

    let id = UUID()
    let side: Side
    let symbol: String
    let companyName: String
    let price: Double

    /// Buys are capped by cash, sells by shares held.
    var availableCash: Double = 0
    var heldQuantity: Int = 0
    var averageCost: Double = 0

    static func buy(symbol: String, companyName: String, price: Double, availableCash: Double) -> OrderTicket {
        OrderTicket(side: .buy, symbol: symbol, companyName: companyName, price: price, availableCash: availableCash)
    }

    /// `freeQuantity` excludes shares already committed to resting sell orders.
    static func sell(holding: PortfolioHolding, freeQuantity: Int? = nil) -> OrderTicket {
        OrderTicket(
            side: .sell,
            symbol: holding.symbol,
            companyName: holding.companyName,
            price: holding.currentPrice,
            heldQuantity: freeQuantity ?? holding.quantity,
            averageCost: holding.avgBuyPrice
        )
    }
}

/// What the ticket produces. A nil `limitPrice` means execute now at the market.
struct OrderRequest {
    let quantity: Int
    let thesis: String

    /// Nil means execute now at the market.
    let limitPrice: Double?

    var kind: LimitOrder.Kind = .limit
    var trailPercent: Double?
    var timeInForce: LimitOrder.TimeInForce = .day

    var isResting: Bool { limitPrice != nil }
}

/// The order ticket.
///
/// Replaces the alert-based flow, which crammed three fields into a system dialog and
/// only revealed that an order was unaffordable *after* it was submitted. Cost and
/// buying power are shown as the size is typed, and failures render inline rather than
/// as a second alert fighting the first one's dismissal.
struct OrderTicketView: View {
    let ticket: OrderTicket
    let onSubmit: (OrderRequest) async -> String?

    @Environment(\.dismiss) private var dismiss

    @State private var quantityString = "1"
    /// Market plus the three resting kinds.
    enum Style: String, CaseIterable, Identifiable {
        case market, limit, stop, trailingStop

        var id: String { rawValue }

        var label: String {
            switch self {
            case .market: return "Market"
            case .limit: return "Limit"
            case .stop: return "Stop"
            case .trailingStop: return "Trail"
            }
        }

        var orderKind: LimitOrder.Kind? {
            switch self {
            case .market: return nil
            case .limit: return .limit
            case .stop: return .stop
            case .trailingStop: return .trailingStop
            }
        }
    }

    @State private var style: Style = .market
    @State private var limitPriceString = ""
    @State private var trailPercentString = "5"
    @State private var timeInForce: LimitOrder.TimeInForce = .day
    @State private var thesis = ""
    @State private var isSubmitting = false
    @State private var inlineError: String?
    @State private var didFill = false

    @FocusState private var quantityFocused: Bool

    private var isBuy: Bool { ticket.side == .buy }
    private var quantity: Int { Int(quantityString.trimmingCharacters(in: .whitespaces)) ?? 0 }

    private var isLimitOrder: Bool { style != .market }

    private var limitPrice: Double {
        Double(limitPriceString.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private var trailPercent: Double {
        Double(trailPercentString.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Where a trailing stop's trigger sits right now, given today's price.
    private var trailingTrigger: Double {
        isBuy ? ticket.price * (1 + trailPercent / 100)
              : ticket.price * (1 - trailPercent / 100)
    }

    /// A resting order is valued at the price it would act on.
    private var effectivePrice: Double {
        switch style {
        case .market: return ticket.price
        case .limit, .stop: return limitPrice
        case .trailingStop: return trailingTrigger
        }
    }

    private var orderValue: Double { Double(quantity) * effectivePrice }

    /// P&L this sell would book, at the price on screen.
    private var projectedPnL: Double {
        Double(quantity) * (ticket.price - ticket.averageCost)
    }

    private var accent: Color { isBuy ? Theme.profit : Theme.accent }

    /// The reason this order can't be placed, or nil when it can.
    private var blockingReason: String? {
        guard quantity > 0 else { return "Enter how many shares to \(isBuy ? "buy" : "sell")." }

        switch style {
        case .market:
            break

        case .limit:
            guard limitPrice > 0 else { return "Enter a limit price." }
            // A marketable limit executes now, so it can only be placed in a session.
            if isMarketableLimit, !MarketSession.isOpen() {
                return "That price executes immediately, so it can only be placed while the market is open (9:15am–3:30pm IST, Mon–Fri)."
            }

        case .stop:
            guard limitPrice > 0 else { return "Enter a stop price." }
            // Stops sit on the opposite side to limits: a sell stop caps a loss below
            // the market, a buy stop enters a breakout above it. On the wrong side it
            // would trigger instantly and behave as a market order.
            if isBuy, limitPrice <= ticket.price {
                return "A buy stop must be above \(CurrencyFormatter.rupees(ticket.price)) — below it, it would trigger immediately."
            }
            if !isBuy, limitPrice >= ticket.price {
                return "A stop-loss must be below \(CurrencyFormatter.rupees(ticket.price)) — above it, it would trigger immediately."
            }

        case .trailingStop:
            guard trailPercent > 0 else { return "Enter how far the stop should trail." }
            guard trailPercent < 100 else { return "A trail has to be less than 100%." }
        }

        if isBuy {
            let shortfall = orderValue - ticket.availableCash
            if shortfall > 0 {
                return "Short by \(CurrencyFormatter.rupees(shortfall)). Reduce the size or add cash."
            }
        } else if quantity > ticket.heldQuantity {
            return "You only hold \(ticket.heldQuantity) share\(ticket.heldQuantity == 1 ? "" : "s")."
        }

        return nil
    }

    /// A buy at or above the market, or a sell at or below it, crosses the spread and
    /// executes now rather than resting.
    private var isMarketableLimit: Bool {
        guard style == .limit, limitPrice > 0 else { return false }
        return isBuy ? limitPrice >= ticket.price : limitPrice <= ticket.price
    }

    /// What a marketable order would actually pay: the market, capped by the limit.
    private var marketableFillPrice: Double {
        isBuy ? min(ticket.price, limitPrice) : max(ticket.price, limitPrice)
    }

    private var canSubmit: Bool { blockingReason == nil && !isSubmitting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    priceHeader

                    Picker("Order type", selection: $style) {
                        ForEach(Style.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch style {
                    case .market: EmptyView()
                    case .limit, .stop: limitPriceSection
                    case .trailingStop: trailSection
                    }

                    sizeSection
                    summarySection

                    if let message = inlineError ?? blockingReason {
                        validationRow(message, isFailure: inlineError != nil)
                    }

                    reasonSection
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle(isBuy ? "Buy \(ticket.symbol)" : "Sell \(ticket.symbol)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") { quantityFocused = false }
                            .fontWeight(.semibold)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { submitBar }
            .sensoryFeedback(.success, trigger: didFill)
        }
        // Full height only: at .medium the projected P&L and buying power fall below
        // the fold, and those are the numbers the ticket exists to show.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}


private extension OrderTicketView {

    var priceHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ticket.companyName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            MoneyText(amount: ticket.price, font: Theme.Typography.hero)

            Text("Live market price")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    var trailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isBuy ? "Buy once it rises this far off the low" : "Sell if it drops this far from the high")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                TextField("5", text: $trailPercentString)
                    .keyboardType(.decimalPad)
                    .font(Theme.Typography.figure)
                Text("%")
                    .font(Theme.Typography.figure)
                    .foregroundStyle(.secondary)
            }

            if trailPercent > 0, trailPercent < 100 {
                Text("Triggers at \(CurrencyFormatter.rupees(trailingTrigger)) today, and \(isBuy ? "falls" : "rises") with the price.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The trigger only ever moves in your favour — it follows the price \(isBuy ? "down" : "up") and never gives ground.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    var limitPriceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(style == .stop
                 ? (isBuy ? "Buy if it rises to" : "Sell if it falls to")
                 : (isBuy ? "Buy when it falls to" : "Sell when it rises to"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("0.00", text: $limitPriceString)
                .keyboardType(.decimalPad)
                .font(Theme.Typography.figure)

            if limitPrice > 0, ticket.price > 0 {
                let distance = ((limitPrice - ticket.price) / ticket.price) * 100
                Text("\(Theme.sign(distance))\(distance, specifier: "%.2f")% from the current price")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if style == .stop {
                Label(
                    "A stop becomes a market order when it triggers, so the fill can be worse than this price.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(Theme.caution)
                .fixedSize(horizontal: false, vertical: true)
            }

            if isMarketableLimit {
                Label(
                    "Executes now at \(CurrencyFormatter.rupees(marketableFillPrice)) — your limit caps the price but won't make it wait.",
                    systemImage: "bolt.fill"
                )
                .font(.caption)
                .foregroundStyle(Theme.caution)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Time in force", selection: $timeInForce) {
                    ForEach(LimitOrder.TimeInForce.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(timeInForce == .day
                     ? "Expires at today's close, like an NSE day order."
                     : "Rests until it fills or you cancel it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    var sizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quantity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !isBuy {
                    Button("Sell all \(ticket.heldQuantity)") {
                        quantityString = "\(ticket.heldQuantity)"
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.accent)
                }
            }

            HStack(spacing: 16) {
                stepperButton(systemName: "minus", enabled: quantity > 1) {
                    quantityString = "\(max(1, quantity - 1))"
                }

                TextField("0", text: $quantityString)
                    .keyboardType(.numberPad)
                    .focused($quantityFocused)
                    .multilineTextAlignment(.center)
                    .font(Theme.Typography.figure)
                    .frame(maxWidth: .infinity)

                stepperButton(systemName: "plus", enabled: true) {
                    quantityString = "\(quantity + 1)"
                }
            }
        }
        .card()
    }

    func stepperButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.raisedSurface)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    var summarySection: some View {
        VStack(spacing: 12) {
            summaryRow(
                title: isBuy ? "Estimated cost" : "Estimated proceeds",
                value: AnyView(MoneyText(amount: orderValue))
            )

            Divider()

            if isBuy {
                summaryRow(
                    title: "Available cash",
                    value: AnyView(
                        MoneyText(
                            amount: ticket.availableCash,
                            font: .headline,
                            color: orderValue > ticket.availableCash ? Theme.loss : .primary
                        )
                    )
                )
            } else {
                summaryRow(
                    title: "Projected P&L",
                    value: AnyView(
                        MoneyText(
                            amount: projectedPnL,
                            font: .headline,
                            color: Theme.pnl(projectedPnL),
                            showsSign: true
                        )
                    )
                )
                summaryRow(
                    title: "Average cost",
                    value: AnyView(MoneyText(amount: ticket.averageCost, font: .subheadline, color: .secondary))
                )
            }
        }
        .card()
    }

    func summaryRow(title: String, value: AnyView) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            value
        }
    }

    func validationRow(_ message: String, isFailure: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isFailure ? Theme.loss : .secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(isFailure ? Theme.loss : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill((isFailure ? Theme.loss : Color.secondary).opacity(0.12))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    var reasonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isBuy ? "Why this trade?" : "Why sell?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(
                isBuy ? "Cheap vs sector, earnings catalyst…" : "Booking profit, thesis broke…",
                text: $thesis,
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.plain)

            Text("Recorded with the trade so you can review the reasoning later.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    var submitBar: some View {
        Button {
            submit()
        } label: {
            HStack {
                if isSubmitting {
                    ProgressView().tint(.white)
                } else {
                    Text(isLimitOrder && !isMarketableLimit
                         ? "Place \(isBuy ? "Buy" : "Sell") \(style.label) Order"
                         : "\(isBuy ? "Buy" : "Sell") \(max(quantity, 0)) \(quantity == 1 ? "share" : "shares")")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(canSubmit ? accent : Color.secondary.opacity(0.3))
            )
            .foregroundStyle(canSubmit ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .padding()
        .background(.bar)
        .animation(Theme.Motion.layout, value: canSubmit)
    }

    func submit() {
        quantityFocused = false
        inlineError = nil
        isSubmitting = true

        let size = quantity
        let reason = thesis.trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor in
            let failure = await onSubmit(
                OrderRequest(
                    quantity: size,
                    thesis: reason,
                    limitPrice: isLimitOrder ? effectivePrice : nil,
                    kind: style.orderKind ?? .limit,
                    trailPercent: style == .trailingStop ? trailPercent : nil,
                    timeInForce: timeInForce
                )
            )
            isSubmitting = false

            if let failure {
                withAnimation(Theme.Motion.layout) { inlineError = failure }
            } else {
                didFill.toggle()
                dismiss()
            }
        }
    }
}
