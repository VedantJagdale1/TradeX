//
//  MarketSessionTests.swift
//  TradeXTests
//

import Foundation
import Testing
@testable import TradeX

/// Fills are gated on these, so an off-by-one minute means orders execute outside a
/// session — or stop executing inside one.
struct MarketSessionTests {

    private func ist(_ stamp: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = MarketSession.exchangeTimeZone
        return try #require(formatter.date(from: stamp))
    }

    @Test("The session runs 09:15 to 15:30 inclusive")
    func sessionBoundaries() throws {
        #expect(MarketSession.isOpen(at: try ist("2026-09-04 09:14")) == false)
        #expect(MarketSession.isOpen(at: try ist("2026-09-04 09:15")) == true)
        #expect(MarketSession.isOpen(at: try ist("2026-09-04 12:00")) == true)
        #expect(MarketSession.isOpen(at: try ist("2026-09-04 15:30")) == true)
        #expect(MarketSession.isOpen(at: try ist("2026-09-04 15:31")) == false)
    }

    @Test("Overnight is closed, which is when a stale close would otherwise fill orders")
    func overnightIsClosed() throws {
        #expect(MarketSession.isOpen(at: try ist("2026-09-04 02:00")) == false)
        #expect(MarketSession.isOpen(at: try ist("2026-09-04 23:59")) == false)
    }

    @Test("Weekends are closed")
    func weekendsAreClosed() throws {
        #expect(MarketSession.isOpen(at: try ist("2026-09-05 11:00")) == false)  // Saturday
        #expect(MarketSession.isOpen(at: try ist("2026-09-06 11:00")) == false)  // Sunday
        #expect(MarketSession.isOpen(at: try ist("2026-09-07 11:00")) == true)   // Monday
    }

    @Test("A day order placed intraday expires at that day's close")
    func dayOrderExpiresToday() throws {
        let close = MarketSession.nextClose(after: try ist("2026-09-04 10:00"))
        #expect(close == (try ist("2026-09-04 15:30")))
    }

    @Test("After Friday's close, the next close is Monday — never the weekend")
    func expiryRollsPastTheWeekend() throws {
        let fromFridayEvening = MarketSession.nextClose(after: try ist("2026-09-04 16:00"))
        let fromSaturday = MarketSession.nextClose(after: try ist("2026-09-05 11:00"))
        let monday = try ist("2026-09-07 15:30")

        #expect(fromFridayEvening == monday)
        #expect(fromSaturday == monday)
    }
}
