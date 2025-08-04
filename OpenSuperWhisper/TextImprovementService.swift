import Foundation

@MainActor
class TextImprovementService: ObservableObject {
    static let shared = TextImprovementService()
    
    @Published private(set) var isImprovingText = false
    @Published private(set) var improvedText = ""
    @Published private(set) var improvementProgress: Float = 0.0
    @Published private(set) var lastError: TextImprovementError?
    
    private var improvementTask: Task<String, Error>?
    var urlSession: URLSession = URLSession.shared
    
    private init() {}
    
    // MARK: - Public Interface
    
    var isEnabled: Bool {
        let config = AppPreferences.shared.textImprovementConfig
        return config.isEnabled && config.isValid
    }
    
    func improveText(_ text: String) async throws -> String {
        guard isEnabled else {
            throw TextImprovementError.serviceDisabled
        }
        
        // Handle empty or whitespace-only text
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return text
        }
        
        // Update state
        isImprovingText = true
        improvementProgress = 0.0
        lastError = nil
        improvedText = ""
        
        defer {
            Task { @MainActor in
                self.isImprovingText = false
                self.improvementProgress = 1.0
            }
        }
        
        do {
            // Create and store the improvement task
            let task = Task {
                try await performTextImprovement(trimmedText)
            }
            improvementTask = task
            
            let result = try await task.value
            
            await MainActor.run {
                self.improvedText = result
                self.improvementProgress = 1.0
            }
            
            return result
            
        } catch is CancellationError {
            await MainActor.run {
                self.lastError = .cancelled
            }
            throw TextImprovementError.cancelled
        } catch let error as TextImprovementError {
            await MainActor.run {
                self.lastError = error
            }
            throw error
        } catch {
            let improvementError = TextImprovementError.networkError(error)
            await MainActor.run {
                self.lastError = improvementError
            }
            throw improvementError
        }
    }
    
    func cancelImprovement() {
        improvementTask?.cancel()
        improvementTask = nil
        
        Task { @MainActor in
            self.isImprovingText = false
            self.improvementProgress = 0.0
        }
    }
    
    func validateAPIKey() async -> Bool {
        let config = AppPreferences.shared.textImprovementConfig
        
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            return false
        }
        
        do {
            // Make a simple validation request
            let request = createValidationRequest(config: config)
            let (_, response) = try await urlSession.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
    
    // MARK: - Private Implementation
    
    private func performTextImprovement(_ text: String) async throws -> String {
        let config = AppPreferences.shared.textImprovementConfig
        
        guard config.isValid else {
            throw TextImprovementError.configurationInvalid
        }
        
        // Check if text is too long (rough token estimation: ~4 chars per token)
        // Only truncate if maxTokens is specified
        let processedText: String
        if let maxTokens = config.maxTokens {
            let estimatedTokens = text.count / 4
            let maxInputTokens = max(maxTokens / 2, 500) // Reserve half for response
            
            if estimatedTokens > maxInputTokens {
                // Truncate text to fit within limits
                let maxChars = maxInputTokens * 4
                processedText = String(text.prefix(maxChars))
            } else {
                processedText = text
            }
        } else {
            processedText = text
        }
        
        await MainActor.run {
            self.improvementProgress = 0.2
        }
        
        let request = try createImprovementRequest(text: processedText, config: config)
        
        await MainActor.run {
            self.improvementProgress = 0.4
        }
        
        let (data, response) = try await urlSession.data(for: request)
        
        await MainActor.run {
            self.improvementProgress = 0.8
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TextImprovementError.responseParsingError
        }
        
        // Handle different HTTP status codes
        switch httpResponse.statusCode {
        case 200:
            // Success - continue processing
            break
        case 401:
            throw TextImprovementError.apiError(statusCode: 401, message: "Invalid API key")
        case 429:
            let retryAfter = extractRetryAfter(from: httpResponse)
            throw TextImprovementError.rateLimitExceeded(retryAfter: retryAfter)
        case 400...499:
            let errorMessage = try? parseErrorMessage(from: data)
            throw TextImprovementError.apiError(statusCode: httpResponse.statusCode, message: errorMessage ?? "Client error")
        case 500...599:
            throw TextImprovementError.apiError(statusCode: httpResponse.statusCode, message: "Server error")
        default:
            throw TextImprovementError.apiError(statusCode: httpResponse.statusCode, message: "Unexpected response")
        }
        
        let improvedText = try parseImprovedText(from: data)
        
        await MainActor.run {
            self.improvementProgress = 1.0
        }
        
        return improvedText
    }
    
    private func createImprovementRequest(text: String, config: TextImprovementConfiguration) throws -> URLRequest {
        guard let url = URL(string: config.baseURL) else {
            throw TextImprovementError.configurationInvalid
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey!)", forHTTPHeaderField: "Authorization")
        
        let prompt = config.customPrompt.isEmpty ? 
            "Improve the following transcribed text for clarity and coherence without changing its meaning:" : 
            config.customPrompt
        
        let fullPrompt = "\(prompt)\n\n\(text)"
        
        let openRouterRequest = OpenRouterRequest(
            model: config.model,
            messages: [
                OpenRouterMessage(role: "user", content: fullPrompt)
            ],
            temperature: config.temperature,
            maxTokens: config.maxTokens
        )
        
        let jsonData = try JSONEncoder().encode(openRouterRequest)
        request.httpBody = jsonData
        
        return request
    }
    
    private func createValidationRequest(config: TextImprovementConfiguration) -> URLRequest {
        let url = URL(string: config.baseURL)!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey!)", forHTTPHeaderField: "Authorization")
        
        // Simple validation request
        let validationRequest = OpenRouterRequest(
            model: config.model,
            messages: [
                OpenRouterMessage(role: "user", content: "Hello")
            ],
            temperature: nil,
            maxTokens: nil
        )
        
        do {
            let jsonData = try JSONEncoder().encode(validationRequest)
            request.httpBody = jsonData
        } catch {
            // Fallback to minimal request
            request.httpBody = Data("{}".utf8)
        }
        
        return request
    }
    
    private func parseImprovedText(from data: Data) throws -> String {
        do {
            let response = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
            
            if let error = response.error {
                throw TextImprovementError.apiError(statusCode: 400, message: error.message)
            }
            
            guard let firstChoice = response.choices.first else {
                throw TextImprovementError.responseParsingError
            }
            
            let improvedText = firstChoice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Return original if response is empty
            return improvedText.isEmpty ? "" : improvedText
            
        } catch is DecodingError {
            throw TextImprovementError.responseParsingError
        }
    }
    
    private func parseErrorMessage(from data: Data) throws -> String? {
        do {
            let response = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
            return response.error?.message
        } catch {
            // Try to extract error message from raw JSON
            if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = jsonObject["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return nil
        }
    }
    
    private func extractRetryAfter(from response: HTTPURLResponse) -> Int? {
        guard let retryAfterString = response.value(forHTTPHeaderField: "Retry-After"),
              let retryAfter = Int(retryAfterString) else {
            return nil
        }
        return retryAfter
    }
}