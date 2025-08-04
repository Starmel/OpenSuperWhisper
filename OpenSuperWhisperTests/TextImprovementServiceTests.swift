import XCTest
@testable import OpenSuperWhisper

@MainActor
final class TextImprovementServiceTests: XCTestCase {
    
    var service: TextImprovementService!
    var mockURLSession: MockURLSession!
    
    override func setUp() {
        super.setUp()
        mockURLSession = MockURLSession()
        service = TextImprovementService()
        service.urlSession = mockURLSession
    }
    
    override func tearDown() {
        service = nil
        mockURLSession = nil
        super.tearDown()
    }
    
    // MARK: - Configuration Tests
    
    func testDefaultConfiguration() {
        let config = TextImprovementConfiguration()
        
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.baseURL, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(config.model, "openai/gpt-4o-mini")
        XCTAssertNil(config.apiKey)
        XCTAssertEqual(config.temperature, 0.3)
        XCTAssertEqual(config.maxTokens, 1000)
        XCTAssertFalse(config.customPrompt.isEmpty)
    }
    
    func testConfigurationValidation() {
        var config = TextImprovementConfiguration()
        
        // Test invalid configurations
        XCTAssertFalse(config.isValid)
        
        config.apiKey = ""
        XCTAssertFalse(config.isValid)
        
        config.apiKey = "test-key"
        XCTAssertTrue(config.isValid)
        
        config.baseURL = ""
        XCTAssertFalse(config.isValid)
        
        config.baseURL = "invalid-url"
        XCTAssertFalse(config.isValid)
        
        config.baseURL = "https://openrouter.ai/api/v1/chat/completions"
        XCTAssertTrue(config.isValid)
    }
    
    // MARK: - Service State Tests
    
    func testInitialState() {
        XCTAssertFalse(service.isImprovingText)
        XCTAssertEqual(service.improvedText, "")
        XCTAssertEqual(service.improvementProgress, 0.0)
        XCTAssertNil(service.lastError)
    }
    
    func testServiceEnabledState() {
        // Should be disabled when configuration is invalid
        XCTAssertFalse(service.isEnabled)
        
        // Enable with valid configuration
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key"
        AppPreferences.shared.textImprovementConfig = config
        
        XCTAssertTrue(service.isEnabled)
    }
    
    // MARK: - Text Improvement Tests
    
    func testSuccessfulTextImprovement() async throws {
        // Setup configuration
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key"
        AppPreferences.shared.textImprovementConfig = config
        
        // Setup mock response
        let mockResponse = OpenRouterResponse(
            choices: [
                OpenRouterChoice(
                    message: OpenRouterMessage(
                        role: "assistant",
                        content: "This is the improved text with better clarity and coherence."
                    )
                )
            ]
        )
        
        mockURLSession.mockData = try JSONEncoder().encode(mockResponse)
        mockURLSession.mockResponse = HTTPURLResponse(
            url: URL(string: config.baseURL)!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        
        let originalText = "um like this is uh you know some text that needs improvement"
        let improvedText = try await service.improveText(originalText)
        
        XCTAssertEqual(improvedText, "This is the improved text with better clarity and coherence.")
        XCTAssertFalse(service.isImprovingText)
        XCTAssertEqual(service.improvementProgress, 1.0)
        XCTAssertNil(service.lastError)
    }
    
    func testTextImprovementWithCustomPrompt() async throws {
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key"
        config.customPrompt = "Make this text more professional:"
        AppPreferences.shared.textImprovementConfig = config
        
        let mockResponse = OpenRouterResponse(
            choices: [
                OpenRouterChoice(
                    message: OpenRouterMessage(
                        role: "assistant",
                        content: "Professional improved text."
                    )
                )
            ]
        )
        
        mockURLSession.mockData = try JSONEncoder().encode(mockResponse)
        mockURLSession.mockResponse = HTTPURLResponse(
            url: URL(string: config.baseURL)!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        
        let originalText = "casual text here"
        _ = try await service.improveText(originalText)
        
        // Verify the request used custom prompt
        XCTAssertNotNil(mockURLSession.lastRequest)
        let requestData = mockURLSession.lastRequestBody!
        let request = try JSONDecoder().decode(OpenRouterRequest.self, from: requestData)
        
        XCTAssertTrue(request.messages.first?.content.contains("Make this text more professional:") ?? false)
    }
    
    func testAPIKeyValidation() async {
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key"
        AppPreferences.shared.textImprovementConfig = config
        
        // Mock successful validation response
        mockURLSession.mockData = Data("{}".utf8)
        mockURLSession.mockResponse = HTTPURLResponse(
            url: URL(string: config.baseURL)!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        
        let isValid = await service.validateAPIKey()
        XCTAssertTrue(isValid)
    }
    
    func testAPIKeyValidationFailure() async {
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "invalid-key"
        AppPreferences.shared.textImprovementConfig = config
        
        // Mock error response
        mockURLSession.mockResponse = HTTPURLResponse(
            url: URL(string: config.baseURL)!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )
        mockURLSession.mockError = URLError(.userAuthenticationRequired)
        
        let isValid = await service.validateAPIKey()
        XCTAssertFalse(isValid)
    }
    
    func testEmptyTextHandling() async throws {
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key"
        AppPreferences.shared.textImprovementConfig = config
        
        let emptyText = ""
        let result = try await service.improveText(emptyText)
        
        XCTAssertEqual(result, emptyText)
        XCTAssertEqual(mockURLSession.requestCount, 0) // No API call should be made
    }
    
    func testLongTextHandling() async throws {
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key"
        config.useAdvancedSettings = true
        config.maxTokens = 100
        AppPreferences.shared.textImprovementConfig = config
        
        // Create text that would exceed token limit
        let longText = String(repeating: "This is a very long text that should be truncated. ", count: 100)
        
        let mockResponse = OpenRouterResponse(
            choices: [
                OpenRouterChoice(
                    message: OpenRouterMessage(
                        role: "assistant",
                        content: "Improved text."
                    )
                )
            ]
        )
        
        mockURLSession.mockData = try JSONEncoder().encode(mockResponse)
        mockURLSession.mockResponse = HTTPURLResponse(
            url: URL(string: config.baseURL)!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        
        let result = try await service.improveText(longText)
        
        XCTAssertEqual(result, "Improved text.")
        
        // Verify request was made with truncated text
        let requestData = mockURLSession.lastRequestBody!
        let request = try JSONDecoder().decode(OpenRouterRequest.self, from: requestData)
        XCTAssertEqual(request.maxTokens, 100)
    }
    
    func testCancellation() async throws {
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key"
        AppPreferences.shared.textImprovementConfig = config
        
        // Setup slow mock response
        mockURLSession.mockDelay = 2.0
        mockURLSession.mockData = Data("{}".utf8)
        mockURLSession.mockResponse = HTTPURLResponse(
            url: URL(string: config.baseURL)!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
        
        let task = Task {
            try await service.improveText("test text")
        }
        
        // Cancel after small delay
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        service.cancelImprovement()
        
        do {
            _ = try await task.value
            XCTFail("Should have been cancelled")
        } catch is CancellationError {
            // Expected
            XCTAssertFalse(service.isImprovingText)
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testNetworkError() async {
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key"
        AppPreferences.shared.textImprovementConfig = config
        
        mockURLSession.mockError = URLError(.networkConnectionLost)
        
        do {
            _ = try await service.improveText("test text")
            XCTFail("Should have thrown error")
        } catch let error as TextImprovementError {
            XCTAssertEqual(error, .networkError(URLError(.networkConnectionLost)))
            XCTAssertNotNil(service.lastError)
        }
    }
    
    func testAPIError() async {
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key"
        AppPreferences.shared.textImprovementConfig = config
        
        let errorResponse = """
        {
            "error": {
                "message": "Invalid API key",
                "code": "invalid_api_key"
            }
        }
        """
        
        mockURLSession.mockData = Data(errorResponse.utf8)
        mockURLSession.mockResponse = HTTPURLResponse(
            url: URL(string: config.baseURL)!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )
        
        do {
            _ = try await service.improveText("test text")
            XCTFail("Should have thrown error")
        } catch let error as TextImprovementError {
            if case .apiError(let statusCode, let message) = error {
                XCTAssertEqual(statusCode, 401)
                XCTAssertTrue(message.contains("Invalid API key"))
            } else {
                XCTFail("Wrong error type")
            }
        }
    }
    
    func testRateLimitHandling() async {
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key"
        AppPreferences.shared.textImprovementConfig = config
        
        mockURLSession.mockResponse = HTTPURLResponse(
            url: URL(string: config.baseURL)!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "60"]
        )
        
        do {
            _ = try await service.improveText("test text")
            XCTFail("Should have thrown error")
        } catch let error as TextImprovementError {
            if case .rateLimitExceeded(let retryAfter) = error {
                XCTAssertEqual(retryAfter, 60)
            } else {
                XCTFail("Wrong error type")
            }
        }
    }
}

// MARK: - Mock Classes

class MockURLSession: URLSessionProtocol {
    var mockData: Data?
    var mockResponse: URLResponse?
    var mockError: Error?
    var mockDelay: TimeInterval = 0
    var lastRequest: URLRequest?
    var lastRequestBody: Data?
    var requestCount = 0
    
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        lastRequest = request
        lastRequestBody = request.httpBody
        
        if mockDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(mockDelay * 1_000_000_000))
        }
        
        if let error = mockError {
            throw error
        }
        
        guard let data = mockData, let response = mockResponse else {
            throw URLError(.badServerResponse)
        }
        
        return (data, response)
    }
}

protocol URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}