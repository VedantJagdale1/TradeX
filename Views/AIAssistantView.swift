//
//  AIAssistantView.swift
//  TradeX
//
//  Created by vedant jagdale on 02/07/26.
//

import SwiftUI
import SwiftData

struct AIAssistantView: View {
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \PortfolioHolding.symbol) private var holdings: [PortfolioHolding]
    @Query private var settings: [UserSettings]
    @Query(sort: \Trade.timestamp, order: .reverse) private var trades: [Trade]
    
    @State private var messageText = ""
    @State private var conversation: [ChatMessage] = [
        ChatMessage(text: "Hello! I am your TradeX AI portfolio strategist. Ask me to analyze your holdings, break down equity allocations, or evaluate cash margins.", isUser: false)
    ]
    
    @FocusState private var isInputFocused: Bool
    
    let suggestions = [
        "Review my trading decisions against the reasons I recorded",
        "Audit my realised returns and win rate",
        "Analyze my asset distribution risk",
        "Check liquid cash margin status"
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        ForEach(conversation) { message in
                            chatBubble(for: message)
                        }
                    }
                    .padding()
                }
                .onChange(of: conversation.count) { _, _ in
                    if let lastMessage = conversation.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                
                .onTapGesture {
                    isInputFocused = false
                }
            }
            
            Divider()
            
            if messageText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(suggestions, id: \.self) { chipText in
                            Button(action: { messageText = chipText }) {
                                Text(chipText)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.purple.opacity(0.08))
                                    .foregroundColor(.purple)
                                    .cornerRadius(20)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20)
                                            .stroke(Color.purple.opacity(0.15), lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                .background(Color(.systemBackground))
            }
            
            inputInteractiveBar
        }
        .navigationTitle("AI Assistant")
    }
}


private extension AIAssistantView {
    
    func chatBubble(for message: ChatMessage) -> some View {
        HStack {
            if message.isUser { Spacer() }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.subheadline)
                    .lineSpacing(4)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(message.isUser ? Color.blue : Color(.secondarySystemBackground))
                    .foregroundColor(message.isUser ? .white : .primary)
                    .cornerRadius(16, corners: message.isUser ? [.topLeft, .topRight, .bottomLeft] : [.topLeft, .topRight, .bottomRight])
            }
            .frame(maxWidth: 280, alignment: message.isUser ? .trailing : .leading)
            
            if !message.isUser { Spacer() }
        }
    }
    
    var inputInteractiveBar: some View {
        HStack(spacing: 12) {
            TextField("Ask TradeX AI...", text: $messageText)
                .focused($isInputFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(24)
            
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .purple)
            }
            .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") {
                        isInputFocused = false
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.purple)
                }
            }
        }
    }
    
    func sendMessage() {
        let userQuery = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userQuery.isEmpty else { return }
        
        conversation.append(ChatMessage(text: userQuery, isUser: true))
        messageText = ""
        
        let cashBalance = settings.first?.availableCash ?? 274500.00
        let netDeposits = PortfolioManager.shared.netDeposits(in: modelContext)
        let totalStocksValue = holdings.reduce(0) { $0 + $1.currentValue }
        let totalInvested = holdings.reduce(0) { $0 + $1.investedAmount }
        let totalNetWorth = totalStocksValue + cashBalance
        let netPnL = totalStocksValue - totalInvested
        let netPnLPercent = totalInvested > 0 ? (netPnL / totalInvested) * 100 : 0.0
        
        var stockHoldingsDetails = ""
        for holding in holdings {
            stockHoldingsDetails += "- \(holding.symbol): \(holding.quantity) Shares, Avg Cost: ₹\(holding.avgBuyPrice), Current Spot: ₹\(holding.currentPrice), Current Value: ₹\(holding.currentValue), PnL: ₹\(holding.totalPNL) (\(String(format: "%.2f", holding.pnlPercentage))%)\n"
        }
        
        // Closed positions are what makes "audit my returns" answerable — unrealised
        // P&L alone says nothing about whether past decisions were any good.
        let closedTrades = trades.filter(\.isClosingTrade)
        let realizedPnL = closedTrades.reduce(0) { $0 + ($1.realizedPnL ?? 0) }
        let winningTrades = closedTrades.filter { ($0.realizedPnL ?? 0) > 0 }.count
        let winRateLine = closedTrades.isEmpty
            ? "No positions closed yet."
            : "\(winningTrades) of \(closedTrades.count) closed positions were profitable (\(String(format: "%.0f", (Double(winningTrades) / Double(closedTrades.count)) * 100))% win rate)."

        var tradeHistoryDetails = ""
        for trade in trades.prefix(25) {
            let date = trade.timestamp.formatted(date: .abbreviated, time: .omitted)
            let action = trade.isBuy ? "BOUGHT" : "SOLD"
            tradeHistoryDetails += "- \(date): \(action) \(trade.quantity) \(trade.symbol) @ ₹\(String(format: "%.2f", trade.price))"
            if let realized = trade.realizedPnL {
                tradeHistoryDetails += " — realised P&L ₹\(String(format: "%.2f", realized))"
            }
            if !trade.thesis.isEmpty {
                tradeHistoryDetails += " — stated reason: \(trade.thesis)"
            }
            tradeHistoryDetails += "\n"
        }

        let completePortfolioContext = """
            Available Cash Balance: ₹\(cashBalance)
            Total Equity Valuation: ₹\(totalStocksValue)
            Total Invested Capital: ₹\(totalInvested)
            Total Combined Net Worth: ₹\(totalNetWorth)
            Unrealised Profit/Loss on open positions: ₹\(netPnL) (\(String(format: "%.2f", netPnLPercent))%)
            Realised Profit/Loss from closed positions: ₹\(String(format: "%.2f", realizedPnL))
            Capital deposited by the user (the denominator for any honest return figure): ₹\(String(format: "%.2f", netDeposits))
            Track record: \(winRateLine)
            
            Current Active Holdings Breakdown:
            \(stockHoldingsDetails.isEmpty ? "No active stock positions held currently." : stockHoldingsDetails)
            
            Trade History (up to 25 most recent, newest first):
            \(tradeHistoryDetails.isEmpty ? "No trades recorded yet." : tradeHistoryDetails)
            """
        
        Task {
            let thinkingMessage = ChatMessage(text: "TradeX AI is analyzing market matrices...", isUser: false)
            await MainActor.run {
                conversation.append(thinkingMessage)
            }
            
            var targetReply = ""
            do {
                targetReply = try await GroqService.shared.generateInsight(
                    userPrompt: userQuery,
                    portfolioContext: completePortfolioContext
                )
            } catch {
                print("🚨 GROQ DIAGNOSTIC ERROR DETECTED: \(error.localizedDescription)")
                targetReply = "Groq Error: \(error.localizedDescription)"
            }
            
            let finalReply = targetReply
            await MainActor.run {
                // Removed by identity. Matching on `last` left the placeholder stranded
                // in the transcript whenever a second message was sent while the first
                // was still in flight — easy to hit now that a review takes a while.
                if let index = conversation.firstIndex(where: { $0.id == thinkingMessage.id }) {
                    conversation.remove(at: index)
                }
                conversation.append(ChatMessage(text: finalReply, isUser: false))
            }
        }
    }
}


extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

struct RoundedCornerShape: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
