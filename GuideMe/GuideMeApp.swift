//
//  GuideMeApp.swift
//  GuideMe
//
//  Created by Aidan Andrews on 3/1/25.
//

import SwiftUI

@main
struct GuideMeApp: App {
    @StateObject private var appState = AppState()
    @State private var menuBarManager: MenuBarManager?
    
    var body: some Scene {
        WindowGroup {
            // Empty view since we're using a menubar app
            Color.clear.opacity(0)
                .frame(width: 0, height: 0)
                .onAppear {
                    // Initialize the menu bar manager
                    menuBarManager = MenuBarManager(appState: appState)
                    
                    // Hide the main window
                    if let window = NSApplication.shared.windows.first {
                        window.close()
                    }
                }
        }
        .commands {
            // Remove menu bar items that don't make sense for a menubar app
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About GuideMe") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }
        }
        .environmentObject(appState)
    }
}
