//
//  Theme.swift
//  TradeX
//

import SwiftUI

/// The app's visual vocabulary.
///
/// Before this existed the views used seven different corner radii and four different
/// hero font sizes for the same role. Everything visual should come from here so new
/// screens inherit the language instead of inventing an eighth value.
enum Theme {

    // MARK: - Colour

    static let accent = Color.purple
    static let profit = Color.green
    static let loss = Color.red

    static let surface = Color(.secondarySystemBackground)
    static let background = Color(.systemBackground)
    static let raisedSurface = Color(.tertiarySystemBackground)

    /// Buy and sell sides. Distinct from profit/loss — a sell is not a loss.
    static let buySide = Color.blue
    static let sellSide = Color.purple

    /// A soft, non-alarming caution — trailing the benchmark isn't an error.
    static let caution = Color.orange

    /// Green above water, red below. Zero counts as flat-positive, matching
    /// `PortfolioHolding.isProfit`.
    static func pnl(_ value: Double) -> Color {
        value >= 0 ? profit : loss
    }

    /// "+" for gains, "" for losses — the minus sign comes from the number itself.
    static func sign(_ value: Double) -> String {
        value >= 0 ? "+" : ""
    }

    // MARK: - Shape

    enum Radius {
        static let chip: CGFloat = 8
        static let control: CGFloat = 12
        static let card: CGFloat = 16
        static let pill: CGFloat = 24
    }

    // MARK: - Type

    enum Typography {
        /// The single biggest number on a screen.
        static let hero = SwiftUI.Font.system(size: 34, weight: .bold, design: .rounded)
        /// A secondary figure — card headline values.
        static let figure = SwiftUI.Font.system(size: 22, weight: .semibold, design: .rounded)
    }

    // MARK: - Motion

    enum Motion {
        /// Value changes: quick, no overshoot on money.
        static let value: Animation = .snappy(duration: 0.35)
        /// Layout and presentation changes.
        static let layout: Animation = .spring(response: 0.4, dampingFraction: 0.85)
    }
}


// MARK: - Card

private struct CardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            // `.continuous` gives iOS's squircle corners; plain `.cornerRadius()`
            // draws circular ones, which read subtly cheaper at these sizes.
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
            )
    }
}

extension View {
    /// The standard surface treatment: one padding, one radius, one fill.
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardModifier(padding: padding))
    }
}


// MARK: - Animated money

/// A rupee amount that rolls between values rather than snapping.
///
/// `.numericText` animates digit-by-digit, so a refreshed portfolio value visibly
/// ticks instead of blinking to a new number.
struct MoneyText: View {
    let amount: Double
    var font: SwiftUI.Font = Theme.Typography.figure
    var color: Color = .primary
    var showsSign: Bool = false

    var body: some View {
        Text("\(showsSign ? Theme.sign(amount) : "")₹\(amount, specifier: "%.2f")")
            .font(font)
            .foregroundStyle(color)
            .contentTransition(.numericText(value: amount))
            .animation(Theme.Motion.value, value: amount)
    }
}

/// A percentage that rolls the same way.
struct PercentText: View {
    let value: Double
    var font: SwiftUI.Font = .caption
    var color: Color? = nil
    var showsSign: Bool = true

    var body: some View {
        Text("\(showsSign ? Theme.sign(value) : "")\(value, specifier: "%.2f")%")
            .font(font)
            .fontWeight(.bold)
            .foregroundStyle(color ?? Theme.pnl(value))
            .contentTransition(.numericText(value: value))
            .animation(Theme.Motion.value, value: value)
    }
}
