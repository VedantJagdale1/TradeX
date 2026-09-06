//
//  SectorAndHolidayTests.swift
//  TradeXTests
//

import Foundation
import SwiftData
import Testing
@testable import TradeX

struct HolidayCalendarTests {

    private func ist(_ stamp: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = MarketSession.exchangeTimeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return try #require(formatter.date(from: stamp))
    }

    @Test("The exchange is shut on a published holiday, mid-session or not")
    func holidaysAreClosed() throws {
        // Independence Day 2026 — a Saturday anyway, so use one that falls midweek.
        #expect(MarketSession.isOpen(at: try ist("2026-10-02 11:00")) == false)  // Gandhi Jayanti, Friday
        #expect(MarketSession.isOpen(at: try ist("2026-12-25 11:00")) == false)  // Christmas, Friday
        #expect(MarketSession.isOpen(at: try ist("2026-01-26 11:00")) == false)  // Republic Day, Monday
    }

    @Test("An ordinary weekday is still open")
    func ordinaryDaysAreOpen() throws {
        #expect(MarketSession.isOpen(at: try ist("2026-09-07 11:00")) == true)
        #expect(MarketSession.isOpen(at: try ist("2026-12-24 11:00")) == true)
    }

    @Test("A day order placed before a holiday expires at the next real session")
    func expirySkipsHolidays() throws {
        // Christmas 2026 is a Friday; the next session is Monday the 28th.
        let close = MarketSession.nextClose(after: try ist("2026-12-24 16:00"))
        #expect(close == (try ist("2026-12-28 15:30")))
    }

    @Test("Trading days exclude both weekends and holidays")
    func tradingDayClassification() throws {
        #expect(MarketSession.isTradingDay(try ist("2026-09-07 11:00")) == true)   // Monday
        #expect(MarketSession.isTradingDay(try ist("2026-09-05 11:00")) == false)  // Saturday
        #expect(MarketSession.isTradingDay(try ist("2026-10-02 11:00")) == false)  // holiday
    }
}


struct SectorTests {

    @Test("Known symbols resolve to their sector")
    func knownSymbols() {
        #expect(Sector.forSymbol("RELIANCE") == .energy)
        #expect(Sector.forSymbol("TCS") == .informationTechnology)
        #expect(Sector.forSymbol("HDFCBANK") == .financials)
        #expect(Sector.forSymbol("TMCV") == .automotive)
        #expect(Sector.forSymbol("SUNPHARMA") == .healthcare)
    }

    @Test("An unmapped symbol is reported as unclassified, not guessed at")
    func unknownSymbolIsHonest() {
        // A wrong sector is worse than an absent one when measuring concentration.
        #expect(Sector.forSymbol("SOMETHINGOBSCURE") == .unclassified)
    }

    @Test("Lookup is case-insensitive")
    func caseInsensitive() {
        #expect(Sector.forSymbol("reliance") == .energy)
    }

    @Test("Both Tata Motors successors map to automotive")
    func demergedSymbolsMapped() {
        #expect(Sector.forSymbol("TMCV") == .automotive)
        #expect(Sector.forSymbol("TMPV") == .automotive)
    }

    @Test("Symbols containing an ampersand resolve")
    func ampersandSymbols() {
        #expect(Sector.forSymbol("M&M") == .automotive)
        #expect(Sector.forSymbol("M&MFIN") == .financials)
    }
}


@MainActor
struct SectorAllocationTests {

    private func holding(_ symbol: String, quantity: Int, price: Double) -> PortfolioHolding {
        PortfolioHolding(symbol: symbol, companyName: symbol, quantity: quantity,
                         avgBuyPrice: price, currentPrice: price)
    }

    @Test("Holdings in one sector are summed together")
    func sectorsAggregate() {
        let breakdown = SectorAllocation.breakdown(of: [
            holding("TCS", quantity: 10, price: 100),
            holding("INFY", quantity: 10, price: 100),
            holding("RELIANCE", quantity: 10, price: 100),
        ])

        let it = try? #require(breakdown.first { $0.sector == .informationTechnology })
        #expect(it?.value == 2_000)
        #expect(it?.symbols == ["INFY", "TCS"])
        #expect(breakdown.count == 2)
    }

    @Test("The largest exposure comes first, which is the one worth seeing")
    func sortedByValue() {
        let breakdown = SectorAllocation.breakdown(of: [
            holding("RELIANCE", quantity: 1, price: 100),
            holding("TCS", quantity: 10, price: 100),
        ])
        #expect(breakdown.first?.sector == .informationTechnology)
    }

    @Test("Shares are a percentage of the total, not of anything else")
    func sharesArePercentages() {
        let holdings = [
            holding("TCS", quantity: 3, price: 100),        // 300
            holding("RELIANCE", quantity: 1, price: 100),   // 100
        ]
        let total = holdings.reduce(0.0) { $0 + $1.currentValue }
        let breakdown = SectorAllocation.breakdown(of: holdings)

        #expect(abs((breakdown.first?.share(of: total) ?? 0) - 75) < 0.001)
        #expect(abs(breakdown.reduce(0) { $0 + $1.share(of: total) } - 100) < 0.001)
    }

    @Test("An empty portfolio has no exposure and doesn't divide by zero")
    func emptyPortfolio() {
        let breakdown = SectorAllocation.breakdown(of: [])
        #expect(breakdown.isEmpty)
        #expect(SectorAllocation(sector: .energy, value: 0, symbols: []).share(of: 0) == 0)
    }

    @Test("Unmapped holdings collect in their own bucket rather than skewing a real one")
    func unclassifiedIsSeparate() {
        let breakdown = SectorAllocation.breakdown(of: [
            holding("TCS", quantity: 1, price: 100),
            holding("OBSCURECO", quantity: 1, price: 100),
        ])
        #expect(breakdown.contains { $0.sector == .unclassified })
        #expect(breakdown.first { $0.sector == .informationTechnology }?.value == 100)
    }
}
