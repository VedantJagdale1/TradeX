//
//  QuoteCacheTests.swift
//  TradeXTests
//

import Foundation
import Testing
@testable import TradeX

/// Counts how many times the network would actually have been hit.
private actor CallCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

struct QuoteCacheTests {

    @Test("Concurrent callers for one symbol share a single request")
    func concurrentCallersAreDeduplicated() async throws {
        let cache = QuoteCache()
        let counter = CallCounter()

        await withTaskGroup(of: Double?.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try? await cache.price(for: "RELIANCE", maxAge: 30) {
                        await counter.record()
                        try await Task.sleep(nanoseconds: 80_000_000)
                        return 1322.0
                    }
                }
            }
            for await _ in group {}
        }

        #expect(await counter.count == 1)
    }

    @Test("A repeat call inside the window doesn't hit the network")
    func freshQuoteIsReused() async throws {
        let cache = QuoteCache()
        let counter = CallCounter()

        for _ in 0..<3 {
            _ = try await cache.price(for: "TCS", maxAge: 30) {
                await counter.record()
                return 2308.0
            }
        }

        #expect(await counter.count == 1)
    }

    @Test("A user-initiated refresh bypasses the cache")
    func forcedRefreshHitsTheNetwork() async throws {
        let cache = QuoteCache()
        let counter = CallCounter()

        _ = try await cache.price(for: "INFY", maxAge: 30) {
            await counter.record(); return 1130.0
        }
        _ = try await cache.price(for: "INFY", maxAge: 0) {
            await counter.record(); return 1131.0
        }

        #expect(await counter.count == 2)
    }

    @Test("A failed fetch serves the last known quote rather than nothing")
    func failureFallsBackToStale() async throws {
        let cache = QuoteCache()

        _ = try await cache.price(for: "HDFCBANK", maxAge: 30) { 712.0 }

        // Callers use `try?` and treat nil as "no data", so returning stale is what
        // keeps an alert check or an order fill from silently being skipped.
        let value = try await cache.price(for: "HDFCBANK", maxAge: 0) {
            throw NetworkError.noData
        }
        #expect(value == 712.0)
    }

    @Test("Being rate limited stops further requests instead of extending the limit")
    func rateLimitBacksOff() async throws {
        let cache = QuoteCache()
        let counter = CallCounter()

        _ = try await cache.price(for: "TMCV", maxAge: 30) { 467.10 }
        _ = try? await cache.price(for: "TMCV", maxAge: 0) { throw NetworkError.rateLimited }

        let afterLimit = await counter.count
        for _ in 0..<3 {
            _ = try? await cache.price(for: "TMCV", maxAge: 0) {
                await counter.record(); return 467.10
            }
        }

        #expect(await counter.count == afterLimit)
    }

    @Test("A symbol with nothing cached fails fast while rate limited")
    func rateLimitedUnknownSymbolThrows() async throws {
        let cache = QuoteCache()
        _ = try? await cache.price(for: "TMCV", maxAge: 0) { throw NetworkError.rateLimited }

        await #expect(throws: NetworkError.self) {
            _ = try await cache.price(for: "WIPRO", maxAge: 0) { 250.0 }
        }
    }
}
