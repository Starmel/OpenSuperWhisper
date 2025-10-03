import Foundation

enum TranscriptionBackend: String, CaseIterable, Identifiable {
    case local
    case openAI
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .local:
            return "On-device (Whisper.cpp)"
        case .openAI:
            return "OpenAI Whisper API"
        }
    }
    
    var helpText: String {
        switch self {
        case .local:
            return "Runs entirely on your Mac using downloaded ggml models."
        case .openAI:
            return "Uploads audio to OpenAI for transcription. Requires an API key."
        }
    }
}
