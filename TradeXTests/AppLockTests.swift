//
//  AppLockTests.swift
//  TradeXTests
//

import Foundation
import Testing
@testable import TradeX

@MainActor
struct AppLockTests {

    private struct AuthError: LocalizedError {
        var errorDescription: String? { "Face ID isn't recognised." }
    }

    /// A fresh defaults suite per test so preferences can't leak between them.
    private func makeLock(
        startsEnabled: Bool = false,
        result: @escaping (String) async -> Result<Bool, Error>
    ) -> (AppLock, UserDefaults) {
        let suite = UserDefaults(suiteName: "AppLockTests.\(UUID().uuidString)")!
        suite.set(startsEnabled, forKey: "TradeX.appLockEnabled")
        return (AppLock(defaults: suite, authenticate: result), suite)
    }

    @Test("Enabling asks for confirmation before switching anything on")
    func enablingPrompts() async {
        var prompted: String?
        let (lock, _) = makeLock { reason in
            prompted = reason
            return .success(true)
        }

        let enabled = await lock.enable()

        #expect(enabled == true)
        #expect(prompted?.isEmpty == false)
        #expect(lock.isEnabled == true)
        #expect(lock.isLocked == false)   // confirming shouldn't immediately lock you out
    }

    @Test("A failed confirmation leaves the lock off")
    func failedConfirmationDoesNotEnable() async {
        // Otherwise someone could switch on a lock they cannot clear and be shut out of
        // their own portfolio at the next launch, with no way back in from inside.
        let (lock, defaults) = makeLock { _ in .failure(AuthError()) }

        let enabled = await lock.enable()

        #expect(enabled == false)
        #expect(lock.isEnabled == false)
        #expect(lock.isLocked == false)
        #expect(defaults.bool(forKey: "TradeX.appLockEnabled") == false)
        #expect(lock.lastFailureReason == "Face ID isn't recognised.")
    }

    @Test("A declined confirmation leaves the lock off too")
    func declinedConfirmationDoesNotEnable() async {
        let (lock, _) = makeLock { _ in .success(false) }

        #expect(await lock.enable() == false)
        #expect(lock.isEnabled == false)
    }

    @Test("A successful confirmation is remembered across launches")
    func enablingPersists() async {
        let (lock, defaults) = makeLock { _ in .success(true) }
        await lock.enable()

        #expect(defaults.bool(forKey: "TradeX.appLockEnabled") == true)

        // A later launch reads that back and starts locked.
        let relaunched = AppLock(defaults: defaults, authenticate: { _ in .success(true) })
        #expect(relaunched.isEnabled == true)
        #expect(relaunched.isLocked == true)
    }

    @Test("Disabling clears the lock rather than leaving the app stuck behind it")
    func disablingUnlocks() async {
        let (lock, defaults) = makeLock(startsEnabled: true) { _ in .success(true) }
        lock.lock()
        #expect(lock.isLocked == true)

        lock.disable()

        #expect(lock.isEnabled == false)
        #expect(lock.isLocked == false)
        #expect(defaults.bool(forKey: "TradeX.appLockEnabled") == false)
    }

    @Test("Backgrounding re-locks only when the feature is on")
    func lockingRespectsTheSetting() async {
        let (off, _) = makeLock { _ in .success(true) }
        off.lock()
        #expect(off.isLocked == false)

        let (on, _) = makeLock(startsEnabled: true) { _ in .success(true) }
        on.isLocked == true ? () : on.lock()
        #expect(on.isLocked == true)
    }

    @Test("A failed unlock keeps the app locked and says why")
    func failedUnlockStaysLocked() async {
        let (lock, _) = makeLock(startsEnabled: true) { _ in .failure(AuthError()) }

        await lock.unlock()

        #expect(lock.isLocked == true)
        #expect(lock.lastFailureReason == "Face ID isn't recognised.")
    }

    @Test("A successful unlock clears the lock and the previous error")
    func successfulUnlockClearsState() async {
        var shouldSucceed = false
        let (lock, _) = makeLock(startsEnabled: true) { _ in
            shouldSucceed ? .success(true) : .failure(AuthError())
        }

        await lock.unlock()
        #expect(lock.lastFailureReason != nil)

        shouldSucceed = true
        await lock.unlock()

        #expect(lock.isLocked == false)
        #expect(lock.lastFailureReason == nil)
    }

    @Test("Unlocking an app that isn't locked doesn't prompt")
    func noPromptWhenUnlocked() async {
        var prompts = 0
        let (lock, _) = makeLock { _ in prompts += 1; return .success(true) }

        await lock.unlock()

        #expect(prompts == 0)
    }
}
