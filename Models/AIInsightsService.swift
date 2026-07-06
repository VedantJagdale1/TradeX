//
//  AIInsightsService.swift
//  TradeX
//
//  Created by Gemini on 04/07/26.
//

import Foundation

class AIInsightsService {
    static let shared = AIInsightsService()
    private init() {}
    
    /// Generates a response based on the user's query.
    /// In a real application, this would call an LLM API (like OpenAI, Claude, or Gemini).
    func generateResponse(for query: String) async -> String {
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        
        let lowerQuery = query.lowercased()
        
        if lowerQuery.contains("portfolio") || lowerQuery.contains("audit") {
            return "Based on your current portfolio, you have a 45% exposure to IT and 30% to Energy. I recommend diversifying into FMCG to hedge against sector-specific volatility. Your year-to-date return is beating the NIFTY 50 by 2.4%."
        } else if lowerQuery.contains("it sector") || lowerQuery.contains("earnings") {
            return "IT sector earnings for Q1 have been mixed. TCS and Infosys reported steady margins despite global headwinds, while mid-cap IT firms are seeing some pressure. The overall outlook remains cautious but stable for the long term."
        } else if lowerQuery.contains("reliance") {
            return "RELIANCE is currently showing strong support at ₹2,450. Resistance is expected near ₹2,620. Technical indicators suggest a bullish crossover in the daily timeframe, supported by high trading volumes."
        } else if lowerQuery.contains("market") || lowerQuery.contains("summary") {
            return "The Indian markets opened flat today. Global cues are neutral. Foreign Institutional Investors (FIIs) have been net buyers in the last three sessions, providing a floor for the benchmark indices."
        } else {
            return "That's an interesting question about '\(query)'. I'm currently analyzing market trends and historical data to give you a detailed insight. In general, staying disciplined with stop-losses is key in this volatile environment."
        }
    }
}
