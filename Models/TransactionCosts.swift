//
//  TransactionCosts.swift
//  TradeX
//

import Foundation

/// What a delivery trade on the NSE actually costs.
///
/// Paper trading that ignores charges teaches a lie: it makes frequent small trades
/// look free, when in practice they are where returns quietly go. The statutory
/// components below are set by SEBI, the exchanges and the state governments and change
/// from time to time; brokerage varies by broker. They are defaults, not law — the rates
/// in force on the day you trade are the ones that matter.
///
/// Modelled on delivery (CNC) equity. Intraday, F&O and currency carry different rates
/// and are not simulated.
struct CostSchedule: Sendable, Equatable {

    /// Percentage of turnover taken as brokerage, and the rupee ceiling per order.
    var brokeragePercent: Double
    var brokerageCap: Double

    /// Securities Transaction Tax — charged on both legs for delivery.
    var sttPercent: Double

    /// NSE transaction charge on turnover.
    var exchangePercent: Double

    /// SEBI turnover fee, quoted as ₹10 per crore.
    var sebiPercent: Double

    /// Stamp duty, charged on the buy leg only.
    var stampDutyPercent: Double

    /// GST on the *services* — brokerage, exchange and SEBI fees — never on the taxes.
    var gstPercent: Double

    /// Depository charge per scrip on the sell leg, a flat fee regardless of size.
    var dpChargePerSell: Double

    /// A discount broker's delivery rates: no brokerage, statutory charges only.
    static let discountDelivery = CostSchedule(
        brokeragePercent: 0,
        brokerageCap: 20,
        sttPercent: 0.1,
        exchangePercent: 0.00297,
        sebiPercent: 0.0001,
        stampDutyPercent: 0.015,
        gstPercent: 18,
        dpChargePerSell: 15.93
    )

    /// A traditional full-service broker, where brokerage dominates everything else.
    static let fullService = CostSchedule(
        brokeragePercent: 0.30,
        brokerageCap: .greatestFiniteMagnitude,
        sttPercent: 0.1,
        exchangePercent: 0.00297,
        sebiPercent: 0.0001,
        stampDutyPercent: 0.015,
        gstPercent: 18,
        dpChargePerSell: 15.93
    )

    /// Charges nothing at all, for anyone who would rather model clean prices.
    static let none = CostSchedule(
        brokeragePercent: 0, brokerageCap: 0, sttPercent: 0, exchangePercent: 0,
        sebiPercent: 0, stampDutyPercent: 0, gstPercent: 0, dpChargePerSell: 0
    )
}


/// The line items behind a single trade's charges, kept separate so the order ticket can
/// show where the money went rather than one unexplained total.
struct CostBreakdown: Sendable, Equatable {
    var brokerage: Double = 0
    var stt: Double = 0
    var exchange: Double = 0
    var sebi: Double = 0
    var stampDuty: Double = 0
    var gst: Double = 0
    var dpCharge: Double = 0

    /// Every component is already rounded to paise, so this is exactly the sum of the
    /// lines shown on screen. A total that disagreed with its own itemisation by a
    /// paisa would cast doubt on every other figure in the app.
    var total: Double { brokerage + stt + exchange + sebi + stampDuty + gst + dpCharge }

    var isZero: Bool { total < 0.005 }

    /// Line items worth showing. A component that rounds to nothing is billed as
    /// nothing, so leaving it out loses no money and saves a row of noise.
    var items: [(label: String, amount: Double)] {
        [
            ("Brokerage", brokerage),
            ("STT", stt),
            ("Exchange charges", exchange),
            ("SEBI fees", sebi),
            ("Stamp duty", stampDuty),
            ("GST", gst),
            ("DP charges", dpCharge)
        ].filter { $0.amount > 0 }
    }
}


extension CostSchedule {

    /// What this trade costs, before the cash moves.
    ///
    /// Each line is rounded to paise as it is computed, the way a contract note is
    /// drawn up, so the itemisation the user sees adds up to the amount actually
    /// billed.
    func charges(isBuy: Bool, quantity: Int, price: Double) -> CostBreakdown {
        let turnover = Double(max(0, quantity)) * max(0, price)
        guard turnover > 0 else { return CostBreakdown() }

        func paise(_ amount: Double) -> Double { (amount * 100).rounded() / 100 }

        var breakdown = CostBreakdown()
        breakdown.brokerage = paise(min(turnover * brokeragePercent / 100, brokerageCap))
        breakdown.stt = paise(turnover * sttPercent / 100)
        breakdown.exchange = paise(turnover * exchangePercent / 100)
        breakdown.sebi = paise(turnover * sebiPercent / 100)
        breakdown.stampDuty = isBuy ? paise(turnover * stampDutyPercent / 100) : 0
        breakdown.dpCharge = isBuy ? 0 : paise(dpChargePerSell)

        // GST rides on the services only, and on the amounts actually billed for them.
        // Applying it to STT or stamp duty would be taxing a tax, which is not how the
        // bill is drawn up.
        breakdown.gst = paise(
            (breakdown.brokerage + breakdown.exchange + breakdown.sebi) * gstPercent / 100
        )

        return breakdown
    }

    /// Total charges for a trade.
    func total(isBuy: Bool, quantity: Int, price: Double) -> Double {
        charges(isBuy: isBuy, quantity: quantity, price: price).total
    }
}


/// Which rate card the account trades on.
enum BrokerProfile: String, CaseIterable, Identifiable, Sendable {
    case discount, fullService, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .discount: return "Discount"
        case .fullService: return "Full-service"
        case .none: return "No charges"
        }
    }

    var detail: String {
        switch self {
        case .discount: return "No brokerage on delivery. Statutory charges only."
        case .fullService: return "0.30% brokerage plus statutory charges."
        case .none: return "Trade at clean prices, as though charges did not exist."
        }
    }

    var schedule: CostSchedule {
        switch self {
        case .discount: return .discountDelivery
        case .fullService: return .fullService
        case .none: return .none
        }
    }
}
