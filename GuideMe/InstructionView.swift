//
//  InstructionView.swift
//  GuideMe
//
//  Created by Aidan Andrews on 3/1/25.
//

import SwiftUI
import Combine
import MarkdownUI
import ScreenCaptureKit
import CoreGraphics

struct InstructionView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("apiKey") private var apiKey: String = ""
    @State private var query: String = ""
    @State private var instructions: String = ""
    @State private var isLoading: Bool = false
    @State private var isCapturingScreen: Bool = false
    @State private var errorMessage: String? = nil
    @State private var cancellables = Set<AnyCancellable>()
    @State private var isCheckingPermission: Bool = false
    @State private var hasScreenCapturePermission: Bool = false
    
    // Add state for debug screenshot
    @State private var debugScreenshot: NSImage? = nil
    @State private var showDebugView: Bool = false
    
    // Add state for debug info
    @State private var debugInfoItems: [OpenAIService.DebugInfo] = []
    @State private var selectedDebugTab: DebugTab = .screenshot
    
    // Add state for step-based system
    @State private var useStepMode: Bool = false
    @State private var currentStep: Int = 0
    @State private var questionText: String = ""
    @State private var showQuestionField: Bool = false
    
    enum DebugTab {
        case screenshot
        case apiDetails
    }
    
    private let openAIService = OpenAIService()
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                
                Text("GuideMe")
                    .font(.headline)
                
                Spacer()
                
                // Add debug toggle button
                Button(action: {
                    showDebugView.toggle()
                }) {
                    Image(systemName: "ladybug.fill")
                        .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .help("Toggle Debug View")
                
                Button(action: {
                    appState.hideWindow()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            
            // Add toggle for step mode
            Toggle(isOn: $useStepMode) {
                Text("Step-by-Step Mode")
                    .font(.subheadline)
            }
            .toggleStyle(SwitchToggleStyle(tint: .blue))
            .padding(.horizontal)
            
            Divider()
            
            // Debug view with tabs
            if showDebugView {
                VStack(spacing: 8) {
                    HStack {
                        Text("Debug Panel")
                            .font(.headline)
                            .foregroundColor(.orange)
                        
                        Spacer()
                        
                        Button(action: {
                            debugInfoItems.removeAll()
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Clear Debug Logs")
                    }
                    
                    Picker("Debug View", selection: $selectedDebugTab) {
                        Text("Screenshot").tag(DebugTab.screenshot)
                        Text("API Details").tag(DebugTab.apiDetails)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    
                    if selectedDebugTab == .screenshot, let screenshot = debugScreenshot {
                        VStack {
                            Image(nsImage: screenshot)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 200)
                                .border(Color.gray, width: 1)
                            
                            Text("Screenshot size: \(Int(screenshot.size.width))×\(Int(screenshot.size.height))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            HStack {
                                Button("Save Screenshot") {
                                    saveDebugScreenshot(screenshot)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                
                                Button("Copy to Clipboard") {
                                    copyScreenshotToClipboard(screenshot)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.top, 4)
                        }
                    } else if selectedDebugTab == .apiDetails {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if debugInfoItems.isEmpty {
                                    Text("No API requests recorded yet")
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding()
                                } else {
                                    ForEach(debugInfoItems.indices, id: \.self) { index in
                                        let item = debugInfoItems[index]
                                        DebugInfoView(item: item)
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                        .frame(maxHeight: 200)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal)
                    }
                }
                .padding(.horizontal)
            }
            
            // Show different UI based on mode
            if useStepMode {
                stepModeView
            } else {
                standardModeView
            }
        }
        .frame(width: 400, height: 600)
        .padding(.vertical)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
        .overlay(
            Group {
                if isCapturingScreen {
                    Color.black.opacity(0.1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .edgesIgnoringSafeArea(.all)
                        .onAppear {
                            // Delay screenshot to allow user to arrange windows
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                if useStepMode {
                                    startStepBasedProcess()
                                } else {
                                    startStreamingRequest()
                                }
                            }
                        }
                }
            }
        )
        .onAppear {
            checkScreenCapturePermission()
            
            // Subscribe to screenshot updates
            openAIService.lastCapturedScreenshot
                .receive(on: DispatchQueue.main)
                .sink { image in
                    debugScreenshot = image
                }
                .store(in: &cancellables)
            
            // Subscribe to debug info updates
            openAIService.debugInfo
                .receive(on: DispatchQueue.main)
                .sink { info in
                    debugInfoItems.append(info)
                }
                .store(in: &cancellables)
        }
    }
    
    // Standard mode view
    private var standardModeView: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("What do you want to learn how to do?", text: $query)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(isLoading)
                
                Button(action: generateInstructions) {
                    Image(systemName: isLoading ? "hourglass" : "paperplane.fill")
                }
                .disabled(query.isEmpty || isLoading)
            }
            .padding(.horizontal)
            
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }
            
            ScrollView {
                if instructions.isEmpty && !isLoading {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        
                        Text("Ask me how to do something on your Mac")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Text("For example: \"take a screenshot\" or \"setup email on Mail app\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        if !hasScreenCapturePermission && !isCheckingPermission {
                            Button("Request Screen Recording Permission") {
                                requestScreenCapturePermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 10)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if isCapturingScreen {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Capturing your screen to provide context-aware instructions...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if isLoading && instructions.isEmpty {
                    ProgressView("Generating instructions...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                } else {
                    Markdown(instructions)
                        .padding()
                        .id(instructions.hash) // Force scroll update when content changes
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
        }
    }
    
    // Step mode view
    private var stepModeView: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("What do you want to learn how to do?", text: $query)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(isLoading || currentStep > 0)
                
                Button(action: {
                    if currentStep == 0 {
                        // Start first step
                        currentStep = 1
                        generateFirstStep()
                    }
                }) {
                    Image(systemName: isLoading ? "hourglass" : "paperplane.fill")
                }
                .disabled(query.isEmpty || isLoading || currentStep > 0)
                
                if currentStep > 0 {
                    Button(action: resetStepProcess) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Reset and start over")
                }
            }
            .padding(.horizontal)
            
            if currentStep > 0 {
                HStack {
                    Text("Step \(currentStep) of task: \(query)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
            }
            
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }
            
            ScrollView {
                if currentStep == 0 && !isLoading {
                    VStack(spacing: 20) {
                        Image(systemName: "list.number")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        
                        Text("Step-by-Step Mode")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Text("Enter your task and I'll guide you through each step")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        if !hasScreenCapturePermission && !isCheckingPermission {
                            Button("Request Screen Recording Permission") {
                                requestScreenCapturePermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 10)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if isCapturingScreen {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Capturing your screen...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if isLoading {
                    ProgressView(currentStep == 0 ? "Preparing first step..." : "Processing...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                } else if !instructions.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Step \(currentStep)")
                                .font(.headline)
                                .foregroundColor(.blue)
                            
                            Spacer()
                        }
                        
                        Markdown(instructions)
                            .id(instructions.hash) // Force scroll update when content changes
                        
                        Spacer()
                        
                        if showQuestionField {
                            TextField("Type your question here...", text: $questionText)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .padding(.top)
                            
                            HStack {
                                Button("Cancel") {
                                    showQuestionField = false
                                    questionText = ""
                                }
                                .buttonStyle(.bordered)
                                
                                Spacer()
                                
                                Button("Ask Question") {
                                    // Save question text and reset the field
                                    _ = self.questionText
                                    askQuestion()
                                    self.showQuestionField = false
                                    self.questionText = ""
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(questionText.isEmpty)
                            }
                        } else {
                            HStack {
                                Button("Ask a Question") {
                                    showQuestionField = true
                                }
                                .buttonStyle(.bordered)
                                
                                Spacer()
                                
                                Button("Next Step") {
                                    getNextStep()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .padding()
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
        }
    }
    
    private func checkScreenCapturePermission() {
        isCheckingPermission = true
        
        DispatchQueue.main.async {
            hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
            isCheckingPermission = false
            
            if !hasScreenCapturePermission {
                errorMessage = "Screen recording permission is required. Please grant permission in System Settings > Privacy & Security > Screen Recording."
            } else {
                errorMessage = nil
            }
        }
    }
    
    private func requestScreenCapturePermission() {
        isCheckingPermission = true
        
        DispatchQueue.main.async {
            _ = CGRequestScreenCaptureAccess()
            
            // Check if permission was granted
            hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
            isCheckingPermission = false
            
            if !hasScreenCapturePermission {
                errorMessage = "Screen recording permission is required. Please grant permission in System Settings > Privacy & Security > Screen Recording."
            } else {
                errorMessage = nil
            }
        }
    }
    
    private func generateInstructions() {
        guard !query.isEmpty else { return }
        
        // Check if screen recording permission is granted
        let hasPermission = CGPreflightScreenCaptureAccess()
        
        if !hasPermission {
            errorMessage = "Screen recording permission is required. Please grant permission in System Settings > Privacy & Security > Screen Recording."
            return
        }
        
        // Reset states
        isCapturingScreen = true
        isLoading = true
        errorMessage = nil
        instructions = ""
        
        // Use a longer delay to allow user to prepare their screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.startStreamingRequest()
        }
    }
    
    private func startStreamingRequest() {
        // Cancel any existing subscriptions
        cancellables.removeAll()
        
        // Subscribe to screenshot updates
        openAIService.lastCapturedScreenshot
            .receive(on: DispatchQueue.main)
            .sink { image in
                debugScreenshot = image
            }
            .store(in: &cancellables)
        
        // Hide the GuideMe window briefly for clean screenshot
        appState.hideWindow()
        
        // Small delay to ensure window is hidden
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Start streaming request
            self.isCapturingScreen = false
            
            self.openAIService.streamInstructions(query: self.query, apiKey: self.apiKey)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        self.isLoading = false
                        
                        if case .failure(let error) = completion {
                            self.errorMessage = "Error: \(error.localizedDescription)"
                            
                            // Show debug view automatically on error
                            self.showDebugView = true
                        }
                        
                        // Show the window again
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.appState.showWindow()
                        }
                    },
                    receiveValue: { chunk in
                        // Append each chunk to the instructions
                        self.instructions += chunk
                    }
                )
                .store(in: &self.cancellables)
            
            // Show the window again after a longer delay to ensure screenshot is complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.appState.showWindow()
            }
        }
    }
    
    private func saveDebugScreenshot(_ image: NSImage) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.jpeg]
        savePanel.nameFieldStringValue = "screenshot_\(Date().timeIntervalSince1970).jpg"
        savePanel.message = "Save Debug Screenshot"
        savePanel.prompt = "Save"
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                guard let tiffData = image.tiffRepresentation,
                      let bitmapRep = NSBitmapImageRep(data: tiffData),
                      let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                    return
                }
                
                do {
                    try jpegData.write(to: url)
                } catch {
                    print("Error saving screenshot: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func copyScreenshotToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
    
    // Step-based process methods
    private func generateFirstStep() {
        guard !query.isEmpty else { return }
        
        // Check if screen recording permission is granted
        let hasPermission = CGPreflightScreenCaptureAccess()
        
        if !hasPermission {
            errorMessage = "Screen recording permission is required. Please grant permission in System Settings > Privacy & Security > Screen Recording."
            return
        }
        
        // Reset states
        isCapturingScreen = true
        isLoading = true
        errorMessage = nil
        instructions = ""
        
        // Use a delay to allow user to prepare their screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.startStepBasedProcess()
        }
    }
    
    private func startStepBasedProcess() {
        // Cancel any existing subscriptions
        cancellables.removeAll()
        
        // Subscribe to screenshot updates
        openAIService.lastCapturedScreenshot
            .receive(on: DispatchQueue.main)
            .sink { image in
                debugScreenshot = image
            }
            .store(in: &cancellables)
        
        // Hide the GuideMe window briefly for clean screenshot
        appState.hideWindow()
        
        // Small delay to ensure window is hidden
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Start step-based process
            self.isCapturingScreen = false
            
            let stepSystemPrompt = "You are an assistant that helps users with computer tasks step by step. " +
                "I'll provide a screenshot of the user's current desktop and their query. " +
                "Provide ONLY THE NEXT SINGLE STEP to accomplish their task on macOS. " +
                "Be concise but clear. Format your response in markdown. " +
                "DO NOT provide multiple steps or the complete solution - JUST ONE STEP AT A TIME."
            
            self.openAIService.streamStepInstruction(query: self.query, apiKey: self.apiKey, systemPrompt: stepSystemPrompt)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        self.isLoading = false
                        
                        if case .failure(let error) = completion {
                            self.errorMessage = "Error: \(error.localizedDescription)"
                            
                            // Show debug view automatically on error
                            self.showDebugView = true
                        }
                        
                        // Show the window again
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.appState.showWindow()
                        }
                    },
                    receiveValue: { chunk in
                        // Append each chunk to the instructions
                        self.instructions += chunk
                    }
                )
                .store(in: &self.cancellables)
            
            // Show the window again after a longer delay to ensure screenshot is complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.appState.showWindow()
            }
        }
    }
    
    private func getNextStep() {
        guard currentStep > 0 else { return }
        
        // Increment step counter
        currentStep += 1
        
        // Reset instruction and set loading state
        instructions = ""
        isLoading = true
        isCapturingScreen = true
        
        // Use a delay to allow user to prepare their screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.startNextStepProcess()
        }
    }
    
    private func startNextStepProcess() {
        // Cancel any existing subscriptions
        cancellables.removeAll()
        
        // Subscribe to screenshot updates
        openAIService.lastCapturedScreenshot
            .receive(on: DispatchQueue.main)
            .sink { image in
                debugScreenshot = image
            }
            .store(in: &cancellables)
        
        // Hide the GuideMe window briefly for clean screenshot
        appState.hideWindow()
        
        // Small delay to ensure window is hidden
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Start next step process
            self.isCapturingScreen = false
            
            let nextStepPrompt = "Provide the NEXT STEP (Step \(self.currentStep)) for the task: \"\(self.query)\". " +
                "Based on the new screenshot, determine what progress has been made and what the user should do next. " +
                "Provide ONLY ONE CLEAR, CONCISE STEP - do not list multiple steps or the complete solution." +
                "Tell the user exactly what you see and give them the next step."
            
            self.openAIService.streamStepInstruction(query: nextStepPrompt, apiKey: self.apiKey, isFollowUpStep: true)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        self.isLoading = false
                        
                        if case .failure(let error) = completion {
                            self.errorMessage = "Error: \(error.localizedDescription)"
                            
                            // Show debug view automatically on error
                            self.showDebugView = true
                        }
                        
                        // Show the window again
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.appState.showWindow()
                        }
                    },
                    receiveValue: { chunk in
                        // Append each chunk to the instructions
                        self.instructions += chunk
                    }
                )
                .store(in: &self.cancellables)
            
            // Show the window again after a longer delay to ensure screenshot is complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.appState.showWindow()
            }
        }
    }
    
    private func askQuestion() {
        guard !questionText.isEmpty else { return }
        
        // Increment step counter
        currentStep += 1
        
        // Reset instruction and set loading state
        instructions = ""
        isLoading = true
        isCapturingScreen = true
        showQuestionField = false
        
        // Use a delay to allow user to prepare their screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.startQuestionProcess()
        }
    }
    
    private func startQuestionProcess() {
        // Cancel any existing subscriptions
        cancellables.removeAll()
        
        // Subscribe to screenshot updates
        openAIService.lastCapturedScreenshot
            .receive(on: DispatchQueue.main)
            .sink { image in
                debugScreenshot = image
            }
            .store(in: &cancellables)
        
        // Hide the GuideMe window briefly for clean screenshot
        appState.hideWindow()
        
        // Small delay to ensure window is hidden
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Start question process
            self.isCapturingScreen = false
            
            let questionPrompt = "The user is working on: \"\(self.query)\" and has a question: \"\(self.questionText)\". " +
                "Based on the screenshot and their question, provide a helpful answer FOLLOWED BY the next step they should take. " +
                "Be concise but clear and answer their specific question first."
            
            self.openAIService.streamStepInstruction(query: questionPrompt, apiKey: self.apiKey, isFollowUpStep: true)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        self.isLoading = false
                        
                        if case .failure(let error) = completion {
                            self.errorMessage = "Error: \(error.localizedDescription)"
                            
                            // Show debug view automatically on error
                            self.showDebugView = true
                        }
                        
                        // Show the window again
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.appState.showWindow()
                        }
                    },
                    receiveValue: { chunk in
                        // Append each chunk to the instructions
                        self.instructions += chunk
                    }
                )
                .store(in: &self.cancellables)
            
            // Show the window again after a longer delay to ensure screenshot is complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.appState.showWindow()
            }
        }
    }
    
    private func resetStepProcess() {
        // Reset all step-related state
        currentStep = 0
        instructions = ""
        showQuestionField = false
        questionText = ""
        errorMessage = nil
    }
}

// Debug info view component
struct DebugInfoView: View {
    let item: OpenAIService.DebugInfo
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Image(systemName: getIconForType(item.type))
                        .foregroundColor(getColorForType(item.type))
                    
                    Text(item.message)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    Text(formatTimestamp(item.timestamp))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.details.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(alignment: .top) {
                            Text(key)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 120, alignment: .leading)
                            
                            Text(value)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                        .padding(.leading, 24)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
    
    private func getIconForType(_ type: OpenAIService.DebugInfo.InfoType) -> String {
        switch type {
        case .screenshot: return "camera.fill"
        case .request: return "arrow.up.circle.fill"
        case .response: return "arrow.down.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    private func getColorForType(_ type: OpenAIService.DebugInfo.InfoType) -> Color {
        switch type {
        case .screenshot: return .blue
        case .request: return .green
        case .response: return .purple
        case .error: return .red
        }
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
} 
