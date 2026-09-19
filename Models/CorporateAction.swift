//
//  CorporateAction.swift
//  TradeX
//

import Foundation
import SwiftData

/// A split or bonus issue that has been applied to the portfolio.
///
/// Recorded so an action is applied exactly once. Reapplying a 2:1 would double the
/// share count a second time and halve the cost basis again — silently inventing a
/// position that never existed.
@Model
final class CorporateAction {
    @Attribute(.unique) var id: String
    var symbol: String
    var effectiveDate: Date
    var numerator: Double
    var denominator: Double
    var appliedAt: Date

    /// Shares before the adjustment, kept so the change is auditable.
    var quantityBefore: Int
    var quantityAfter: Int
    var averageCostBefore: Double
    var averageCostAfter: Double

    init(
        symbol: String,
        effectiveDate: Date,
        numerator: Double,
        denominator: Double,
        quantityBefore: Int,
        quantityAfter: Int,
        averageCostBefore: Double,
        averageCostAfter: Double,
        appliedAt: Date = Date()
    ) {
        // Symbol plus effective day identifies an action; a stock can't split twice in
        // a day, and this is what makes reapplication impossible.
        self.id = CorporateAction.identifier(symbol: symbol, date: effectiveDate)
        self.symbol = symbol
        self.effectiveDate = effectiveDate
        self.numerator = numerator
        self.denominator = denominator
        self.quantityBefore = quantityBefore
        self.quantityAfter = quantityAfter
        self.averageCostBefore = averageCostBefore
        self.averageCostAfter = averageCostAfter
        self.appliedAt = appliedAt
    }

    static func identifier(symbol: String, date: Date) -> String {
        let day = Int(date.timeIntervalSince1970 / 86_400)
        return "\(symbol)@\(day)"
    }

    var ratioDescription: String { "\(Int(numerator)):\(Int(denominator))" }
}


@MainActor
enum CorporateActionService {

    private static let lastScanKey = "TradeX.lastSplitScan"

    /// Applies any split the portfolio hasn't seen yet.
    ///
    /// Holdings store an absolute rupee cost basis, but quotes come back adjusted for
    /// splits. Left alone, a 2:1 halves the price overnight while the cost basis stays
    /// put — the position reads as a 50% loss that never happened, and that error is
    /// then booked for real the moment it is sold.
    /// - Returns: the actions applied.
    @discardableResult
    static func apply(
        modelContext: ModelContext,
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        splitSource: ((String) async -> [SplitEvent])? = nil
    ) async -> [CorporateAction] {

        let holdings = (try? modelContext.fetch(FetchDescriptor<PortfolioHolding>())) ?? []
        guard !holdings.isEmpty else { return [] }

        let known = Set(((try? modelContext.fetch(FetchDescriptor<CorporateAction>())) ?? []).map(\.id))
        let openDates = positionOpenDates(modelContext: modelContext)
        var applied: [CorporateAction] = []

        for holding in holdings {
            let splits: [SplitEvent]
            if let splitSource {
                splits = await splitSource(holding.symbol)
            } else {
                splits = (try? await MarketAPIService.shared.fetchSplits(symbol: holding.symbol)) ?? []
            }

            // A split from before the position existed is already in the price that was
            // paid for it. Reapplying it doubles the shares and halves a cost basis that
            // was never pre-split — inventing a gain out of an accounting event.
            let openedAt = openDates[holding.symbol] ?? now

            for split in splits where split.date > openedAt {
                let id = CorporateAction.identifier(symbol: holding.symbol, date: split.date)
                guard !known.contains(id) else { continue }
                guard let action = adjust(holding, for: split) else { continue }

                modelContext.insert(action)
                applied.append(action)

                adjustRestingOrders(for: holding.symbol, by: split, modelContext: modelContext)
                adjustAlerts(for: holding.symbol, by: split, modelContext: modelContext)
            }
        }

        defaults.set(now, forKey: lastScanKey)
        if !applied.isEmpty { try? modelContext.save() }
        return applied
    }

    /// When each position was opened, from the earliest buy in the ledger.
    ///
    /// A holding with no trade record predates the journal and can't be dated, so the
    /// caller treats it as opened now — only future splits will touch it. Under-applying
    /// is recoverable; corrupting a cost basis is not.
    static func positionOpenDates(modelContext: ModelContext) -> [String: Date] {
        let trades = (try? modelContext.fetch(FetchDescriptor<Trade>())) ?? []
        var earliest: [String: Date] = [:]

        for trade in trades where trade.isBuy {
            if let current = earliest[trade.symbol] {
                earliest[trade.symbol] = min(current, trade.timestamp)
            } else {
                earliest[trade.symbol] = trade.timestamp
            }
        }
        return earliest
    }

    /// Undoes adjustments that should never have been made.
    ///
    /// An earlier build applied every split it could find, including ones predating the
    /// position. This reverses those, but only where the holding still looks exactly as
    /// the adjustment left it — if it has been traded since, the original numbers are no
    /// longer recoverable and it is left alone rather than guessed at.
    /// - Returns: the symbols repaired.
    @discardableResult
    static func repairMisapplied(modelContext: ModelContext) -> [String] {
        let actions = (try? modelContext.fetch(FetchDescriptor<CorporateAction>())) ?? []
        guard !actions.isEmpty else { return [] }

        let holdings = (try? modelContext.fetch(FetchDescriptor<PortfolioHolding>())) ?? []
        let openDates = positionOpenDates(modelContext: modelContext)
        var repaired: [String] = []

        for action in actions {
            let openedAt = openDates[action.symbol]
            // Only actions that predate the position were wrong.
            guard let openedAt, action.effectiveDate <= openedAt else { continue }

            if let holding = holdings.first(where: { $0.symbol == action.symbol }),
               holding.quantity == action.quantityAfter,
               abs(holding.avgBuyPrice - action.averageCostAfter) < 0.01 {

                holding.quantity = action.quantityBefore
                holding.avgBuyPrice = action.averageCostBefore
                repaired.append(action.symbol)
            }

            // Remove the record either way: it describes something that shouldn't have
            // happened, and leaving it would block the split being applied correctly
            // if it ever legitimately recurs.
            modelContext.delete(action)
        }

        if !actions.isEmpty { try? modelContext.save() }
        return repaired
    }

    /// Splits are rare and the scan costs a request per holding, so it runs daily.
    static func shouldScan(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard let last = defaults.object(forKey: lastScanKey) as? Date else { return true }
        return !Calendar.current.isDate(last, inSameDayAs: now)
    }

    // MARK: - Adjustments

    /// Restates a holding across a split, keeping the money invested unchanged.
    ///
    /// A split changes how many pieces a position is divided into, never what it cost.
    /// Deriving the new average from the preserved total is what keeps that true even
    /// when the new share count has to be rounded.
    static func adjust(_ holding: PortfolioHolding, for split: SplitEvent) -> CorporateAction? {
        let multiplier = split.shareMultiplier
        guard multiplier > 0, multiplier != 1, holding.quantity > 0 else { return nil }

        let totalCost = Double(holding.quantity) * holding.avgBuyPrice
        // A consolidation can round a small position below one share. Real brokers pay
        // out the fraction in cash; keeping a single share is the closest this can get
        // without inventing a cash movement.
        let newQuantity = max(1, Int((Double(holding.quantity) * multiplier).rounded(.down)))
        let newAverage = totalCost / Double(newQuantity)

        let action = CorporateAction(
            symbol: holding.symbol,
            effectiveDate: split.date,
            numerator: split.numerator,
            denominator: split.denominator,
            quantityBefore: holding.quantity,
            quantityAfter: newQuantity,
            averageCostBefore: holding.avgBuyPrice,
            averageCostAfter: newAverage
        )

        holding.quantity = newQuantity
        holding.avgBuyPrice = newAverage
        holding.currentPrice /= multiplier

        return action
    }

    /// A stop set at pre-split levels would trigger the instant the price restates, so
    /// resting orders are moved with the stock rather than left stranded.
    private static func adjustRestingOrders(
        for symbol: String, by split: SplitEvent, modelContext: ModelContext
    ) {
        let orders = ((try? modelContext.fetch(FetchDescriptor<LimitOrder>())) ?? [])
            .filter { $0.isOpen && $0.symbol == symbol }

        for order in orders {
            order.limitPrice /= split.shareMultiplier
            order.quantity = max(1, Int((Double(order.quantity) * split.shareMultiplier).rounded(.down)))
            if let extreme = order.extremePrice {
                order.extremePrice = extreme / split.shareMultiplier
            }
        }
    }

    /// Same for alerts: a target of ₹2,600 on a stock that just halved is not the alert
    /// its owner set.
    private static func adjustAlerts(
        for symbol: String, by split: SplitEvent, modelContext: ModelContext
    ) {
        let alerts = ((try? modelContext.fetch(FetchDescriptor<PriceAlert>())) ?? [])
            .filter { $0.isArmed && $0.symbol == symbol }

        for alert in alerts {
            alert.targetPrice /= split.shareMultiplier
        }
    }
}
