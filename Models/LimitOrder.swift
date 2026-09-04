//
//  LimitOrder.swift
//  TradeX
//

import Foundation
import SwiftData
import UserNotifications

/// A resting order that executes when the market reaches a chosen price.
///
/// Note the direction convention is the market's, and is the opposite of a price
/// alert's: a *buy* limit rests **below** the current price (buy no worse than X), a
/// *sell* limit rests **above** it (sell no worse than X).
@Model
final class LimitOrder {
    @Attribute(.unique) var id: UUID
    var symbol: String
    var companyName: String
    var isBuy: Bool
    var quantity: Int
    var limitPrice: Double
    var thesis: String

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
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    enum State: String {
        case open, filled, cancelled, failed, expired
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

    /// A buy fills at or below its limit; a sell at or above.
    func wouldFill(at price: Double) -> Bool {
        isBuy ? price <= limitPrice : price >= limitPrice
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
        let base = "\(isBuy ? "Buy" : "Sell") \(quantity) at \(CurrencyFormatter.rupees(limitPrice)) or better"
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
        thesis: String,
        timeInForce: LimitOrder.TimeInForce,
        holding: PortfolioHolding?,
        modelContext: ModelContext
    ) async -> String? {

        let isMarketable = isBuy ? limitPrice >= marketPrice : limitPrice <= marketPrice

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

        modelContext.insert(
            LimitOrder(
                symbol: symbol,
                companyName: companyName,
                isBuy: isBuy,
                quantity: quantity,
                limitPrice: limitPrice,
                thesis: thesis,
                expiresAt: timeInForce == .day ? MarketSession.nextClose() : nil
            )
        )
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

        for order in open {
            guard let price = quotes[order.symbol], order.wouldFill(at: price) else { continue }
            let outcome = await execute(order, manager: manager, modelContext: modelContext)
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
    static func execute(
        _ order: LimitOrder,
        manager: PortfolioManager? = nil,
        modelContext: ModelContext
    ) async -> FillOutcome {
        let manager = manager ?? .shared

        do {
            if order.isBuy {
                try await manager.addStock(
                    symbol: order.symbol,
                    companyName: order.companyName,
                    quantity: order.quantity,
                    buyPrice: order.limitPrice,
                    thesis: order.thesis,
                    modelContext: modelContext
                )
            } else {
                guard let holding = holding(for: order.symbol, modelContext: modelContext) else {
                    throw PortfolioError.insufficientShares(requested: order.quantity, available: 0)
                }
                // Sell at the limit rather than the stored mark, so the booked P&L
                // reflects the price the order actually rested at.
                holding.currentPrice = order.limitPrice
                try manager.sellStock(
                    holding,
                    quantity: order.quantity,
                    thesis: order.thesis,
                    modelContext: modelContext
                )
            }

            order.state = .filled
            order.filledAt = Date()
            order.filledPrice = order.limitPrice
            try? modelContext.save()
            return .filled(price: order.limitPrice)

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
