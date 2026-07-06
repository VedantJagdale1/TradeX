//
//  SwiftUIView.swift
//  TradeX
//
//  Created by vedant jagdale on 06/07/26.
//

import SwiftUI

struct AppIconPreviewView: View {
    var body: some View {
        VStack {
            
            ZStack {
                
                Color(red: 0.08, green: 0.08, blue: 0.10)
                
                
                RadialGradient(
                    colors: [Color.purple.opacity(0.25), Color.clear],
                    center: .topTrailing,
                    startRadius: 5,
                    endRadius: 120
                )
                
                
                VStack(spacing: 6) {
                    HStack(alignment: .bottom, spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .bottom, endPoint: .top))
                            .frame(width: 10, height: 25)
                        
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .bottom, endPoint: .top))
                            .frame(width: 10, height: 45)
                        
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [.indigo, .green], startPoint: .bottom, endPoint: .top))
                            .frame(width: 10, height: 65)
                        
                        
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.green)
                            .padding(.bottom, 50)
                            .padding(.leading, -2)
                    }
                }
                .offset(x: -4, y: 8)
                
                
                Text("T")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .offset(x: -22, y: -22)
                    .opacity(0.15)
            }
            .frame(width: 120, height: 120)
            .cornerRadius(26)
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 8)
            
            Text("TradeX Icon Preview")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

#Preview {
    AppIconPreviewView()
}
