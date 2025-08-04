import SwiftUI

/// SwiftUI view for requesting keychain permissions during onboarding
struct KeychainPermissionView: View {
    @Binding var keychainAccessState: KeychainAccessState
    @State private var isChecking = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    let onPermissionGranted: () -> Void
    let onSkip: () -> Void
    
    private let cloudProviders = KeychainPermissionManager.shared.getCloudProviders()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Secure API Key Storage")
                    .font(.title2)
                    .fontWeight(.medium)
                
                Text("OpenSuperWhisper can use cloud transcription services for improved accuracy and speed.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // Benefits section
            VStack(alignment: .leading, spacing: 16) {
                Text("Cloud Provider Benefits")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                VStack(alignment: .leading, spacing: 12) {
                    FeatureRow(
                        icon: "cloud.fill",
                        iconColor: .blue,
                        title: "Enhanced Accuracy",
                        description: "Latest AI models with improved transcription quality"
                    )
                    
                    FeatureRow(
                        icon: "bolt.fill",
                        iconColor: .orange,
                        title: "Faster Processing",
                        description: "Cloud-based processing for quicker results"
                    )
                    
                    FeatureRow(
                        icon: "globe",
                        iconColor: .green,
                        title: "Multiple Languages",
                        description: "Better support for international languages"
                    )
                }
            }
            .padding()
            .background(Color(.controlBackgroundColor).opacity(0.3))
            .cornerRadius(12)
            
            // Available providers
            if !cloudProviders.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Available Cloud Providers")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(cloudProviders, id: \.self) { provider in
                            HStack(spacing: 12) {
                                Image(systemName: "cloud")
                                    .foregroundColor(.blue)
                                    .frame(width: 20)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.displayName)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    
                                    Text("Requires API key for authentication")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            
            // Security explanation
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.checkerboard")
                        .foregroundColor(.green)
                        .font(.title3)
                    
                    Text("Secure Storage")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("• API keys are encrypted and stored in macOS Keychain")
                    Text("• Only this app can access your stored keys")
                    Text("• Keys are protected by your system password or Touch ID")
                    Text("• You can revoke access at any time in System Preferences")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.controlBackgroundColor).opacity(0.3))
            .cornerRadius(12)
            
            // Status message
            if keychainAccessState != .unknown {
                HStack(spacing: 8) {
                    switch keychainAccessState {
                    case .available:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .denied, .restricted, .unavailable:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    case .unknown:
                        EmptyView()
                    }
                    
                    Text(keychainAccessState.userMessage)
                        .font(.subheadline)
                        .foregroundColor(keychainAccessState.isAccessible ? .green : .orange)
                }
                .padding()
                .background(keychainAccessState.isAccessible ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 12) {
                Button("Skip for Now") {
                    onSkip()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button(action: {
                    checkKeychainAccess()
                }) {
                    HStack(spacing: 8) {
                        if isChecking {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "key.fill")
                        }
                        
                        Text(keychainAccessState.isAccessible ? "Continue" : "Check Access")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isChecking)
            }
        }
        .padding()
        .frame(width: 450, height: 650)
        .alert("Permission Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            // Initial check when view appears
            if keychainAccessState == .unknown {
                checkKeychainAccess()
            }
        }
    }
    
    private func checkKeychainAccess() {
        isChecking = true
        
        // Perform keychain check on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            let accessState = KeychainPermissionManager.shared.checkKeychainAccess()
            
            DispatchQueue.main.async {
                self.keychainAccessState = accessState
                self.isChecking = false
                
                if accessState.isAccessible {
                    // Auto-continue if access is available
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        onPermissionGranted()
                    }
                }
            }
        }
    }
}

/// Reusable component for feature rows
private struct FeatureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 20)
                .font(.system(size: 16, weight: .medium))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
    }
}

/// ViewModel for managing keychain permission state
class KeychainPermissionViewModel: ObservableObject {
    @Published var keychainAccessState: KeychainAccessState = .unknown
    @Published var shouldShowPermissionView: Bool = false
    
    init() {
        checkIfShouldRequestPermission()
    }
    
    private func checkIfShouldRequestPermission() {
        shouldShowPermissionView = KeychainPermissionManager.shared.shouldRequestKeychainPermission()
    }
    
    func skipPermissionRequest() {
        // User chose to skip - they can configure API keys later in settings
        keychainAccessState = .denied
        shouldShowPermissionView = false
    }
    
    func permissionGranted() {
        shouldShowPermissionView = false
    }
}

#Preview {
    KeychainPermissionView(
        keychainAccessState: .constant(.unknown),
        onPermissionGranted: {},
        onSkip: {}
    )
}