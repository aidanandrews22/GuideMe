//
//  OpenAIService.swift
//  GuideMe
//
//  Created by Aidan Andrews on 3/1/25.
//

import Foundation
import Combine
import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreGraphics

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case networkError(Error)
    case decodingError(Error)
    case apiError(String)
    case screenshotError
    case screenCapturePermissionDenied
    case noShareableContent
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from server"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .decodingError(let error): return "Could not decode response: \(error.localizedDescription)"
        case .apiError(let message): return message
        case .screenshotError: return "Failed to capture screen"
        case .screenCapturePermissionDenied: return "Screen capture permission denied"
        case .noShareableContent: return "No shareable content available"
        }
    }
}

struct OpenAIRequest: Encodable {
    let model: String = "gpt-4o-mini"
    let messages: [Message]
    let temperature: Double = 0.7
    let stream: Bool
    
    struct Message: Encodable {
        let role: String
        let content: Content
        
        // For text-only messages
        init(role: String, content: String) {
            self.role = role
            self.content = Content.string(content)
        }
        
        // For messages with mixed content (text and images)
        init(role: String, contentItems: [ContentItem]) {
            self.role = role
            self.content = Content.array(contentItems)
        }
    }
    
    enum Content: Encodable {
        case string(String)
        case array([ContentItem])
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let string):
                try container.encode(string)
            case .array(let array):
                try container.encode(array)
            }
        }
    }
    
    struct ContentItem: Encodable {
        let type: String
        let text: String?
        let image_url: ImageURL?
        
        // For text content
        init(text: String) {
            self.type = "text"
            self.text = text
            self.image_url = nil
        }
        
        // For image content
        init(imageBase64: String) {
            self.type = "image_url"
            self.text = nil
            self.image_url = ImageURL(url: "data:image/jpeg;base64,\(imageBase64)")
        }
    }
    
    struct ImageURL: Encodable {
        let url: String
    }
}

struct OpenAIChunkResponse: Decodable {
    let choices: [Choice]?
    
    struct Choice: Decodable {
        let delta: Delta
        
        struct Delta: Decodable {
            let content: String?
        }
    }
}

struct OpenAIResponse: Decodable {
    let id: String
    let choices: [Choice]
    let usage: Usage
    
    struct Choice: Decodable {
        let message: Message
        let index: Int
        let finishReason: String?
        
        enum CodingKeys: String, CodingKey {
            case message, index
            case finishReason = "finish_reason"
        }
    }
    
    struct Message: Decodable {
        let role: String
        let content: String
    }
    
    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
        
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

class OpenAIService {
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private var screenCaptureStream: SCStream?
    private var streamOutput: ScreenCaptureStreamOutput?
    
    // Add a publisher for debugging the captured screenshot
    var lastCapturedScreenshot = PassthroughSubject<NSImage?, Never>()
    
    // Add a publisher for debug information
    var debugInfo = PassthroughSubject<DebugInfo, Never>()
    
    // Debug info structure
    struct DebugInfo {
        let timestamp: Date
        let type: InfoType
        let message: String
        let details: [String: String]
        
        enum InfoType {
            case screenshot
            case request
            case response
            case error
        }
    }
    
    // Check screen capture permission
    private func checkScreenCapturePermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }
    
    // Request screen capture permission
    private func requestScreenCapturePermission() {
        _ = CGRequestScreenCaptureAccess()
    }
    
    // Get shareable content
    private func getShareableContent() async throws -> SCShareableContent {
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
    
    // Capture screenshot using ScreenCaptureKit
    private func captureScreen() async throws -> String {
        // Check if screen recording permission is granted
        let isAuthorized = checkScreenCapturePermission()
        if !isAuthorized {
            requestScreenCapturePermission()
            // Check again after request
            if !checkScreenCapturePermission() {
                throw APIError.screenCapturePermissionDenied
            }
        }
        
        // Clean up any existing capture session
        if let existingStream = self.screenCaptureStream {
            try? await existingStream.stopCapture()
            self.screenCaptureStream = nil
            self.streamOutput = nil
        }
        
        // Get available screen content
        let availableContent: SCShareableContent
        do {
            availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("Error getting shareable content: \(error)")
            throw APIError.noShareableContent
        }
        
        // Get the main display
        guard let mainDisplay = availableContent.displays.first else {
            throw APIError.noShareableContent
        }
        
        // Configure capture settings
        let configuration = SCStreamConfiguration()
        configuration.width = mainDisplay.width
        configuration.height = mainDisplay.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = true
        
        // Get our app's bundle ID
        let myBundleID = Bundle.main.bundleIdentifier!
        
        // Filter out our own app's windows
        let excludedWindows = availableContent.windows.filter { window in
            window.owningApplication?.bundleIdentifier == myBundleID
        }
        
        // Create filter to capture everything except our app
        let filter = SCContentFilter(
            display: mainDisplay,
            excludingWindows: excludedWindows
        )
        
        // Create stream output handler
        let streamOutput = ScreenCaptureStreamOutput()
        streamOutput.debugImageHandler = { [weak self] image in
            // Send the captured image through the publisher for debugging
            self?.lastCapturedScreenshot.send(image)
        }
        self.streamOutput = streamOutput
        
        // Create and start the capture stream
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        
        do {
            try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
        } catch {
            print("Error starting capture: \(error)")
            throw APIError.screenshotError
        }
        
        // Store the stream for later cleanup
        self.screenCaptureStream = stream
        
        // Capture immediately with no timeout
        return try await withCheckedThrowingContinuation { continuation in
            streamOutput.captureCompletionHandler = { result in
                switch result {
                case .success(let imageData):
                    print("✅ Successfully captured screenshot: \(imageData.prefix(100))...")
                    continuation.resume(returning: imageData)
                case .failure(let error):
                    print("❌ Failed to capture screenshot: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
                
                // Stop the capture after getting the frame
                Task {
                    try? await stream.stopCapture()
                    self.screenCaptureStream = nil
                    self.streamOutput = nil
                }
            }
        }
    }
    
    // Stream response
    func streamInstructions(query: String, apiKey: String) -> AnyPublisher<String, APIError> {
        let streamSubject = PassthroughSubject<String, APIError>()
        
        Task {
            do {
                // Capture the screenshot
                let screenBase64 = try await captureScreen()
                print("📸 Screenshot captured with base64 length: \(screenBase64.count)")
                
                // Send debug info
                debugInfo.send(DebugInfo(
                    timestamp: Date(),
                    type: .screenshot,
                    message: "Screenshot Captured",
                    details: ["base64_length": "\(screenBase64.count)"]
                ))
                
                guard let url = URL(string: baseURL) else {
                    streamSubject.send(completion: .failure(.invalidURL))
                    return
                }
                
                // Create system prompt with context about screenshot
                let systemMessage = OpenAIRequest.Message(
                    role: "system",
                    content: "You are an assistant that helps users with computer tasks. I'll provide a screenshot of the user's current desktop and their query. Provide clear, step-by-step instructions on how to accomplish the task on macOS, referencing the visible elements in the screenshot when relevant. Format your response in markdown with numbered steps. Be concise but thorough."
                )
                
                // Create content items for user message (text + screenshot)
                let userContentItems = [
                    OpenAIRequest.ContentItem(text: "Here is the user's query that you must respond to: \(query). Here is a screenshot of the user's current screen for context."),
                    OpenAIRequest.ContentItem(imageBase64: screenBase64)
                ]
                
                let userMessage = OpenAIRequest.Message(
                    role: "user",
                    contentItems: userContentItems
                )
                
                let request = OpenAIRequest(
                    messages: [systemMessage, userMessage],
                    stream: true
                )
                
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                
                // Debug: Print request size
                let encoder = JSONEncoder()
                let requestData = try encoder.encode(request)
                print("📤 Request size: \(requestData.count) bytes")
                
                urlRequest.httpBody = requestData
                
                // Start streaming task
                await startStreamingTask(with: urlRequest, streamSubject: streamSubject)
                
            } catch {
                print("❌ Error in streamInstructions: \(error.localizedDescription)")
                
                // Send debug info
                debugInfo.send(DebugInfo(
                    timestamp: Date(),
                    type: .error,
                    message: "Error in streamInstructions",
                    details: ["error": error.localizedDescription]
                ))
                
                if let apiError = error as? APIError {
                    streamSubject.send(completion: .failure(apiError))
                } else {
                    streamSubject.send(completion: .failure(.networkError(error)))
                }
            }
        }
        
        return streamSubject.eraseToAnyPublisher()
    }
    
    // Stream step-based instructions
    func streamStepInstruction(query: String, apiKey: String, systemPrompt: String? = nil, isFollowUpStep: Bool = false) -> AnyPublisher<String, APIError> {
        let streamSubject = PassthroughSubject<String, APIError>()
        
        Task {
            do {
                // Capture the screenshot
                let screenBase64 = try await captureScreen()
                print("📸 Screenshot captured with base64 length: \(screenBase64.count)")
                
                // Send debug info
                debugInfo.send(DebugInfo(
                    timestamp: Date(),
                    type: .screenshot,
                    message: "Screenshot Captured for Step",
                    details: ["base64_length": "\(screenBase64.count)"]
                ))
                
                guard let url = URL(string: baseURL) else {
                    streamSubject.send(completion: .failure(.invalidURL))
                    return
                }
                
                // Create system prompt with context about screenshot
                let defaultSystemPrompt = "You are an assistant that helps users with computer tasks step by step. " +
                    "I'll provide a screenshot of the user's current desktop and their query. " +
                    "Provide ONLY THE NEXT SINGLE STEP to accomplish their task on macOS. " +
                    "Be concise but clear. Format your response in markdown. " +
                    "DO NOT provide multiple steps or the complete solution - JUST ONE STEP AT A TIME."
                
                let systemMessage = OpenAIRequest.Message(
                    role: "system",
                    content: systemPrompt ?? defaultSystemPrompt
                )
                
                // Create content items for user message (text + screenshot)
                let userContentItems: [OpenAIRequest.ContentItem]
                
                // Log the isFollowUpStep value for debugging
                print("📝 isFollowUpStep: \(isFollowUpStep)")
                
                if isFollowUpStep {
                    userContentItems = [
                        OpenAIRequest.ContentItem(text: "Here is the follow-up step request: \(query). Here is the current screenshot for context."),
                        OpenAIRequest.ContentItem(imageBase64: screenBase64)
                    ]
                } else {
                    userContentItems = [
                        OpenAIRequest.ContentItem(text: "Here is the user's request: \(query). Provide ONLY THE FIRST STEP. Here is a screenshot of the user's current screen."),
                        OpenAIRequest.ContentItem(imageBase64: screenBase64)
                    ]
                }
                
                let userMessage = OpenAIRequest.Message(
                    role: "user",
                    contentItems: userContentItems
                )
                
                let request = OpenAIRequest(
                    messages: [systemMessage, userMessage],
                    stream: true
                )
                
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                
                // Debug: Print request size
                let encoder = JSONEncoder()
                let requestData = try encoder.encode(request)
                print("📤 Step Request size: \(requestData.count) bytes")
                
                urlRequest.httpBody = requestData
                
                // Start streaming task
                await startStreamingTask(with: urlRequest, streamSubject: streamSubject)
                
            } catch {
                print("❌ Error in streamStepInstruction: \(error.localizedDescription)")
                
                // Send debug info
                debugInfo.send(DebugInfo(
                    timestamp: Date(),
                    type: .error,
                    message: "Error in streamStepInstruction",
                    details: ["error": error.localizedDescription]
                ))
                
                if let apiError = error as? APIError {
                    streamSubject.send(completion: .failure(apiError))
                } else {
                    streamSubject.send(completion: .failure(.networkError(error)))
                }
            }
        }
        
        return streamSubject.eraseToAnyPublisher()
    }
    
    private func startStreamingTask(with request: URLRequest, streamSubject: PassthroughSubject<String, APIError>) async {
        do {
            // Debug the request
            debugRequest(request)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                streamSubject.send(completion: .failure(.invalidResponse))
                return
            }
            
            // Debug the response
            print("📥 Response status code: \(httpResponse.statusCode)")
            
            // Log the raw response data
            let rawResponseString = String(data: data, encoding: .utf8) ?? "Could not decode response data"
            print("📥 RAW RESPONSE DATA (first 2000 chars): \(rawResponseString.prefix(2000))")
            
            // Log the full response to a file
            saveResponseToFile(rawResponseString, isError: !(200...299).contains(httpResponse.statusCode))
            
            var responseDebugDetails = [String: String]()
            responseDebugDetails["status_code"] = "\(httpResponse.statusCode)"
            responseDebugDetails["headers"] = httpResponse.allHeaderFields.keys.map { "\($0)" }.joined(separator: ", ")
            responseDebugDetails["data_size"] = "\(data.count) bytes"
            
            if !(200...299).contains(httpResponse.statusCode) {
                // Try to extract error message from response
                if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = errorData["error"] as? [String: Any],
                   let message = errorObj["message"] as? String {
                    print("❌ API Error: \(message)")
                    responseDebugDetails["error"] = message
                    streamSubject.send(completion: .failure(.apiError("API Error: \(message)")))
                } else {
                    print("❌ HTTP Error: \(httpResponse.statusCode)")
                    responseDebugDetails["error"] = "HTTP Error: \(httpResponse.statusCode)"
                    streamSubject.send(completion: .failure(.apiError("HTTP Error: \(httpResponse.statusCode)")))
                }
                
                // Send debug info for error response
                debugInfo.send(DebugInfo(
                    timestamp: Date(),
                    type: .error,
                    message: "API Error Response",
                    details: responseDebugDetails
                ))
                
                return
            }
            
            // Process streaming data
            let dataString = String(decoding: data, as: UTF8.self)
            let lines = dataString.components(separatedBy: "\n")
            
            print("📄 Received \(lines.count) lines of data")
            responseDebugDetails["lines_count"] = "\(lines.count)"
            
            // Sample some of the response content for debugging
            if !lines.isEmpty {
                let sampleLines = min(5, lines.count)
                for i in 0..<sampleLines {
                    responseDebugDetails["line_\(i)"] = lines[i].prefix(100).description
                }
            }
            
            // Send debug info for successful response
            debugInfo.send(DebugInfo(
                timestamp: Date(),
                type: .response,
                message: "API Response",
                details: responseDebugDetails
            ))
            
            var contentReceived = false
            
            for line in lines {
                // Skip empty lines and "[DONE]" marker
                guard !line.isEmpty else { continue }
                
                // Check if line starts with "data: "
                if line.hasPrefix("data: ") {
                    let dataContent = line.dropFirst(6) // Remove "data: " prefix
                    
                    // Check for the completion marker
                    if dataContent == "[DONE]" {
                        continue
                    }
                    
                    if let processedContent = self.processStreamingLine(String(dataContent)) {
                        contentReceived = true
                        streamSubject.send(processedContent)
                    }
                }
            }
            
            // If no content was received, log this as a potential issue
            if !contentReceived {
                print("⚠️ No content was processed from the response")
                responseDebugDetails["warning"] = "No content was processed from the response"
                
                // Send debug info for this issue
                debugInfo.send(DebugInfo(
                    timestamp: Date(),
                    type: .error,
                    message: "No Content Processed",
                    details: responseDebugDetails
                ))
            }
            
            streamSubject.send(completion: .finished)
            
        } catch {
            print("❌ Network error: \(error.localizedDescription)")
            
            // Send debug info for network error
            debugInfo.send(DebugInfo(
                timestamp: Date(),
                type: .error,
                message: "Network Error",
                details: ["error": error.localizedDescription]
            ))
            
            streamSubject.send(completion: .failure(.networkError(error)))
        }
    }
    
    // Helper method to save response to file
    private func saveResponseToFile(_ responseString: String, isError: Bool = false) {
        let fileManager = FileManager.default
        
        // Get the Documents directory
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access Documents directory")
            return
        }
        
        // Create a GuideMe debug folder if it doesn't exist
        let debugDirectory = documentsDirectory.appendingPathComponent("GuideMe_Debug")
        
        do {
            if !fileManager.fileExists(atPath: debugDirectory.path) {
                try fileManager.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
            }
            
            // Create a filename with timestamp
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            let prefix = isError ? "error_response" : "response"
            let filename = "\(prefix)_\(timestamp).txt"
            
            let fileURL = debugDirectory.appendingPathComponent(filename)
            
            // Write to file
            try responseString.write(to: fileURL, atomically: true, encoding: .utf8)
            print("✅ Response saved to: \(fileURL.path)")
        } catch {
            print("❌ Error saving response: \(error.localizedDescription)")
        }
    }
    
    private func processStreamingLine(_ line: String) -> String? {
        guard !line.isEmpty else { return nil }
        
        do {
            let data = line.data(using: .utf8) ?? Data()
            let decoder = JSONDecoder()
            let response = try decoder.decode(OpenAIChunkResponse.self, from: data)
            
            if let content = response.choices?.first?.delta.content {
                return content
            }
        } catch {
            // Log the error but don't propagate it to avoid breaking the stream
            print("Error parsing chunk: \(error)")
            print("Problematic line: \(line)")
        }
        
        return nil
    }
    
    // Helper method to debug the request
    private func debugRequest(_ request: URLRequest) {
        print("🔍 DEBUG REQUEST:")
        print("📡 URL: \(request.url?.absoluteString ?? "unknown")")
        print("🔑 Headers: \(request.allHTTPHeaderFields?.keys.joined(separator: ", ") ?? "none")")
        
        var debugDetails = [String: String]()
        debugDetails["url"] = request.url?.absoluteString ?? "unknown"
        debugDetails["headers"] = request.allHTTPHeaderFields?.keys.joined(separator: ", ") ?? "none"
        
        if let httpBody = request.httpBody {
            print("📦 Body size: \(httpBody.count) bytes")
            debugDetails["body_size"] = "\(httpBody.count) bytes"
            
            // Save the raw request to file
            saveRequestToFile(httpBody)
            
            // Try to decode the request to check if it contains the image
            do {
                let decoder = JSONDecoder()
                let requestObj = try JSONSerialization.jsonObject(with: httpBody, options: []) as? [String: Any]
                
                // Log the raw request data (truncated for console)
                if let jsonData = try? JSONSerialization.data(withJSONObject: requestObj ?? [:], options: .prettyPrinted),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    print("📤 RAW REQUEST (first 2000 chars): \(jsonString.prefix(2000))")
                }
                
                if let messages = requestObj?["messages"] as? [[String: Any]] {
                    print("📨 Request contains \(messages.count) messages")
                    debugDetails["message_count"] = "\(messages.count)"
                    
                    for (index, message) in messages.enumerated() {
                        let role = message["role"] as? String ?? "unknown"
                        print("📝 Message \(index): role=\(role)")
                        debugDetails["message_\(index)_role"] = role
                        
                        if let content = message["content"] as? [[String: Any]] {
                            for (contentIndex, item) in content.enumerated() {
                                let type = item["type"] as? String ?? "unknown"
                                print("  - Content \(contentIndex): type=\(type)")
                                debugDetails["message_\(index)_content_\(contentIndex)_type"] = type
                                
                                if type == "image_url", let imageUrl = item["image_url"] as? [String: Any], let url = imageUrl["url"] as? String {
                                    if url.hasPrefix("data:image/jpeg;base64,") {
                                        let base64Length = url.count - "data:image/jpeg;base64,".count
                                        print("  - Image: base64 data (\(base64Length) chars)")
                                        debugDetails["message_\(index)_content_\(contentIndex)_image_size"] = "\(base64Length) chars"
                                        
                                        // Verify base64 format
                                        let base64Data = String(url.dropFirst("data:image/jpeg;base64,".count))
                                        if base64Data.count % 4 != 0 {
                                            print("⚠️ WARNING: Base64 data length is not a multiple of 4 (length: \(base64Data.count))")
                                            debugDetails["message_\(index)_content_\(contentIndex)_image_warning"] = "Base64 data length is not a multiple of 4"
                                        }
                                    } else {
                                        print("  - Image: \(url)")
                                        debugDetails["message_\(index)_content_\(contentIndex)_image_url"] = url
                                    }
                                }
                            }
                        } else if let content = message["content"] as? String {
                            print("  - Text content: \(content.prefix(50))...")
                            debugDetails["message_\(index)_content"] = String(content.prefix(50)) + "..."
                        }
                    }
                }
            } catch {
                print("⚠️ Could not parse request body: \(error.localizedDescription)")
                debugDetails["parse_error"] = error.localizedDescription
            }
        }
        
        // Send debug info through publisher
        debugInfo.send(DebugInfo(
            timestamp: Date(),
            type: .request,
            message: "API Request",
            details: debugDetails
        ))
    }
    
    // Helper method to save request to file
    private func saveRequestToFile(_ requestData: Data) {
        let fileManager = FileManager.default
        
        // Get the Documents directory
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access Documents directory")
            return
        }
        
        // Create a GuideMe debug folder if it doesn't exist
        let debugDirectory = documentsDirectory.appendingPathComponent("GuideMe_Debug")
        
        do {
            if !fileManager.fileExists(atPath: debugDirectory.path) {
                try fileManager.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
            }
            
            // Create a filename with timestamp
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            let filename = "request_\(timestamp).json"
            
            let fileURL = debugDirectory.appendingPathComponent(filename)
            
            // Try to create a pretty-printed version if possible
            if let jsonObject = try? JSONSerialization.jsonObject(with: requestData),
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted) {
                try prettyData.write(to: fileURL)
            } else {
                // Fall back to raw data if pretty printing fails
                try requestData.write(to: fileURL)
            }
            
            print("✅ Request saved to: \(fileURL.path)")
        } catch {
            print("❌ Error saving request: \(error.localizedDescription)")
        }
    }
    
    // Non-streaming method (kept for compatibility)
    func generateInstructions(query: String, apiKey: String) -> AnyPublisher<String, APIError> {
        return streamInstructions(query: query, apiKey: apiKey)
    }
}

// Stream output handler for ScreenCaptureKit
class ScreenCaptureStreamOutput: NSObject, SCStreamOutput {
    typealias CaptureResult = Result<String, APIError>
    var captureCompletionHandler: ((CaptureResult) -> Void)?
    var debugImageHandler: ((NSImage?) -> Void)?
    private var hasProcessedFrame = false
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, 
              CMSampleBufferIsValid(sampleBuffer) else { 
            return 
        }
        
        // Only process the first frame for the API
        if !hasProcessedFrame, let captureCompletionHandler = captureCompletionHandler {
            // Mark that we've processed a frame to avoid duplicate processing
            hasProcessedFrame = true
            
            guard let imageBuffer = sampleBuffer.imageBuffer else {
                captureCompletionHandler(.failure(.screenshotError))
                return
            }
            
            // Convert to base64 on a background thread to avoid UI blocking
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Convert CMSampleBuffer to CGImage
                    let ciImage = CIImage(cvPixelBuffer: imageBuffer)
                    let context = CIContext()
                    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                        DispatchQueue.main.async {
                            captureCompletionHandler(.failure(.screenshotError))
                        }
                        return
                    }
                    
                    // Convert to NSImage
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    
                    // Send the image for debugging
                    DispatchQueue.main.async {
                        self.debugImageHandler?(nsImage)
                    }
                    
                    // Save the screenshot to disk for debugging
                    self.saveScreenshotToDisk(nsImage)
                    
                    // Convert to JPEG data with compression
                    guard let tiffData = nsImage.tiffRepresentation,
                          let bitmapRep = NSBitmapImageRep(data: tiffData) else {
                        DispatchQueue.main.async {
                            captureCompletionHandler(.failure(.screenshotError))
                        }
                        return
                    }
                    
                    // Try different compression levels if needed
                    var compressionFactor: CGFloat = 0.7
                    var imageData: Data?
                    
                    while compressionFactor >= 0.3 && imageData == nil {
                        imageData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
                        compressionFactor -= 0.1
                    }
                    
                    guard let finalImageData = imageData else {
                        DispatchQueue.main.async {
                            captureCompletionHandler(.failure(.screenshotError))
                        }
                        return
                    }
                    
                    // Convert to base64
                    let base64String = finalImageData.base64EncodedString()
                    
                    DispatchQueue.main.async {
                        captureCompletionHandler(.success(base64String))
                    }
                } catch {
                    DispatchQueue.main.async {
                        captureCompletionHandler(.failure(.screenshotError))
                    }
                }
            }
        }
    }
    
    // Helper method to save screenshot to disk
    private func saveScreenshotToDisk(_ image: NSImage) {
        let fileManager = FileManager.default
        
        // Get the Documents directory
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access Documents directory")
            return
        }
        
        // Create a GuideMe debug folder if it doesn't exist
        let debugDirectory = documentsDirectory.appendingPathComponent("GuideMe_Debug")
        
        do {
            if !fileManager.fileExists(atPath: debugDirectory.path) {
                try fileManager.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
            }
            
            // Create a filename with timestamp
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            let filename = "screenshot_\(timestamp).jpg"
            
            let fileURL = debugDirectory.appendingPathComponent(filename)
            
            // Convert NSImage to JPEG data
            guard let tiffData = image.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                print("❌ Could not convert image to JPEG")
                return
            }
            
            // Write to file
            try jpegData.write(to: fileURL)
            print("✅ Screenshot saved to: \(fileURL.path)")
        } catch {
            print("❌ Error saving screenshot: \(error.localizedDescription)")
        }
    }
} 
