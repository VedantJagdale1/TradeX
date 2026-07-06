//
//  ChatMessage.swift
//  TradeX
//
//  Created by vedant jagdale on 03/07/26.
//

import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
    let timestamp = Date()
}
