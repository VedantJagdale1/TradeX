//
//  TradeXApp.swift
//  TradeX
//
//  Created by vedant jagdale on 02/07/26.
//

import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct TradeXApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var lock = AppLock.shared

    /// Held explicitly rather than created by `.modelContainer(for:)` so the background
    /// refresh task — which runs outside any view — can open its own context.
    private let container: ModelContainer

    /// Set when the on-disk store could not be opened, so the app can say so instead of
    /// silently presenting an empty portfolio.
    private let storeFailureReason: String?

    private static let schema = Schema([
        PortfolioHolding.self,
        UserSettings.self,
        Trade.self,
        CashAdjustment.self,
        PortfolioSnapshot.self,
        WatchlistItem.self,
        PriceAlert.self,
        LimitOrder.self,
        StoredChatMessage.self,
        CorporateAction.self,
    ])

    init() {
        do {
            container = try ModelContainer(for: Self.schema)
            storeFailureReason = nil
        } catch {
            // Crashing here would brick the app with no way back in: the store can only
            // be cleared by deleting the app, which takes the portfolio with it. Models
            // have been added repeatedly, so a migration that fails has to stay
            // recoverable. Running in memory keeps the app openable and honest about it.
            storeFailureReason = error.localizedDescription
            container = try! ModelContainer(
                for: Self.schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .safeAreaInset(edge: .bottom) {
                    if let storeFailureReason {
                        Label(
                            "Your saved data couldn't be opened, so this session won't be kept. \(storeFailureReason)",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(Theme.loss)
                    }
                }
                .overlay {
                    if lock.isLocked {
                        LockScreen(lock: lock)
                            .transition(.opacity)
                    }
                }
                .animation(Theme.Motion.layout, value: lock.isLocked)
                .environment(lock)
        }
        .modelContainer(container)
        .backgroundTask(.appRefresh(PriceAlertService.backgroundTaskID)) {
            let context = ModelContext(container)
            await PriceAlertService.checkAll(modelContext: context)
            await LimitOrderService.checkAll(modelContext: context)
            // Re-arm: a refresh task only ever runs once per submission.
            await scheduleAlertCheck()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // Re-lock on the way out, so returning to the app asks again.
                lock.lock()
                Task { await scheduleAlertCheck() }
            }
        }
    }

    /// Asks iOS to run a price check later. The system decides when — it weighs battery,
    /// network and how often the app is actually opened — so this is a request, not a
    /// schedule, and an alert can arrive later than the moment its price was hit.
    @MainActor
    private func scheduleAlertCheck() async {
        let request = BGAppRefreshTaskRequest(identifier: PriceAlertService.backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
