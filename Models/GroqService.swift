//
//  GroqService.swift
//  TradeX
//
//  Created by vedant jagdale on 06/07/26.
//

import Foundation

class GroqService {
    static let shared = GroqService()
    private init() {}

    
    /// Injected at build time from Secrets.xcconfig (GROQ_API_KEY), expanded into
    /// TradeX-Info.plist as `GroqAPIKey`. Never hardcode the key here — anything in
    /// source ends up in the shipped binary and in git history.
    ///
    /// Note the plist is a real file referenced by INFOPLIST_FILE rather than an
    /// `INFOPLIST_KEY_GroqAPIKey` build setting: that prefix only honours keys Xcode
    /// recognises, and silently drops custom ones from the generated Info.plist.
    private var apiKey: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "GroqAPIKey") as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    
    private let model = "llama-3.3-70b-versatile"

    
    func generateInsight(userPrompt: String, portfolioContext: String) async throws -> String {

        let key = apiKey
        guard !key.isEmpty, key.hasPrefix("gsk_") else {
            throw NSError(
                domain: "GroqService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Missing or invalid Groq API key. Copy Secrets.example.xcconfig to Secrets.xcconfig and set GROQ_API_KEY. Get a free key at https://console.groq.com/keys — it must start with 'gsk_'."]
            )
        }

        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw NSError(domain: "GroqService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid API Endpoint URL"])
        }

        let systemPrompt = """
        You are TradeX AI, a portfolio analyst inside a paper-trading practice app.
        Use the data below to give analytical, concise, professional answers. Keep replies
        direct and easy to read.

        How to use this data:
        - Trade history is the record of what the user actually did. Reference specific
          trades by symbol and date rather than speaking in generalities.
        - Where a trade has a stated reason, compare that reasoning against how the trade
          actually turned out, and say plainly whether it held up.
        - Look for patterns across trades: holding periods for winners versus losers,
          repeated entries into the same name, position sizing, reactions to drawdowns.
        - Distinguish realised P&L (booked on closed positions) from unrealised P&L
          (open positions, not yet money). Measure returns against deposited capital.
        - If the history is too thin to support a conclusion, say so instead of inventing
          a pattern.

        This is simulated trading for practice. Analyse the user's decisions and the data;
        do not present your output as personalised investment advice.

        [CURRENT USER PORTFOLIO DATA]
        \(portfolioContext)
        """

        let jsonPayload: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonPayload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GroqService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid Server Response"])
        }

        func groqErrorMessage(from data: Data) -> String? {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return nil
        }

        if httpResponse.statusCode != 200 {
            let rawBody = String(data: data, encoding: .utf8) ?? "<no body>"
            print("🚨 GROQ SERVER ERROR BODY: \(rawBody)")

            if httpResponse.statusCode == 429 {
                return "TradeX AI free-tier daily limit reached. Please try again later, or upgrade at console.groq.com."
            }

            let message = groqErrorMessage(from: data) ?? "Groq Server returned HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "GroqService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return "I processed your query but couldn't parse the final answer correctly."
        }

        return content
    }
}
