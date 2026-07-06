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



#Preview {
    ContentView()
}


