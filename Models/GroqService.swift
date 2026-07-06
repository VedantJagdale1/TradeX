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

    
    private let apiKey = ""

    
    private let model = "llama-3.3-70b-versatile"

    
    func generateInsight(userPrompt: String, portfolioContext: String) async throws -> String {

        guard !apiKey.isEmpty, apiKey.hasPrefix("gsk_") else {
            throw NSError(
                domain: "GroqService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Missing or invalid Groq API key. Get a free one at https://console.groq.com/keys — it must start with 'gsk_'."]
            )
        }

        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw NSError(domain: "GroqService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid API Endpoint URL"])
        }

        let systemPrompt = """
        You are TradeX AI, a highly sophisticated portfolio strategist and financial advisor.
        You are given the user's current portfolio status below. Use this data to provide deeply
        analytical, concise, and professional answers. Keep your reply direct and easy to read.

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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
