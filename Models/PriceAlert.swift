//
//  PriceAlert.swift
//  TradeX
//

import Foundation
import SwiftData
import UserNotifications

/// A target price to be told about.
///
/// Alerts fire once and then stay in the list as triggered, rather than deleting
/// themselves — the record of "I said I'd act at ₹1,250" is worth keeping alongside the
/// trade journal.
@Model
final class PriceAlert {
    @Attribute(.unique) var id: UUID
    var symbol: String
    var companyName: String
    var targetPrice: Double

    /// True fires when the price rises to the target, false when it falls to it.
    var isAbove: Bool

    var isEnabled: Bool
    var createdAt: Date
    var triggeredAt: Date?
    var triggeredPrice: Double?

    init(
        id: UUID = UUID(),
        symbol: String,
        companyName: String,
        targetPrice: Double,
        isAbove: Bool,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.symbol = symbol
        self.companyName = companyName
        self.targetPrice = targetPrice
        self.isAbove = isAbove
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    var isTriggered: Bool { triggeredAt != nil }

    /// Only untriggered, enabled alerts are worth spending a network request on.
    var isArmed: Bool { isEnabled && !isTriggered }

    var conditionDescription: String {
        "\(isAbove ? "Rises to" : "Falls to") \(CurrencyFormatter.rupees(targetPrice))"
    }

    func hasMet(price: Double) -> Bool {
        isAbove ? price >= targetPrice : price <= targetPrice
    }
}


@MainActor
enum PriceAlertService {

    static let backgroundTaskID = "vedant.TradeX.priceCheck"

    /// Asked for when the first alert is created, rather than at launch — the request
    /// makes sense to the user at the moment it becomes relevant.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    /// Prices every armed alert and delivers a notification for any that have been met.
    ///
    /// Safe to call from the foreground or a background refresh; symbols are fetched
    /// concurrently and each alert fires at most once. The clock and quote source are
    /// injectable so this can be exercised without the network.
    ///
    /// Unlike an order fill, this is deliberately *not* gated on market hours: an alert
    /// is information, and "it reached your price" stays true after the close.
    /// - Returns: the alerts that fired.
    @discardableResult
    static func checkAll(
        modelContext: ModelContext,
        now: Date = Date(),
        quoteSource: ((Set<String>) async -> [String: Double])? = nil
    ) async -> [PriceAlert] {
        let armed = ((try? modelContext.fetch(FetchDescriptor<PriceAlert>())) ?? [])
            .filter(\.isArmed)
        guard !armed.isEmpty else { return [] }

        let symbols = Set(armed.map(\.symbol))
        let quotes = await (quoteSource ?? liveQuotes)(symbols)

        var fired: [PriceAlert] = []
        for alert in armed {
            guard let price = quotes[alert.symbol], alert.hasMet(price: price) else { continue }

            alert.triggeredAt = now
            // The price actually seen, not the target — unlike a limit order, which
            // fills at its limit. What the alert reports is what the market did.
            alert.triggeredPrice = price
            fired.append(alert)
        }

        guard !fired.isEmpty else { return [] }

        try? modelContext.save()
        for alert in fired {
            await deliver(alert: alert, price: alert.triggeredPrice ?? alert.targetPrice)
        }
        return fired
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

    private static func deliver(alert: PriceAlert, price: Double) async {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.symbol) \(alert.isAbove ? "rose to" : "fell to") \(CurrencyFormatter.rupees(price))"
        content.body = "Your alert was set at \(CurrencyFormatter.rupees(alert.targetPrice)). \(alert.companyName)"
        content.sound = .default

        // nil trigger delivers immediately.
        let request = UNNotificationRequest(
            identifier: alert.id.uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
