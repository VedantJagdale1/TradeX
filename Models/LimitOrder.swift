//
//  LimitOrder.swift
//  TradeX
//

import Foundation
import SwiftData
import UserNotifications

/// A resting order that executes when the market reaches a chosen price.
///
/// Covers limits and stops alike — they share a lifecycle, a checking loop and a set of
/// reservations, and differ only in which side of the market they wait on.
///
/// Limits wait for a *better* price: a buy limit rests **below** the market, a sell limit
/// **above** it. Stops wait for a *worse* one and are the exact inverse: a sell stop
/// rests **below** the market to cap a loss, a buy stop **above** it to enter a breakout.
/// Getting that inversion wrong turns a stop-loss into a take-profit, so it is asserted
/// in both directions by the tests.
@Model
final class LimitOrder {
    @Attribute(.unique) var id: UUID
    var symbol: String
    var companyName: String
    var isBuy: Bool
    var quantity: Int

    /// The price the order acts at: the limit for a limit order, the trigger for a stop.
    /// For a trailing stop this holds the current trigger, recomputed as the market moves.
    var limitPrice: Double

    var thesis: String

    /// Stored as a raw string; read through `kind`.
    var kindRaw: String

    /// How far a trailing stop sits from the best price seen, as a percentage.
    var trailPercent: Double?

    /// The best price reached since the order was placed — the high for a trailing sell,
    /// the low for a trailing buy. A trail ratchets in the favourable direction only.
    var extremePrice: Double?

    /// Stored as a raw string; read through `state`.
    var statusRaw: String

    var createdAt: Date

    /// When the order stops being live. Nil is good-till-cancelled; a day order is set
    /// to the session close, matching NSE's default.
    var expiresAt: Date?

    var filledAt: Date?
    var filledPrice: Double?
    var failureReason: String?

    init(
        id: UUID = UUID(),
        symbol: String,
        companyName: String,
        isBuy: Bool,
        quantity: Int,
        limitPrice: Double,
        kind: Kind = .limit,
        trailPercent: Double? = nil,
        thesis: String = "",
        expiresAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.symbol = symbol
        self.companyName = companyName
        self.isBuy = isBuy
        self.quantity = quantity
        self.limitPrice = limitPrice
        self.thesis = thesis
        self.statusRaw = State.open.rawValue
        self.kindRaw = kind.rawValue
        self.trailPercent = trailPercent
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    enum State: String {
        case open, filled, cancelled, failed, expired
    }

    enum Kind: String, CaseIterable, Identifiable {
        case limit, stop, trailingStop

        var id: String { rawValue }

        var label: String {
            switch self {
            case .limit: return "Limit"
            case .stop: return "Stop"
            case .trailingStop: return "Trail"
            }
        }

        var isStop: Bool { self != .limit }
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .limit }
        set { kindRaw = newValue.rawValue }
    }

    enum TimeInForce: String, CaseIterable, Identifiable {
        case day, goodTillCancelled

        var id: String { rawValue }

        var label: String {
            switch self {
            case .day: return "Day"
            case .goodTillCancelled: return "GTC"
            }
        }
    }

    var state: State {
        get { State(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }

    var isOpen: Bool { state == .open }

    /// Whether the market has reached this order.
    ///
    /// Limits and stops wait on opposite sides: a buy limit fills at or below its price,
    /// a buy stop at or above it.
    func wouldFill(at price: Double) -> Bool {
        if kind.isStop {
            return isBuy ? price >= limitPrice : price <= limitPrice
        }
        return isBuy ? price <= limitPrice : price >= limitPrice
    }

    /// Moves a trailing stop's trigger in the favourable direction only.
    ///
    /// A trail follows the price up (for a sell) and never gives ground — that ratchet is
    /// the whole point: it locks in gains without capping them.
    /// - Returns: true when the trigger moved.
    @discardableResult
    func updateTrail(with price: Double) -> Bool {
        guard kind == .trailingStop, let trailPercent, price > 0 else { return false }

        let isNewExtreme = extremePrice.map { isBuy ? price < $0 : price > $0 } ?? true
        guard isNewExtreme else { return false }

        extremePrice = price
        limitPrice = isBuy
            ? price * (1 + trailPercent / 100)
            : price * (1 - trailPercent / 100)
        return true
    }

    func hasExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }

    /// Cash a resting buy ties up, or zero for a sell.
    var reservedCash: Double {
        isBuy ? Double(quantity) * limitPrice : 0
    }

    var conditionDescription: String {
        let base: String
        switch kind {
        case .limit:
            base = "\(isBuy ? "Buy" : "Sell") \(quantity) at \(CurrencyFormatter.rupees(limitPrice)) or better"
        case .stop:
            base = "\(isBuy ? "Buy" : "Sell") \(quantity) if it \(isBuy ? "rises" : "falls") to \(CurrencyFormatter.rupees(limitPrice))"
        case .trailingStop:
            let trail = trailPercent.map { String(format: "%.1f%%", $0) } ?? ""
            base = "\(isBuy ? "Buy" : "Sell") \(quantity), trailing \(trail) · now \(CurrencyFormatter.rupees(limitPrice))"
        }
        return expiresAt == nil ? base : base + " · today"
    }
}


/// What happened when an order was executed.
enum FillOutcome: Equatable {
    case filled(price: Double)
    case failed(reason: String)
}

@MainActor
enum LimitOrderService {

    /// Places a limit order, or executes it immediately if it is already marketable.
    ///
    /// A marketable limit — a buy priced at or above the market, a sell at or below — is
    /// a real instrument, not a mistake: it executes now but caps the worst price you
    /// can get, which a market order does not. Returns a message on failure.
    @discardableResult
    static func submit(
        symbol: String,
        companyName: String,
        isBuy: Bool,
        quantity: Int,
        limitPrice: Double,
        marketPrice: Double,
        kind: LimitOrder.Kind = .limit,
        trailPercent: Double? = nil,
        thesis: String,
        timeInForce: LimitOrder.TimeInForce,
        holding: PortfolioHolding?,
        modelContext: ModelContext
    ) async -> String? {

        // Only a limit can already be marketable. A stop placed on the correct side of
        // the market is by definition not yet reached.
        let isMarketable = kind == .limit && (isBuy ? limitPrice >= marketPrice : limitPrice <= marketPrice)

        if isMarketable {
            guard MarketSession.isOpen() else {
                return "The market is closed. This order would execute immediately, so it can only be placed during trading hours (9:15am–3:30pm IST, Mon–Fri)."
            }

            // Fill at the market, capped by the limit — the price improvement a real
            // marketable order would receive.
            let fillPrice = isBuy ? min(marketPrice, limitPrice) : max(marketPrice, limitPrice)
            return await executeImmediately(
                symbol: symbol,
                companyName: companyName,
                isBuy: isBuy,
                quantity: quantity,
                price: fillPrice,
                thesis: thesis,
                holding: holding,
                modelContext: modelContext
            )
        }

        let order = LimitOrder(
            symbol: symbol,
            companyName: companyName,
            isBuy: isBuy,
            quantity: quantity,
            limitPrice: limitPrice,
            kind: kind,
            trailPercent: trailPercent,
            thesis: thesis,
            expiresAt: timeInForce == .day ? MarketSession.nextClose() : nil
        )

        // A trail starts from where the market is now, so it can only ever ratchet from
        // a real observation rather than from wherever the first check happens to land.
        if kind == .trailingStop {
            order.updateTrail(with: marketPrice)
        }

        modelContext.insert(order)
        try? modelContext.save()
        return nil
    }

    private static func executeImmediately(
        symbol: String,
        companyName: String,
        isBuy: Bool,
        quantity: Int,
        price: Double,
        thesis: String,
        holding: PortfolioHolding?,
        modelContext: ModelContext
    ) async -> String? {
        do {
            if isBuy {
                try await PortfolioManager.shared.addStock(
                    symbol: symbol,
                    companyName: companyName,
                    quantity: quantity,
                    buyPrice: price,
                    thesis: thesis,
                    modelContext: modelContext
                )
            } else {
                guard let holding else {
                    return "You no longer hold \(symbol)."
                }
                holding.currentPrice = price
                try PortfolioManager.shared.sellStock(
                    holding,
                    quantity: quantity,
                    thesis: thesis,
                    modelContext: modelContext
                )
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func cancel(_ order: LimitOrder, modelContext: ModelContext) {
        guard order.isOpen else { return }
        order.state = .cancelled
        try? modelContext.save()
    }

    /// Prices every open order and executes the ones the market has reached.
    ///
    /// The clock, the quote source and the portfolio are injectable so this can be
    /// exercised without the network and without only passing during trading hours.
    static func checkAll(
        modelContext: ModelContext,
        manager: PortfolioManager? = nil,
        now: Date = Date(),
        quoteSource: ((Set<String>) async -> [String: Double])? = nil
    ) async {
        // Resolved here rather than as a default argument: those evaluate outside the
        // actor, and `shared` is main-actor isolated.
        let manager = manager ?? .shared

        var open = ((try? modelContext.fetch(FetchDescriptor<LimitOrder>())) ?? [])
            .filter(\.isOpen)
        guard !open.isEmpty else { return }

        // Retire day orders that outlived their session, whether or not the market is
        // open now — an expired order must not linger and fill days later.
        let expired = open.filter { $0.hasExpired(at: now) }
        if !expired.isEmpty {
            for order in expired { order.state = .expired }
            try? modelContext.save()
            open.removeAll { $0.hasExpired(at: now) }
        }

        // Fills are transactions and only happen inside a session. Yahoo serves the last
        // close outside hours, which would otherwise execute orders overnight.
        guard MarketSession.isOpen(at: now), !open.isEmpty else { return }

        let symbols = Set(open.map(\.symbol))
        let quotes = await (quoteSource ?? liveQuotes)(symbols)

        // Trails move before anything is judged: a stop that has ratcheted up this tick
        // must be evaluated against its new trigger, not the one it was placed with.
        var trailMoved = false
        for order in open where order.kind == .trailingStop {
            if let price = quotes[order.symbol], order.updateTrail(with: price) {
                trailMoved = true
            }
        }
        if trailMoved { try? modelContext.save() }

        for order in open {
            guard let price = quotes[order.symbol], order.wouldFill(at: price) else { continue }
            let outcome = await execute(order, at: price, manager: manager, modelContext: modelContext)
            await notify(order: order, outcome: outcome)
        }
    }

    private static func liveQuotes(_ symbols: Set<String>) async -> [String: Double] {
        await withTaskGroup(of: (String, Double?).self) { group in
            for symbol in symbols {
                group.addTask {
                    (symbol, try? await MarketAPIService.shared.fetchStockPrice(symbol: symbol))
                }
            }
            var collected: [String: Double] = [:]
            for await (symbol, price) in group {
                if let price { collected[symbol] = price }
            }
            return collected
        }
    }

    /// Fills at the **limit price**, not the price we happened to observe.
    ///
    /// Prices are sampled periodically, so by the time an order is seen as fillable the
    /// market may have run well past the limit. A real order would have executed as the
    /// price crossed — filling at the limit avoids handing the user a better price than
    /// they could actually have got.
    @discardableResult
    /// - Parameter marketPrice: the quote that triggered the order, if there was one.
    static func execute(
        _ order: LimitOrder,
        at marketPrice: Double? = nil,
        manager: PortfolioManager? = nil,
        modelContext: ModelContext
    ) async -> FillOutcome {
        let manager = manager ?? .shared

        // A limit fills at its limit; a stop becomes a market order the moment it
        // triggers, so it fills at whatever the market is — which can be worse than the
        // stop. Pretending otherwise would teach that a stop guarantees a price, and the
        // gap between the two is exactly what a stop costs you.
        let fillPrice = order.kind.isStop ? (marketPrice ?? order.limitPrice) : order.limitPrice

        do {
            if order.isBuy {
                try await manager.addStock(
                    symbol: order.symbol,
                    companyName: order.companyName,
                    quantity: order.quantity,
                    buyPrice: fillPrice,
                    thesis: order.thesis,
                    modelContext: modelContext
                )
            } else {
                guard let holding = holding(for: order.symbol, modelContext: modelContext) else {
                    throw PortfolioError.insufficientShares(requested: order.quantity, available: 0)
                }
                // Mark at the fill price so the booked P&L reflects what the order
                // actually got, not the stale mark on the holding.
                holding.currentPrice = fillPrice
                try manager.sellStock(
                    holding,
                    quantity: order.quantity,
                    thesis: order.thesis,
                    modelContext: modelContext
                )
            }

            order.state = .filled
            order.filledAt = Date()
            order.filledPrice = fillPrice
            try? modelContext.save()
            return .filled(price: fillPrice)

        } catch {
            // Conditions can change between placing and filling — the cash may be spent
            // or the shares already sold. The order fails rather than silently vanishing.
            order.state = .failed
            order.failureReason = error.localizedDescription
            try? modelContext.save()
            return .failed(reason: error.localizedDescription)
        }
    }

    private static func holding(for symbol: String, modelContext: ModelContext) -> PortfolioHolding? {
        let descriptor = FetchDescriptor<PortfolioHolding>(
            predicate: #Predicate { $0.symbol == symbol }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private static func notify(order: LimitOrder, outcome: FillOutcome) async {
        let content = UNMutableNotificationContent()
        if case .filled = outcome {
            content.title = "\(order.isBuy ? "Bought" : "Sold") \(order.quantity) \(order.symbol)"
            content.body = "Your limit order filled at \(CurrencyFormatter.rupees(order.limitPrice))."
        } else {
            content.title = "\(order.symbol) order didn't fill"
            content.body = order.failureReason ?? "The order could not be completed."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: order.id.uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
