//
//  TradeXApp.swift
//  TradeX
//
//  Created by vedant jagdale on 02/07/26.
//

import SwiftUI
import SwiftData

@main
struct TradeXApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: [PortfolioHolding.self, UserSettings.self])
        }
    }
}
