//
//  Trade.swift
//  TradeX
//

import Foundation
import SwiftData

/// An immutable record of a single executed order.
///
/// Holdings only describe what you own *now* — `avgBuyPrice` is overwritten on every
/// top-up and the whole row disappears on a sell. This is the app's memory: it is
/// written once when an order fills and never edited afterwards.
@Model
final class Trade {
    @Attribute(.unique) var id: UUID
    var symbol: String
    var companyName: String
    var isBuy: Bool
    var quantity: Int
    var price: Double
    var timestamp: Date

    /// Why the trade was made. Captured in a later pass — the column exists now so
    /// adding the input field won't require a schema migration.
    var thesis: String

    /// Profit or loss booked by this trade. Set on sells, `nil` on buys (a buy opens
    /// exposure, it doesn't realise anything).
    var realizedPnL: Double?

    init(
        id: UUID = UUID(),
        symbol: String,
        companyName: String,
        isBuy: Bool,
        quantity: Int,
        price: Double,
        timestamp: Date = Date(),
        thesis: String = "",
        realizedPnL: Double? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.companyName = companyName
        self.isBuy = isBuy
        self.quantity = quantity
        self.price = price
        self.timestamp = timestamp
        self.thesis = thesis
        self.realizedPnL = realizedPnL
    }

    /// Cash that moved: what the buy cost, or what the sell returned.
    var totalValue: Double {
        Double(quantity) * price
    }

    var isClosingTrade: Bool {
        realizedPnL != nil
    }

    var isProfitable: Bool {
        (realizedPnL ?? 0) >= 0
    }
}

/// Money added to or removed from the account by hand, rather than by trading.
///
/// Without this, editing the cash balance on the Dashboard silently inflates net
/// worth and every return percentage computed from it becomes meaningless. Recording
/// the deltas means performance can be measured against what was actually put in.
@Model
final class CashAdjustment {
    @Attribute(.unique) var id: UUID

    /// Signed delta. Positive is a deposit, negative a withdrawal.
    var amount: Double
    var balanceAfter: Double
    var timestamp: Date
    var note: String

    init(
        id: UUID = UUID(),
        amount: Double,
        balanceAfter: Double,
        timestamp: Date = Date(),
        note: String = ""
    ) {
        self.id = id
        self.amount = amount
        self.balanceAfter = balanceAfter
        self.timestamp = timestamp
        self.note = note
    }

    var isDeposit: Bool { amount >= 0 }
}

/// A daily mark of what the account was worth, alongside the benchmark level that day.
///
/// `netDeposits` is stored with each mark so performance can be measured time-weighted:
/// without it, paying money in looks identical to making money.
@Model
final class PortfolioSnapshot {
    @Attribute(.unique) var id: UUID

    /// Normalised to the start of the day — one mark per calendar day.
    var day: Date
    var netWorth: Double
    var netDeposits: Double
    var niftyLevel: Double?

    /// True when derived from the trade ledger rather than observed live. A rebuild
    /// replaces its own past output but never overwrites a mark taken from real prices.
    var isReconstructed: Bool = false

    init(
        id: UUID = UUID(),
        day: Date,
        netWorth: Double,
        netDeposits: Double,
        niftyLevel: Double? = nil,
        isReconstructed: Bool = false
    ) {
        self.id = id
        self.day = day
        self.netWorth = netWorth
        self.netDeposits = netDeposits
        self.niftyLevel = niftyLevel
        self.isReconstructed = isReconstructed
    }
}
