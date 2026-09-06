//
//  AppLock.swift
//  TradeX
//

import Foundation
import LocalAuthentication
import SwiftUI

/// Optional biometric lock over the whole app.
///
/// The portfolio is simulated, but it is still a record of how someone thinks and what
/// they hold, and finance-shaped apps are expected to offer this.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    private static let preferenceKey = "TradeX.appLockEnabled"

    /// Locked until unlocked. Starts unlocked when the feature is off.
    private(set) var isLocked: Bool

    /// Only ever changed through `enable()` and `disable()`, so the lock can never be
    /// turned on without first proving it can be turned off again.
    private(set) var isEnabled: Bool

    private(set) var lastFailureReason: String?

    private let defaults: UserDefaults

    /// Resolved once at init and excluded from observation: this was a computed
    /// property, so SwiftUI built a fresh LAContext on every render of the settings row
    /// just to draw a label. It cannot change while the app is running.
    @ObservationIgnored private let capability: (available: Bool, description: String)

    /// How the owner is verified. Injectable so the state machine can be tested without
    /// a device, since biometrics can't be driven from a test.
    var authenticate: (String) async -> Result<Bool, Error>

    init(
        defaults: UserDefaults = .standard,
        authenticate: (((String) async -> Result<Bool, Error>))? = nil
    ) {
        let enabled = defaults.bool(forKey: Self.preferenceKey)
        self.defaults = defaults
        self.isEnabled = enabled
        self.isLocked = enabled
        self.authenticate = authenticate ?? AppLock.evaluateDeviceOwner
        self.capability = AppLock.resolveCapability()
    }

    private static func resolveCapability() -> (available: Bool, description: String) {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return (false, "Not available")
        }
        switch context.biometryType {
        case .faceID: return (true, "Face ID")
        case .touchID: return (true, "Touch ID")
        case .opticID: return (true, "Optic ID")
        default: return (true, "Passcode")
        }
    }

    /// deviceOwnerAuthentication rather than biometrics alone: a failed or unavailable
    /// scan should fall back to the passcode rather than locking the owner out.
    private static func evaluateDeviceOwner(reason: String) async -> Result<Bool, Error> {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        do {
            return .success(try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                             localizedReason: reason))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Availability

    /// What the device can actually do, so the setting isn't offered where it can't work.
    var biometryDescription: String { capability.description }

    var isAvailable: Bool { capability.available }

    // MARK: - Turning it on and off

    /// Turns the lock on, but only after the owner has proved they can pass it.
    ///
    /// Enabling without a check would let someone switch on a lock they cannot clear —
    /// a face that won't scan, a passcode they don't know — and be shut out of their own
    /// portfolio at the next launch, with no way back in from inside the app.
    @discardableResult
    func enable() async -> Bool {
        lastFailureReason = nil

        guard isAvailable else {
            lastFailureReason = "Set up a passcode or biometrics on this device first."
            return false
        }

        switch await authenticate("Confirm you can unlock TradeX") {
        case .success(true):
            isEnabled = true
            isLocked = false
            defaults.set(true, forKey: Self.preferenceKey)
            return true

        case .success(false):
            lastFailureReason = "Not enabled — the check didn't pass."
            return false

        case .failure(let error):
            lastFailureReason = error.localizedDescription
            return false
        }
    }

    func disable() {
        isEnabled = false
        // Turning it off must not leave the app stuck behind a lock it no longer has.
        isLocked = false
        lastFailureReason = nil
        defaults.set(false, forKey: Self.preferenceKey)
    }

    // MARK: - Locking

    /// Re-locks when the app leaves the foreground.
    func lock() {
        guard isEnabled else { return }
        isLocked = true
    }

    func unlock() async {
        guard isLocked else { return }

        switch await authenticate("Unlock TradeX to see your portfolio") {
        case .success(true):
            isLocked = false
            lastFailureReason = nil
        case .success(false):
            lastFailureReason = "Authentication didn't pass."
        case .failure(let error):
            lastFailureReason = error.localizedDescription
        }
    }
}


/// Covers the app while locked.
struct LockScreen: View {
    @Bindable var lock: AppLock

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accent)

                Text("TradeX is Locked")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Unlock with \(lock.biometryDescription) to see your portfolio.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let reason = lock.lastFailureReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Theme.loss)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await lock.unlock() }
                } label: {
                    Text("Unlock")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(Theme.accent)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(40)
        }
        .task { await lock.unlock() }
    }
}
