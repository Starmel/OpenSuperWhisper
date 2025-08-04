//
//  SettingsComponents.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import SwiftUI

// MARK: - Settings Section Component

struct SettingsSection<Content: View>: View {
    let title: String
    let description: String?
    let iconName: String?
    let content: Content
    
    init(
        title: String,
        description: String? = nil,
        iconName: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.iconName = iconName
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            HStack(spacing: 12) {
                if let iconName = iconName {
                    Image(systemName: iconName)
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 24, height: 24)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    
                    if let description = description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            
            // Section Content
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        )
    }
}

// MARK: - Expandable Section Component

struct ExpandableSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let isAdvanced: Bool
    let iconName: String
    @State private var isExpanded: Bool
    let content: Content
    
    init(
        title: String,
        subtitle: String? = nil,
        isAdvanced: Bool = false,
        iconName: String = "chevron.right",
        defaultExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isAdvanced = isAdvanced
        self.iconName = iconName
        self.content = content()
        self._isExpanded = State(initialValue: defaultExpanded)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: iconName)
                        .font(.body)
                        .foregroundStyle(.blue)
                        .frame(width: 20, height: 20)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(title)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            
                            if isAdvanced {
                                Text("Advanced")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(.orange)
                                    )
                            }
                        }
                        
                        if let subtitle = subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
            )
            
            // Expandable Content
            if isExpanded {
                content
                    .padding(.top, 16)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
            }
        }
    }
}

// MARK: - Settings Row Component

struct SettingsRow<Content: View>: View {
    let title: String
    let subtitle: String?
    let iconName: String?
    let content: Content
    
    init(
        title: String,
        subtitle: String? = nil,
        iconName: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.content = content()
    }
    
    var body: some View {
        HStack(spacing: 12) {
            if let iconName = iconName {
                Image(systemName: iconName)
                    .font(.body)
                    .foregroundStyle(.blue)
                    .frame(width: 20, height: 20)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            content
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Custom Toggle Style

struct ModernToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            
            Spacer()
            
            RoundedRectangle(cornerRadius: 16)
                .fill(configuration.isOn ? .blue : .gray.opacity(0.3))
                .frame(width: 44, height: 26)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .offset(x: configuration.isOn ? 9 : -9)
                        .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                        .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        configuration.isOn.toggle()
                    }
                }
        }
    }
}

// MARK: - Validation State Indicator

struct ValidationStateIndicator: View {
    let state: SettingsViewModel.APIKeyValidationState
    
    var body: some View {
        Group {
            switch state {
            case .unknown:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.gray)
            case .validating:
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 16, height: 16)
            case .valid:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .invalid:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.body)
        .frame(width: 20, height: 20)
    }
}

// MARK: - API Key Field Component

struct APIKeyField: View {
    let title: String
    let placeholder: String
    let helpText: String
    @Binding var apiKey: String
    @Binding var validationState: SettingsViewModel.APIKeyValidationState
    let onValidate: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            
            HStack(spacing: 8) {
                SecureField(placeholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !apiKey.isEmpty {
                            onValidate()
                        }
                    }
                
                Button(action: onValidate) {
                    ValidationStateIndicator(state: validationState)
                }
                .buttonStyle(.borderless)
                .disabled(apiKey.isEmpty || validationState == .validating)
                .help("Validate API Key")
            }
            
            if case .invalid(let error) = validationState {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 4)
            }
            
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }
}

// MARK: - Slider Row Component

struct SliderRow: View {
    let title: String
    let subtitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatter: NumberFormatter
    
    init(
        title: String,
        subtitle: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 0.1,
        formatter: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = 1
            f.maximumFractionDigits = 1
            return f
        }()
    ) {
        self.title = title
        self.subtitle = subtitle
        self._value = value
        self.range = range
        self.step = step
        self.formatter = formatter
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                Text(formatter.string(from: NSNumber(value: value)) ?? "\(value)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            Slider(value: $value, in: range, step: step)
                .tint(.blue)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Info Card Component

struct InfoCard: View {
    let title: String
    let message: String
    let iconName: String
    let color: Color
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.1))
        )
    }
}

// MARK: - Directory Path Component

struct DirectoryPathRow: View {
    let title: String
    let path: String
    let onOpenFolder: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Button(action: onOpenFolder) {
                    Label("Open Folder", systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)
                .help("Open folder in Finder")
            }
            
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(0.5))
                )
        }
    }
}

// MARK: - Custom Picker Style

struct ModernPickerStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
            )
    }
}

extension View {
    func modernPickerStyle() -> some View {
        modifier(ModernPickerStyle())
    }
}