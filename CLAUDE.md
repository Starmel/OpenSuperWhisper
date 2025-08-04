# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

OpenSuperWhisper is a macOS application that provides real-time audio transcription using the Whisper model. Built with SwiftUI and native macOS APIs, it offers seamless audio recording and transcription with customizable settings and global keyboard shortcuts.

**Platform Requirements**: macOS 14.0+ (Sonoma), ARM64 (Apple Silicon) only

## Development Commands

### Building the Project

**Initial Setup**:
```bash
git submodule update --init --recursive
brew install cmake
gem install xcpretty  # Optional: for prettier build output
```

**Development Build**:
```bash
./run.sh build    # Build only
./run.sh          # Build and run
```

**Manual Build Process**:
```bash
# Configure libwhisper (native C++ library)
cmake -G Xcode -B libwhisper/build -S libwhisper

# Build via Xcode command line
xcodebuild -scheme OpenSuperWhisper -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build build
```

### Testing

**Run All Tests**:
```bash
xcodebuild test -scheme OpenSuperWhisper -destination 'platform=macOS,arch=arm64'
```

**Individual Test Targets**:
```bash
xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperTests
xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperUITests
```

**Run Specific Test Files**:
```bash
# STT-related tests
xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperTests/STTProviderFactoryTests
xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperTests/MistralVoxtralProviderTests
xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperTests/EnhancedTranscriptionServiceTests

# Text improvement tests
xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperTests/TextImprovementServiceTests
xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperTests/TextImprovementConfigurationTests
```

### Release Build

**Signed Release Build**:
```bash
./notarize_app.sh "Developer ID Application: Your Name (TEAM_ID)"
```

**Full Release Pipeline**:
```bash
./make_release.sh 0.0.4 "Developer ID Application: Your Name (TEAM_ID)" ghp_xxxxx
```

## Architecture Overview

### Core Components

**App Entry Point**: `OpenSuperWhisperApp.swift`
- SwiftUI app with `@main` attribute
- Singleton `AppState` for global state management
- Menu bar app with system tray integration
- Conditional onboarding flow

**Audio Pipeline**: `AudioRecorder.swift`
- Singleton pattern for thread-safe recording
- AVFoundation integration with optimized settings (16kHz, mono, 16-bit PCM)
- Dynamic audio device monitoring
- Temporary file management with automatic cleanup

**Transcription Engine**: `TranscriptionService.swift` & `EnhancedTranscriptionService.swift`
- MainActor isolation for UI updates
- Asynchronous processing with cancellation support
- Audio conversion pipeline (44.1kHz → 16kHz mono float32)
- Real-time progress tracking via segment callbacks
- Multi-provider STT support (Local Whisper, Mistral Voxtral cloud API)
- Provider factory pattern for extensible STT backends

**Model Management**: `WhisperModelManager.swift`
- Application Support directory for model storage
- Default model bundling (`ggml-tiny.en.bin`)
- Progress-tracked downloads with resume capability

**Swift Wrapper**: `Whis/Whis.swift`
- Memory-safe C interop with `OpaquePointer` management
- Context and state management for thread safety
- Real-time callback integration
- OpenVINO hardware acceleration support

**STT Provider System**: `STT/` directory
- `STTProvider.swift`: Core protocol for all STT implementations
- `MistralVoxtralProvider.swift`: Cloud-based transcription via Mistral AI API
- `STTProviderFactory.swift`: Factory pattern for provider instantiation
- `SecureStorage.swift`: Keychain management for API credentials
- `STTConfigurations.swift`: Provider-specific configuration management

**Text Improvement Service**: `TextImprovementService.swift`
- LLM-powered text enhancement via cloud APIs
- Configurable provider support (OpenAI, Anthropic, etc.)
- Real-time progress tracking and error handling
- Secure credential management via Keychain

### Key Architectural Patterns

- **MVVM**: Clear separation between view models and business logic
- **Observer Pattern**: `@Published` properties for reactive UI updates
- **Singleton Pattern**: Shared managers for core services
- **Delegation Pattern**: Audio recorder and URL session delegates
- **Async/Await**: Modern concurrency for audio processing

### Directory Structure

```
OpenSuperWhisper/
├── OpenSuperWhisperApp.swift     # Main app entry point
├── AudioRecorder.swift           # Audio recording pipeline
├── TranscriptionService.swift    # Legacy transcription service
├── EnhancedTranscriptionService.swift # New unified transcription service
├── WhisperModelManager.swift     # ML model lifecycle
├── Settings.swift                # Configuration management
├── ShortcutManager.swift         # Global keyboard shortcuts
├── TextImprovementService.swift  # LLM text enhancement
├── TextImprovementConfiguration.swift # Text improvement settings
├── Whis/                         # Swift wrapper for Whisper C library
│   ├── Whis.swift               # Main wrapper implementation
│   └── Whisper*.swift           # Supporting structures
├── STT/                          # Speech-to-Text provider system
│   ├── STTProvider.swift        # Core STT protocol
│   ├── MistralVoxtralProvider.swift # Mistral AI cloud provider
│   ├── STTProviderFactory.swift # Provider factory
│   ├── SecureStorage.swift      # Keychain credential management
│   └── STTConfigurations.swift  # Provider configurations
├── Models/                       # Data models
├── Onboarding/                   # First-run experience
├── Indicator/                    # Status indicator UI
└── Utils/                        # Shared utilities
```

## Development Notes

### Dependencies

**Swift Packages**:
- GRDB 7.5.0+ (SQLite database)
- KeyboardShortcuts 2.3.0+ (Global shortcuts)

**Native Libraries**:
- libwhisper (via CMake)
- whisper.cpp (git submodule)

**System Frameworks**:
- AVFoundation (audio recording/playback)
- SwiftUI (UI framework)
- AppKit (macOS-specific features)
- Metal/MetalKit (GPU acceleration)

### Build Configuration

- **Target Platform**: ARM64 macOS 14.0+ only (`EXCLUDED_ARCHS = x86_64`)
- **Code Signing**: Manual style for release builds
- **Hardened Runtime**: Enabled for security
- **Entitlements**: Microphone and accessibility permissions required

### Testing Structure

- **OpenSuperWhisperTests**: Basic unit tests
- **OpenSuperWhisperUITests**: UI automation with launch performance
- **WhisperCppBindingTests**: Native binding validation
- **STT-specific tests**: Provider factory, Mistral integration, enhanced transcription
- **Text improvement tests**: Configuration and service functionality

### CI/CD

GitHub Actions workflow (`.github/workflows/build.yml`):
- Runs on `macos-latest`
- Tests build via `./run.sh build`
- Ruby/xcpretty for output formatting
- CMake for native library configuration

### Release Process

1. Version update via `make_release.sh`
2. Code signing and notarization via `notarize_app.sh`
3. DMG creation with `swifty-dmg`
4. Apple notarization via `xcrun notarytool`
5. GitHub release with asset upload

### Whisper Model Management

- Default model: `ggml-tiny.en.bin` (bundled)
- Additional models: Download from [Whisper.cpp Hugging Face repository](https://huggingface.co/ggerganov/whisper.cpp/tree/main)
- Model storage: User's Application Support directory
- Formats supported: `.bin` files from whisper.cpp

### Cloud Provider Configuration

**Mistral Voxtral STT Integration**:
- Provider: Mistral AI cloud API
- Configuration: API key stored securely in Keychain
- Supported features: Real-time transcription, multiple languages
- Network-dependent service with fallback to local Whisper

**Text Improvement (LLM Enhancement)**:
- Supported providers: OpenAI, Anthropic, custom endpoints
- Configuration: API keys and endpoints in secure storage
- Features: Grammar correction, style improvement, translation
- Async processing with progress tracking and cancellation support

## Important Implementation Details

### Audio Processing
- Sample rate conversion: 44.1kHz → 16kHz mono float32
- Minimum recording duration: 1 second (auto-filtered)
- Buffer management for real-time processing
- Device switching support during recording

### Memory Management
- Careful `OpaquePointer` lifecycle for C interop
- Automatic cleanup in `deinit` methods
- Temporary file management with isolated directories
- Context separation for thread safety
- Secure credential storage via Keychain Services
- Network request cancellation and resource cleanup

### Performance Considerations
- Background processing for CPU-intensive transcription
- Real-time progress updates via MainActor
- GPU acceleration via Metal (when available) 
- Efficient audio format conversion pipeline
- Provider-based architecture for optimal STT backend selection
- Async/await patterns for network operations and UI responsiveness
- Smart fallback from cloud to local processing when network unavailable

### Global Shortcuts
- Default: `cmd + `\` for quick recording
- Configurable via Settings UI
- System-wide registration via Carbon APIs
- Long-press support for continuous recording

## Development Memories

- No need to build the app after making changes, just use Xcode to build it