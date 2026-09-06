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
    private(set) var lastFailureReason: String?

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey)
            // Turning it off must not leave the app stuck behind a lock it no longer has.
            if !isEnabled { isLocked = false }
        }
    }

    init(defaults: UserDefaults = .standard) {
        let enabled = defaults.bool(forKey: Self.preferenceKey)
        self.isEnabled = enabled
        self.isLocked = enabled
    }

    /// What the device can actually do, so the setting isn't offered where it can't work.
    var biometryDescription: String {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return "Not available"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Re-locks when the app leaves the foreground.
    func lock() {
        guard isEnabled else { return }
        isLocked = true
    }

    func unlock() async {
        guard isLocked else { return }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        do {
            // deviceOwnerAuthentication, not biometrics alone: a failed or unavailable
            // scan should fall back to the passcode rather than locking the owner out.
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock TradeX to see your portfolio"
            )
            if success {
                isLocked = false
                lastFailureReason = nil
            }
        } catch {
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
