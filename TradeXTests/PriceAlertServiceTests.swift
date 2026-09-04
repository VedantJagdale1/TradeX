//
//  PriceAlertServiceTests.swift
//  TradeXTests
//

import Foundation
import SwiftData
import Testing
@testable import TradeX

@MainActor
private struct AlertBook {
    let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: PortfolioHolding.self, UserSettings.self, Trade.self,
            CashAdjustment.self, PortfolioSnapshot.self, WatchlistItem.self,
            PriceAlert.self, LimitOrder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    static let checkedAt = Date(timeIntervalSince1970: 1_780_000_000)

    @discardableResult
    func alert(_ symbol: String, target: Double, isAbove: Bool, enabled: Bool = true) -> PriceAlert {
        let alert = PriceAlert(symbol: symbol, companyName: symbol,
                               targetPrice: target, isAbove: isAbove, isEnabled: enabled)
        context.insert(alert)
        try? context.save()
        return alert
    }

    func check(_ quotes: [String: Double]) async -> [PriceAlert] {
        await PriceAlertService.checkAll(
            modelContext: context,
            now: Self.checkedAt,
            quoteSource: { _ in quotes }
        )
    }
}


@MainActor
struct PriceAlertTriggerTests {

    @Test("A rise alert fires once its price is reached")
    func riseAlertFires() async throws {
        let book = try AlertBook()
        let alert = book.alert("INFY", target: 1_200, isAbove: true)

        let fired = await book.check(["INFY": 1_250])

        #expect(fired.count == 1)
        #expect(alert.isTriggered == true)
        #expect(alert.isArmed == false)
        #expect(alert.triggeredAt == AlertBook.checkedAt)
    }

    @Test("A fall alert fires once its price is reached")
    func fallAlertFires() async throws {
        let book = try AlertBook()
        let alert = book.alert("INFY", target: 1_000, isAbove: false)

        _ = await book.check(["INFY": 950])

        #expect(alert.isTriggered == true)
    }

    @Test("The alert reports the price seen, not the target it was set at")
    func recordsTheObservedPrice() async throws {
        let book = try AlertBook()
        let alert = book.alert("RELIANCE", target: 1_300, isAbove: true)

        // Deliberately unlike a limit order, which fills at its limit. An alert is
        // telling you what the market actually did.
        _ = await book.check(["RELIANCE": 1_355])

        #expect(alert.triggeredPrice == 1_355)
        #expect(alert.targetPrice == 1_300)
    }

    @Test("An alert whose price hasn't been reached stays armed")
    func unreachedAlertStaysArmed() async throws {
        let book = try AlertBook()
        let alert = book.alert("INFY", target: 1_200, isAbove: true)

        let fired = await book.check(["INFY": 1_150])

        #expect(fired.isEmpty)
        #expect(alert.isArmed == true)
        #expect(alert.triggeredAt == nil)
    }

    @Test("Reaching the target exactly counts as reaching it")
    func exactTargetCounts() async throws {
        let book = try AlertBook()
        let rise = book.alert("A", target: 100, isAbove: true)
        let fall = book.alert("B", target: 200, isAbove: false)

        _ = await book.check(["A": 100, "B": 200])

        #expect(rise.isTriggered == true)
        #expect(fall.isTriggered == true)
    }

    @Test("An alert fires once and is not re-triggered by later checks")
    func firesOnlyOnce() async throws {
        let book = try AlertBook()
        let alert = book.alert("INFY", target: 1_200, isAbove: true)

        _ = await book.check(["INFY": 1_250])
        let firstTrigger = alert.triggeredPrice

        let second = await book.check(["INFY": 1_400])

        #expect(second.isEmpty)
        #expect(alert.triggeredPrice == firstTrigger)   // not overwritten
    }

    @Test("A disabled alert is not checked")
    func disabledAlertIsSkipped() async throws {
        let book = try AlertBook()
        let alert = book.alert("INFY", target: 1_200, isAbove: true, enabled: false)

        let fired = await book.check(["INFY": 1_250])

        #expect(fired.isEmpty)
        #expect(alert.isTriggered == false)
    }

    @Test("A missing quote leaves the alert armed rather than firing wrongly")
    func missingQuoteDoesNotFire() async throws {
        let book = try AlertBook()
        let alert = book.alert("INFY", target: 1_200, isAbove: true)

        let fired = await book.check([:])

        #expect(fired.isEmpty)
        #expect(alert.isArmed == true)
    }

    @Test("Several alerts on one symbol are each judged on their own terms")
    func multipleAlertsOnOneSymbol() async throws {
        let book = try AlertBook()
        let near = book.alert("TCS", target: 2_300, isAbove: true)
        let far = book.alert("TCS", target: 2_600, isAbove: true)
        let below = book.alert("TCS", target: 2_000, isAbove: false)

        let fired = await book.check(["TCS": 2_400])

        #expect(fired.count == 1)
        #expect(near.isTriggered == true)
        #expect(far.isArmed == true)
        #expect(below.isArmed == true)
    }

    @Test("Alerts fire out of hours, unlike order fills")
    func firesOutsideMarketHours() async throws {
        let book = try AlertBook()
        let alert = book.alert("INFY", target: 1_200, isAbove: true)

        // A Sunday. An order would be gated here; an alert is information, and the fact
        // that the price was reached does not stop being true after the close.
        let sunday = Date(timeIntervalSince1970: 1_780_000_000)
        _ = await PriceAlertService.checkAll(
            modelContext: book.context,
            now: sunday,
            quoteSource: { _ in ["INFY": 1_250] }
        )

        #expect(alert.isTriggered == true)
    }

    @Test("With nothing armed, no quotes are requested at all")
    func noArmedAlertsMeansNoFetch() async throws {
        let book = try AlertBook()
        book.alert("INFY", target: 1_200, isAbove: true, enabled: false)

        var asked = false
        let fired = await PriceAlertService.checkAll(
            modelContext: book.context,
            now: AlertBook.checkedAt,
            quoteSource: { _ in asked = true; return [:] }
        )

        #expect(fired.isEmpty)
        #expect(asked == false)
    }

    @Test("Only the symbols actually needed are requested")
    func asksOnlyForArmedSymbols() async throws {
        let book = try AlertBook()
        book.alert("INFY", target: 1_200, isAbove: true)
        book.alert("TCS", target: 2_300, isAbove: true, enabled: false)

        var requested: Set<String> = []
        _ = await PriceAlertService.checkAll(
            modelContext: book.context,
            now: AlertBook.checkedAt,
            quoteSource: { symbols in requested = symbols; return [:] }
        )

        #expect(requested == ["INFY"])
    }
}
