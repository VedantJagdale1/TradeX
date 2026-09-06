//
//  SettingsView.swift
//  TradeX
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppLock.self) private var lock

    @Query private var trades: [Trade]
    @Query private var alerts: [PriceAlert]
    @Query private var watchlist: [WatchlistItem]

    var body: some View {
        @Bindable var lock = lock

        List {
            Section {
                if lock.isAvailable {
                    Toggle(isOn: $lock.isEnabled) {
                        Label("Require \(lock.biometryDescription)", systemImage: "lock.fill")
                    }
                } else {
                    Label("No passcode or biometrics set up on this device", systemImage: "lock.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Asks on launch and whenever you return to the app. Falls back to your passcode if a scan fails.")
            }

            Section("Your Data") {
                row("Trades recorded", "\(trades.count)")
                row("Price alerts", "\(alerts.count)")
                row("Watchlist", "\(watchlist.count)")
                row("Capital deposited",
                    CurrencyFormatter.rupees(PortfolioManager.shared.netDeposits(in: modelContext)))
            }

            Section {
                Text("TradeX is a paper trading app. Every position, order and balance is simulated — no real money is involved, and nothing here is investment advice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Market data is sourced from Yahoo Finance and may be delayed or incomplete. AI responses are generated and can be wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
