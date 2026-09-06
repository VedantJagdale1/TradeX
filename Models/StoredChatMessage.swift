//
//  StoredChatMessage.swift
//  TradeX
//

import Foundation
import SwiftData

/// A chat turn that survives relaunch.
///
/// The conversation was view state, so closing the app discarded any analysis the model
/// had produced — including reviews of trades that took weeks to accumulate.
@Model
final class StoredChatMessage {
    @Attribute(.unique) var id: UUID
    var text: String
    var isUser: Bool
    var timestamp: Date

    init(id: UUID = UUID(), text: String, isUser: Bool, timestamp: Date = Date()) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.timestamp = timestamp
    }
}
