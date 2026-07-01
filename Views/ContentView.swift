//
//  Constants.swift
//  test
//
//  Created by vedant jagdale on 29/06/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab(Constants.DashboardString, systemImage: Constants.Dashboardiconstring) {
                NavigationStack {
                    DashboardView()
                }
            }
            
            Tab(Constants.Explorestring, systemImage: Constants.Exploreiconstring) {
                NavigationStack {
                    MarketExplorerView()
                }
            }
            
            Tab(Constants.Portfoliostring, systemImage: Constants.Portfolioiconstring) {
                NavigationStack {
                    PortfolioView()
                }
            }
            
            Tab(Constants.Aistring, systemImage: Constants.Aiiconstring) {
                NavigationStack {
                    AIAssistantView()
                }
            }
        }
    }
}
struct DashboardView: View {
    var body: some View {
        Text("Dashboard Screen")
            .font(.title)
    }
}

struct MarketExplorerView: View {
    var body: some View {
        Text("Market Explorer Screen")
            .font(.title)
    }
}

struct PortfolioView: View {
    var body: some View {
        Text("Portfolio Screen")
            .font(.title)
    }
}

struct AIAssistantView: View {
    var body: some View {
        Text("AI Assistant & Journal")
            .font(.title)
    }
}

#Preview {
    ContentView()
}


