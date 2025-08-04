import Foundation
import Security

/// Manager for handling keychain access permissions and validation
class KeychainPermissionManager {
    static let shared = KeychainPermissionManager()
    
    private init() {}
    
    /// Check if keychain access is available by attempting a test operation
    func checkKeychainAccess() -> KeychainAccessState {
        let testKey = "com.opensuperwhisper.permission.test"
        let testValue = "test_value"
        let testData = testValue.data(using: .utf8)!
        
        // Attempt to add a test item to keychain
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.opensuperwhisper.apikeys",
            kSecAttrAccount as String: testKey,
            kSecValueData as String: testData
        ]
        
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        
        switch addStatus {
        case errSecSuccess:
            // Successfully added, now try to read it back
            let readQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.opensuperwhisper.apikeys",
                kSecAttrAccount as String: testKey,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            
            var result: AnyObject?
            let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
            
            // Clean up test item
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.opensuperwhisper.apikeys",
                kSecAttrAccount as String: testKey
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            
            if readStatus == errSecSuccess {
                return .available
            } else {
                return .restricted
            }
            
        case errSecItemNotFound:
            // This shouldn't happen for a new item, but treat as available
            return .available
            
        case errSecAuthFailed, errSecUserCanceled:
            return .denied
            
        case errSecNotAvailable:
            return .unavailable
            
        default:
            // Other errors - treat as restricted
            return .restricted
        }
    }
    
    /// Check if any cloud STT providers are available or configured
    func hasCloudSTTProviders() -> Bool {
        let cloudProviders = STTProviderType.allCases.filter { $0.requiresInternetConnection }
        return !cloudProviders.isEmpty
    }
    
    /// Check if user has any existing API keys stored (indicates they previously granted access)
    func hasExistingAPIKeys() -> Bool {
        let cloudProviders = STTProviderType.allCases.filter { $0.requiresInternetConnection }
        
        for provider in cloudProviders {
            if SecureStorageManager.shared.hasValidAPIKey(for: provider) {
                return true
            }
        }
        
        return false
    }
    
    /// Determine if we should request keychain permission during onboarding
    func shouldRequestKeychainPermission() -> Bool {
        // Request permission if:
        // 1. Cloud providers are available AND
        // 2. Keychain access is not currently available
        let hasCloudProviders = hasCloudSTTProviders()
        print("DEBUG: Has cloud providers: \(hasCloudProviders)")
        
        guard hasCloudProviders else { return false }
        
        let keychainState = checkKeychainAccess()
        let shouldRequest = !keychainState.isAccessible
        print("DEBUG: Keychain state: \(keychainState), should request: \(shouldRequest)")
        
        return shouldRequest
    }
    
    /// Get the list of cloud providers that would benefit from keychain access
    func getCloudProviders() -> [STTProviderType] {
        return STTProviderType.allCases.filter { $0.requiresInternetConnection }
    }
}

/// Represents the state of keychain access
enum KeychainAccessState {
    case available      // Keychain access is working normally
    case denied         // User explicitly denied access
    case restricted     // Access is restricted (possibly by enterprise policies)
    case unavailable    // Keychain service is not available
    case unknown        // Haven't checked yet
    
    var isAccessible: Bool {
        return self == .available
    }
    
    var userMessage: String {
        switch self {
        case .available:
            return "Keychain access is available"
        case .denied:
            return "Keychain access was denied. API keys cannot be stored securely."
        case .restricted:
            return "Keychain access is restricted. Please check your system settings."
        case .unavailable:
            return "Keychain service is not available on this system."
        case .unknown:
            return "Keychain access status is unknown"
        }
    }
    
    var canStoreAPIKeys: Bool {
        return self == .available
    }
}