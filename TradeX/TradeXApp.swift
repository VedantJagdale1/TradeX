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

    init() {
        do {
            container = try ModelContainer(
                for: PortfolioHolding.self,
                UserSettings.self,
                Trade.self,
                CashAdjustment.self,
                PortfolioSnapshot.self,
                WatchlistItem.self,
                PriceAlert.self,
                LimitOrder.self,
                StoredChatMessage.self,
                CorporateAction.self
            )
        } catch {
            fatalError("Could not open the TradeX data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
