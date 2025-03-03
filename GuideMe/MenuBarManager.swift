//
//  MenuBarManager.swift
//  GuideMe
//
//  Created by Aidan Andrews on 3/1/25.
//

import SwiftUI
import AppKit

class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var appState: AppState
    
    init(appState: AppState) {
        self.appState = appState
        super.init()
        setupMenuBar()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "questionmark.circle.fill", accessibilityDescription: "GuideMe")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    @objc private func togglePopover(_ sender: AnyObject) {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(sender)
                appState.hideWindow()
            } else {
                if popover == nil {
                    let contentView = NSHostingView(rootView: ContentView().environmentObject(appState))
                    popover = NSPopover()
                    popover?.contentViewController = NSViewController()
                    popover?.contentViewController?.view = contentView
                    popover?.contentSize = NSSize(width: 400, height: 600)
                    popover?.behavior = .transient
                }
                
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                appState.showWindow()
                
                // Make window stay on top
                if let window = popover?.contentViewController?.view.window {
                    window.level = .floating
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                }
            }
        }
    }
} 