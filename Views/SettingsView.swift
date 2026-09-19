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

    @State private var isVerifying = false

    /// Bound through the settings row rather than held in view state, so a change
    /// applies to the next order rather than only to this screen.
    private var brokerBinding: Binding<BrokerProfile> {
        Binding(
            get: { PortfolioManager.shared.settings(in: modelContext).brokerProfile },
            set: { PortfolioManager.shared.settings(in: modelContext).brokerProfile = $0 }
        )
    }

    private var chargesPaid: Double { trades.reduce(0) { $0 + $1.charges } }

    /// Routes the switch through enable/disable rather than binding straight to the
    /// stored flag, so turning it on has to pass a check first. A failed check leaves
    /// the flag untouched and the switch springs back on its own.
    private var lockBinding: Binding<Bool> {
        Binding(
            get: { lock.isEnabled },
            set: { wantsLock in
                guard !isVerifying else { return }
                if wantsLock {
                    isVerifying = true
                    Task {
                        await lock.enable()
                        isVerifying = false
                    }
                } else {
                    lock.disable()
                }
            }
        )
    }

    var body: some View {
        List {
            Section {
                if lock.isAvailable {
                    Toggle(isOn: lockBinding) {
                        HStack {
                            Label("Require \(lock.biometryDescription)", systemImage: "lock.fill")
                            if isVerifying {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }

                    if let reason = lock.lastFailureReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Theme.loss)
                    }
                } else {
                    Label("No passcode or biometrics set up on this device", systemImage: "lock.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("You'll be asked to confirm before it's switched on, so a lock you can't clear never takes effect. After that it asks on launch and whenever you return to the app, falling back to your passcode if a scan fails.")
            }

            Section {
                Picker("Rate card", selection: brokerBinding) {
                    ForEach(BrokerProfile.allCases) { profile in
                        Text(profile.label).tag(profile)
                    }
                }
                .pickerStyle(.segmented)

                Text(brokerBinding.wrappedValue.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if chargesPaid > 0 {
                    row("Charges paid so far", CurrencyFormatter.rupees(chargesPaid))
                }
            } header: {
                Text("Transaction Charges")
            } footer: {
                Text("STT, exchange and SEBI fees, stamp duty, GST and depository charges are applied to every trade, modelled on NSE delivery rates. Statutory rates change from time to time and brokerage varies by broker — treat these as a close approximation, not a contract note.")
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
