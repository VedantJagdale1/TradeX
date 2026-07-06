//
//  AIInsightsViewModel.swift
//  TradeX
//
//  Created by Gemini on 04/07/26.
//

import Foundation
import SwiftUI

@MainActor
class AIInsightsViewModel: ObservableObject {
    @Published var messageText: String = ""
    @Published var conversation: [ChatMessage] = [
        ChatMessage(text: "Hello! I am your TradeX AI portfolio strategist. Ask me to analyze your holdings, break down company fundamentals, or draft a market summary.", isUser: false)
    ]
    @Published var isTyping: Bool = false
    
    let suggestions = [
        "Audit my current portfolio returns",
        "Summarize IT sector earnings",
        "Analyze RELIANCE resistance levels"
    ]
    
    private let aiService = AIInsightsService.shared
    
    func sendMessage() {
        let userQuery = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userQuery.isEmpty else { return }
        
        // 1. Add user message
        conversation.append(ChatMessage(text: userQuery, isUser: true))
        messageText = ""
        
        // 2. Set typing state
        isTyping = true
        
        // 3. Get AI response
        Task {
            let response = await aiService.generateResponse(for: userQuery)
            
            // 4. Update UI with response
            self.conversation.append(ChatMessage(text: response, isUser: false))
            self.isTyping = false
        }
    }
}
