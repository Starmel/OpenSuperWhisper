import Foundation

// MARK: - Text Improvement Configuration

struct TextImprovementConfiguration: Codable {
    var isEnabled: Bool = false
    var baseURL: String = "https://openrouter.ai/api/v1/chat/completions"
    var model: String = "openai/gpt-4o-mini"
    var apiKey: String? = nil
    var customPrompt: String = "Improve the following transcribed text for clarity and coherence without changing its meaning:"
    
    // Advanced settings (optional)
    var useAdvancedSettings: Bool = false
    var temperature: Double? = nil
    var maxTokens: Int? = nil
    
    var isValid: Bool {
        // API key must be present and non-empty
        guard let apiKey = apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        
        // Base URL must be valid
        guard !baseURL.isEmpty, URL(string: baseURL) != nil else {
            return false
        }
        
        // Model must be non-empty
        guard !model.isEmpty else {
            return false
        }
        
        // Temperature must be between 0.0 and 1.0 if provided
        if let temperature = temperature {
            guard temperature >= 0.0 && temperature <= 1.0 else {
                return false
            }
        }
        
        // Max tokens must be positive if provided
        if let maxTokens = maxTokens {
            guard maxTokens > 0 else {
                return false
            }
        }
        
        return true
    }
}

// MARK: - OpenRouter API Models

struct OpenRouterRequest: Codable {
    let model: String
    let messages: [OpenRouterMessage]
    let temperature: Double?
    let maxTokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        
        // Only encode temperature if it's provided
        if let temperature = temperature {
            try container.encode(temperature, forKey: .temperature)
        }
        
        // Only encode maxTokens if it's provided
        if let maxTokens = maxTokens {
            try container.encode(maxTokens, forKey: .maxTokens)
        }
    }
}

struct OpenRouterMessage: Codable {
    let role: String
    let content: String
}

struct OpenRouterResponse: Codable {
    let choices: [OpenRouterChoice]
    let error: OpenRouterError?
}

struct OpenRouterChoice: Codable {
    let message: OpenRouterMessage
}

struct OpenRouterError: Codable {
    let message: String
    let code: String?
}

// MARK: - Text Improvement Errors

enum TextImprovementError: Error, Equatable {
    case configurationInvalid
    case serviceDisabled
    case networkError(Error)
    case apiError(statusCode: Int, message: String)
    case rateLimitExceeded(retryAfter: Int?)
    case responseParsingError
    case textTooLong
    case cancelled
    
    static func == (lhs: TextImprovementError, rhs: TextImprovementError) -> Bool {
        switch (lhs, rhs) {
        case (.configurationInvalid, .configurationInvalid),
             (.serviceDisabled, .serviceDisabled),
             (.responseParsingError, .responseParsingError),
             (.textTooLong, .textTooLong),
             (.cancelled, .cancelled):
            return true
        case (.networkError(let lhsError), .networkError(let rhsError)):
            return (lhsError as NSError) == (rhsError as NSError)
        case (.apiError(let lhsCode, let lhsMessage), .apiError(let rhsCode, let rhsMessage)):
            return lhsCode == rhsCode && lhsMessage == rhsMessage
        case (.rateLimitExceeded(let lhsRetry), .rateLimitExceeded(let rhsRetry)):
            return lhsRetry == rhsRetry
        default:
            return false
        }
    }
    
    var localizedDescription: String {
        switch self {
        case .configurationInvalid:
            return "Text improvement configuration is invalid. Please check your API key and settings."
        case .serviceDisabled:
            return "Text improvement service is disabled."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .rateLimitExceeded(let retryAfter):
            if let retryAfter = retryAfter {
                return "Rate limit exceeded. Please retry after \(retryAfter) seconds."
            } else {
                return "Rate limit exceeded. Please try again later."
            }
        case .responseParsingError:
            return "Failed to parse API response."
        case .textTooLong:
            return "Text is too long for improvement processing."
        case .cancelled:
            return "Text improvement was cancelled."
        }
    }
}