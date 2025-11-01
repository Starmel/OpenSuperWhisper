import Foundation
import AVFoundation
import FluidAudio

class FluidAudioEngine: TranscriptionEngine {
    var engineName: String { "FluidAudio" }
    
    private var asrManager: AsrManager?
    private var isCancelled = false
    private var transcriptionTask: Task<String, Error>?
    
    var isModelLoaded: Bool {
        asrManager != nil
    }
    
    func initialize() async throws {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        let version: AsrModelVersion = versionString == "v2" ? .v2 : .v3
        
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        
        asrManager = manager
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let asrManager = asrManager else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        isCancelled = false
        
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()
            
            guard let self = self, !self.isCancelled else {
                throw CancellationError()
            }
            
            let result = try await asrManager.transcribe(url)
            
            try Task.checkCancellation()
            
            guard !self.isCancelled else {
                throw CancellationError()
            }
            
            let text = result.text
            
            var processedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if ["zh", "ja", "ko"].contains(settings.selectedLanguage) && settings.useAsianAutocorrect && !processedText.isEmpty {
                processedText = AutocorrectWrapper.format(processedText)
            }
            
            return processedText.isEmpty ? "No speech detected in the audio" : processedText
        }
        
        transcriptionTask = task
        
        do {
            return try await task.value
        } catch is CancellationError {
            isCancelled = true
            throw TranscriptionError.processingFailed
        }
    }
    
    func cancelTranscription() {
        isCancelled = true
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }
    
    func getSupportedLanguages() -> [String] {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        if versionString == "v2" {
            return ["en"]
        }
        return ["en", "de", "es", "fr", "it", "pt", "ru", "pl", "nl", "tr", "cs", "ar", "zh", "ja", "hu", "fi", "hr", "sk", "sr", "sl", "uk", "ca", "da", "el", "bg"]
    }
}

