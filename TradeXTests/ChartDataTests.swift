//
//  ChartDataTests.swift
//  TradeXTests
//

import Foundation
import Testing
@testable import TradeX

private func bar(_ day: Int, open: Double? = nil, high: Double? = nil,
                 low: Double? = nil, close: Double, volume: Int? = nil) -> ChartPoint {
    ChartPoint(
        date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
        price: close, open: open, high: high, low: low, volume: volume
    )
}

struct ChartPointTests {

    @Test("A bar closing above its open is an up bar")
    func direction() {
        #expect(bar(1, open: 100, close: 105).isUp)
        #expect(!bar(1, open: 105, close: 100).isUp)
        // A doji closed where it opened; treating that as a decline would paint the
        // candle red for a day on which nothing was lost.
        #expect(bar(1, open: 100, close: 100).isUp)
    }

    @Test("A bar with no open is not reported as a decline")
    func directionWithoutOpen() {
        #expect(bar(1, close: 100).isUp)
    }

    @Test("A wick needs a coherent high and low")
    func rangeValidity() {
        #expect(bar(1, high: 110, low: 90, close: 100).hasRange)
        #expect(!bar(1, high: 110, close: 100).hasRange)          // no low
        #expect(!bar(1, low: 90, close: 100).hasRange)            // no high
        #expect(!bar(1, high: 90, low: 110, close: 100).hasRange) // inverted
        #expect(!bar(1, high: .nan, low: 90, close: 100).hasRange)
    }
}


struct ChartSeriesTests {

    private func series(_ points: [ChartPoint], baseline: Double? = nil) -> ChartSeries {
        ChartSeries(points: points, quote: nil, rangeBaseline: baseline)
    }

    @Test("The range's extremes come from the wicks, not the closes")
    func extremesUseWicks() throws {
        let data = series([
            bar(1, open: 100, high: 130, low: 95, close: 105),
            bar(2, open: 105, high: 112, low: 80, close: 108),
            bar(3, open: 108, high: 115, low: 100, close: 110)
        ])

        // The highest close is 110 and the lowest 105, but the day's trading reached
        // 130 and 80 — a chart scaled to closes alone would cut both wicks off.
        #expect(try #require(data.rangeHigh?.high) == 130)
        #expect(try #require(data.rangeLow?.low) == 80)
    }

    @Test("Bars without a high or low are ignored when finding the extremes")
    func extremesSkipIncompleteBars() {
        let data = series([
            bar(1, close: 999),
            bar(2, open: 100, high: 110, low: 90, close: 105)
        ])

        #expect(data.rangeHigh?.high == 110)
        #expect(data.rangeLow?.low == 90)
    }

    @Test("A series with no usable bars reports no extremes")
    func noExtremes() {
        let data = series([bar(1, close: 100), bar(2, close: 101)])
        #expect(data.rangeHigh == nil)
        #expect(data.rangeLow == nil)
        #expect(!data.hasVolume)
    }

    @Test("Volume is plotted only when some bar actually carries it")
    func volumePresence() {
        #expect(!series([bar(1, close: 100)]).hasVolume)
        #expect(!series([bar(1, close: 100, volume: 0)]).hasVolume)
        #expect(series([bar(1, close: 100, volume: 0), bar(2, close: 101, volume: 5)]).hasVolume)
    }

    @Test("The range baseline is kept apart from the quote's own previous close")
    func baselineIsSeparate() {
        // Yahoo moves chartPreviousClose with the range, so the value that colours a
        // one-month chart is a month old. Reading a day change off it was how the
        // detail view came to report a month's fall as today's.
        let data = series([bar(1, close: 442.90)], baseline: 471.65)

        #expect(data.rangeBaseline == 471.65)
        #expect(data.quote == nil)
        #expect(data.latestPrice == nil)
        #expect(data.displayPrice == 442.90)
    }
}
