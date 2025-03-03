//
//  AppState.swift
//  GuideMe
//
//  Created by Aidan Andrews on 3/1/25.
//

import SwiftUI

class AppState: ObservableObject {
    @Published var isApiKeySet: Bool = false
    @Published var isWindowVisible: Bool = false
    @AppStorage("apiKey") private var storedApiKey: String = ""
    private var windowVisibilityTask: Task<Void, Never>? = nil
    
    init() {
        // Check if API key is already set
        isApiKeySet = !storedApiKey.isEmpty
    }
    
    func setApiKey(_ key: String) {
        storedApiKey = key
        isApiKeySet = !key.isEmpty
    }
    
    func toggleWindow() {
        isWindowVisible.toggle()
    }
    
    func showWindow() {
        // Cancel any pending hide tasks
        windowVisibilityTask?.cancel()
        windowVisibilityTask = nil
        
        // Show window on main thread
        DispatchQueue.main.async {
            self.isWindowVisible = true
        }
    }
    
    func hideWindow() {
        // Cancel any pending tasks
        windowVisibilityTask?.cancel()
        
        // Create a new task for hiding the window
        windowVisibilityTask = Task {
            // Hide window on main thread
            await MainActor.run {
                self.isWindowVisible = false
            }
        }
    }
} 