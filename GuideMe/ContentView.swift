//
//  ContentView.swift
//  GuideMe
//
//  Created by Aidan Andrews on 3/1/25.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("apiKey") private var apiKey: String = ""
    @State private var temporaryApiKey: String = ""
    @State private var showApiKeyView: Bool = true
    @EnvironmentObject private var appState: AppState
    
    var body: some View {
        Group {
            if appState.isApiKeySet {
                InstructionView()
                    .transition(.opacity)
            } else {
                ApiKeyView(apiKey: $temporaryApiKey, onSave: {
                    appState.setApiKey(temporaryApiKey)
                    apiKey = temporaryApiKey
                })
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: appState.isApiKeySet)
    }
}

struct ApiKeyView: View {
    @Binding var apiKey: String
    var onSave: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            
            Text("Welcome to GuideMe")
                .font(.headline)
            
            Text("Please enter your OpenAI API key to continue")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            SecureField("API Key", text: $apiKey)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)
            
            Button("Save") {
                if !apiKey.isEmpty {
                    onSave()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKey.isEmpty)
            
            Link("Need an API key?", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.caption)
        }
        .padding()
        .frame(width: 350, height: 300)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
