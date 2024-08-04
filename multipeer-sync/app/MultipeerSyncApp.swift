//
//  multipeer_syncApp.swift
//  multipeer-sync
//
//  Created by Pasin Suriyentrakorn on 8/3/24.
//

import SwiftUI

@main
struct MultipeerSyncApp: App {
    private let service = { return DatabaseService() }()
    
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(ContentViewModel(service))
        }
    }
}
