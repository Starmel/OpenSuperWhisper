import Foundation
import Security

/// Property wrapper for secure storage of sensitive data like API keys using macOS Keychain
@propertyWrapper
struct SecureStorage {
    private let key: String
    private let service = "com.opensuperwhisper.apikeys"
    
    init(wrappedValue: String? = nil, _ key: String) {
        self.key = key
        if let value = wrappedValue {
            self.wrappedValue = value
        }
    }
    
    var wrappedValue: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            
            return string
        }
        set {
            if let value = newValue, !value.isEmpty {
                let data = value.data(using: .utf8)!
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: key,
                    kSecValueData as String: data
                ]
                
                // Try to update first
                let updateQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: key
                ]
                
                let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                
                if updateStatus == errSecItemNotFound {
                    // Item doesn't exist, add it
                    SecItemAdd(query as CFDictionary, nil)
                }
            } else {
                // Remove item if value is nil or empty
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: key
                ]
                SecItemDelete(query as CFDictionary)
            }
        }
    }
    
    /// Check if a value exists in the keychain without retrieving it
    var hasValue: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false
        ]
        
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Clear the stored value
    mutating func clear() {
        wrappedValue = nil
    }
}

/// Secure storage manager for centralized access to keychain operations
class SecureStorageManager {
    static let shared = SecureStorageManager()
    
    private init() {}
    
    /// Validate if an API key exists and is not empty
    func hasValidAPIKey(for provider: STTProviderType) -> Bool {
        switch provider {
        case .mistralVoxtral:
            @SecureStorage("mistral_api_key") var apiKey: String?
            return apiKey != nil && !apiKey!.isEmpty
        case .whisperLocal:
            return true // Local provider doesn't need API key
        }
    }
    
    /// Get API key for a specific provider
    func getAPIKey(for provider: STTProviderType) -> String? {
        switch provider {
        case .mistralVoxtral:
            @SecureStorage("mistral_api_key") var apiKey: String?
            return apiKey
        case .whisperLocal:
            return nil // Local provider doesn't need API key
        }
    }
    
    /// Set API key for a specific provider
    func setAPIKey(_ key: String?, for provider: STTProviderType) {
        switch provider {
        case .mistralVoxtral:
            @SecureStorage("mistral_api_key") var apiKey: String?
            apiKey = key
        case .whisperLocal:
            break // Local provider doesn't need API key
        }
    }
    
    /// Clear all stored API keys
    func clearAllAPIKeys() {
        for provider in STTProviderType.allCases {
            setAPIKey(nil, for: provider)
        }
    }
}