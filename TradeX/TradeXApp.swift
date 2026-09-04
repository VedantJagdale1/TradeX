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
                LimitOrder.self
            )
        } catch {
            fatalError("Could not open the TradeX data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
