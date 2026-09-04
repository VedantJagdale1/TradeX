//
//  WatchlistItem.swift
//  TradeX
//

import Foundation
import SwiftData

/// A stock being followed without a position in it.
///
/// `symbol` is the unique attribute rather than a UUID: the same stock must never be
/// watchable twice, and the symbol is what identifies it everywhere else in the app.
@Model
final class WatchlistItem {
    @Attribute(.unique) var symbol: String
    var companyName: String
    var addedAt: Date

    init(symbol: String, companyName: String, addedAt: Date = Date()) {
        self.symbol = symbol
        self.companyName = companyName
        self.addedAt = addedAt
    }
}

@MainActor
enum Watchlist {
    static func contains(_ symbol: String, in modelContext: ModelContext) -> Bool {
        item(for: symbol, in: modelContext) != nil
    }

    /// Adds or removes, returning the state afterwards so callers can drive a toggle.
    @discardableResult
    static func toggle(symbol: String, companyName: String, in modelContext: ModelContext) -> Bool {
        if let existing = item(for: symbol, in: modelContext) {
            modelContext.delete(existing)
            try? modelContext.save()
            return false
        }

        modelContext.insert(WatchlistItem(symbol: symbol, companyName: companyName))
        try? modelContext.save()
        return true
    }

    static func remove(symbol: String, in modelContext: ModelContext) {
        guard let existing = item(for: symbol, in: modelContext) else { return }
        modelContext.delete(existing)
        try? modelContext.save()
    }

    private static func item(for symbol: String, in modelContext: ModelContext) -> WatchlistItem? {
        let descriptor = FetchDescriptor<WatchlistItem>(
            predicate: #Predicate { $0.symbol == symbol }
        )
        return try? modelContext.fetch(descriptor).first
    }
}
