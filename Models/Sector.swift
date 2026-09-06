//
//  Sector.swift
//  TradeX
//

import Foundation

/// Sector classification for NSE symbols.
///
/// `stock_list.csv` carries no sector column, so this is a curated mapping rather than
/// data. It covers the large and mid caps a paper portfolio is most likely to hold;
/// anything outside it is reported honestly as unclassified rather than guessed at,
/// because a wrong sector is worse than an absent one when the point is measuring
/// concentration risk.
enum Sector: String, CaseIterable, Identifiable, Sendable {
    case financials = "Financials"
    case informationTechnology = "Information Technology"
    case energy = "Energy"
    case consumer = "Consumer"
    case healthcare = "Healthcare"
    case industrials = "Industrials"
    case materials = "Materials"
    case automotive = "Automotive"
    case telecom = "Telecom"
    case utilities = "Utilities"
    case unclassified = "Unclassified"

    var id: String { rawValue }

    static func forSymbol(_ symbol: String) -> Sector {
        mapping[symbol.uppercased()] ?? .unclassified
    }

    private static let mapping: [String: Sector] = [
        // Financials
        "HDFCBANK": .financials, "ICICIBANK": .financials, "SBIN": .financials,
        "KOTAKBANK": .financials, "AXISBANK": .financials, "INDUSINDBK": .financials,
        "BAJFINANCE": .financials, "BAJAJFINSV": .financials, "SBILIFE": .financials,
        "HDFCLIFE": .financials, "ICICIGI": .financials, "ICICIPRULI": .financials,
        "SHRIRAMFIN": .financials, "CHOLAFIN": .financials, "PNB": .financials,
        "BANKBARODA": .financials, "IDFCFIRSTB": .financials, "FEDERALBNK": .financials,
        "AUBANK": .financials, "MUTHOOTFIN": .financials, "HDFCAMC": .financials,
        "JIOFIN": .financials, "LICI": .financials, "M&MFIN": .financials,
        "J&KBANK": .financials, "CANBK": .financials, "UNIONBANK": .financials,

        // Information Technology
        "TCS": .informationTechnology, "INFY": .informationTechnology,
        "HCLTECH": .informationTechnology, "WIPRO": .informationTechnology,
        "TECHM": .informationTechnology, "LTIM": .informationTechnology,
        "PERSISTENT": .informationTechnology, "COFORGE": .informationTechnology,
        "MPHASIS": .informationTechnology, "OFSS": .informationTechnology,
        "TATAELXSI": .informationTechnology, "KPITTECH": .informationTechnology,

        // Energy
        "RELIANCE": .energy, "ONGC": .energy, "BPCL": .energy, "IOC": .energy,
        "HINDPETRO": .energy, "GAIL": .energy, "OIL": .energy, "PETRONET": .energy,
        "COALINDIA": .energy, "ATGL": .energy, "IGL": .energy,

        // Consumer
        "HINDUNILVR": .consumer, "ITC": .consumer, "NESTLEIND": .consumer,
        "BRITANNIA": .consumer, "DABUR": .consumer, "MARICO": .consumer,
        "GODREJCP": .consumer, "COLPAL": .consumer, "TATACONSUM": .consumer,
        "VBL": .consumer, "UNITDSPR": .consumer, "TITAN": .consumer,
        "TRENT": .consumer, "DMART": .consumer, "JUBLFOOD": .consumer,
        "ZOMATO": .consumer, "NYKAA": .consumer, "PAGEIND": .consumer,

        // Healthcare
        "SUNPHARMA": .healthcare, "CIPLA": .healthcare, "DRREDDY": .healthcare,
        "DIVISLAB": .healthcare, "APOLLOHOSP": .healthcare, "LUPIN": .healthcare,
        "AUROPHARMA": .healthcare, "TORNTPHARM": .healthcare, "ZYDUSLIFE": .healthcare,
        "ALKEM": .healthcare, "MANKIND": .healthcare, "MAXHEALTH": .healthcare,
        "FORTIS": .healthcare, "BIOCON": .healthcare,

        // Industrials
        "LT": .industrials, "SIEMENS": .industrials, "ABB": .industrials,
        "BEL": .industrials, "HAL": .industrials, "BHEL": .industrials,
        "CUMMINSIND": .industrials, "THERMAX": .industrials, "POLYCAB": .industrials,
        "HAVELLS": .industrials, "DIXON": .industrials, "GVT&D": .industrials,
        "INDIGO": .industrials, "ADANIPORTS": .industrials, "CONCOR": .industrials,

        // Materials
        "TATASTEEL": .materials, "JSWSTEEL": .materials, "HINDALCO": .materials,
        "VEDL": .materials, "ULTRACEMCO": .materials, "GRASIM": .materials,
        "SHREECEM": .materials, "AMBUJACEM": .materials, "ACC": .materials,
        "JSWENERGY": .materials, "PIDILITIND": .materials, "ASIANPAINT": .materials,
        "BERGEPAINT": .materials, "SRF": .materials, "UPL": .materials,
        "PIIND": .materials, "TATACHEM": .materials, "JINDALSTEL": .materials,
        "NMDC": .materials, "SAIL": .materials,

        // Automotive
        "MARUTI": .automotive, "M&M": .automotive, "TMCV": .automotive,
        "TMPV": .automotive, "BAJAJ-AUTO": .automotive, "EICHERMOT": .automotive,
        "HEROMOTOCO": .automotive, "TVSMOTOR": .automotive, "ASHOKLEY": .automotive,
        "BOSCHLTD": .automotive, "MOTHERSON": .automotive, "BALKRISIND": .automotive,
        "MRF": .automotive, "APOLLOTYRE": .automotive, "EXIDEIND": .automotive,

        // Telecom
        "BHARTIARTL": .telecom, "IDEA": .telecom, "INDUSTOWER": .telecom,
        "TATACOMM": .telecom, "HFCL": .telecom,

        // Utilities
        "NTPC": .utilities, "POWERGRID": .utilities, "TATAPOWER": .utilities,
        "ADANIGREEN": .utilities, "ADANIENSOL": .utilities, "NHPC": .utilities,
        "SJVN": .utilities, "TORNTPOWER": .utilities, "IREDA": .utilities,
    ]

    /// How many symbols the mapping actually covers, so the UI can be honest about it.
    static var coverage: Int { mapping.count }
}


/// One slice of the portfolio.
struct SectorAllocation: Identifiable {
    let sector: Sector
    let value: Double
    let symbols: [String]

    var id: String { sector.rawValue }

    static func breakdown(of holdings: [PortfolioHolding]) -> [SectorAllocation] {
        var byValue: [Sector: Double] = [:]
        var bySymbols: [Sector: [String]] = [:]

        for holding in holdings {
            let sector = Sector.forSymbol(holding.symbol)
            byValue[sector, default: 0] += holding.currentValue
            bySymbols[sector, default: []].append(holding.symbol)
        }

        return byValue
            .map { SectorAllocation(sector: $0.key, value: $0.value,
                                    symbols: (bySymbols[$0.key] ?? []).sorted()) }
            .sorted { $0.value > $1.value }
    }

    func share(of total: Double) -> Double {
        total > 0 ? (value / total) * 100 : 0
    }
}
