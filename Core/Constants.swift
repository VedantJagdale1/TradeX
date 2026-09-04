//
//  Constants.swift
//  test
//
//  Created by vedant jagdale on 29/06/26.
//

import Foundation

struct Constants {
    static let DashboardString = "Dashboard"
    static let Dashboardiconstring = "chart.pie.fill"
    
    static let Explorestring = "Explore"
    static let Exploreiconstring = "magnifyingglass"
    
    static let Portfoliostring = "Portfolio"
    static let Portfolioiconstring = "briefcase.fill"
    
    static let Aistring = "AI Insights"
    static let Aiiconstring = "brain.head.profile"
}

/// Formats rupee amounts for interpolation into larger strings.
///
/// `Text("₹\(value, specifier: "%.2f")")` already applies the locale's digit grouping,
/// so standalone values don't need this. `String(format:)` does not — use this wherever
/// an amount has to be embedded in a sentence, or it renders ₹274500.00 instead of
/// ₹2,74,500.00.
enum CurrencyFormatter {
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static func rupees(_ amount: Double) -> String {
        let formatted = decimal.string(from: NSNumber(value: amount))
            ?? String(format: "%.2f", amount)
        return "₹\(formatted)"
    }
}
