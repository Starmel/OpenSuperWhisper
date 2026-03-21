import Foundation

enum GrammarEngineError: LocalizedError {
    case modelNotDownloaded
    case modelLoadFailed
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded: return "Grammar model has not been downloaded yet."
        case .modelLoadFailed:    return "Failed to load the grammar model."
        case .inferenceFailed:    return "Grammar correction failed."
        }
    }
}

/// Wraps the llama.cpp-based grammar correction engine.
/// The model is loaded lazily on the first call to fixGrammar().
@MainActor
class GrammarEngine: ObservableObject {
    static let shared = GrammarEngine()

    @Published private(set) var isModelLoading  = false
    @Published private(set) var isFixingGrammar = false

    private var engineRef: LlamaGrammarEngineRef? = nil
    private var loadingTask: Task<Void, Never>? = nil

    private init() {}

    // MARK: - Model lifecycle

    var isModelLoaded: Bool { engineRef != nil }

    /// Start loading the model in the background. Safe to call multiple times.
    func loadModelIfNeeded() {
        guard !isModelLoaded && !isModelLoading else { return }
        guard GrammarModelManager.shared.isModelDownloaded else { return }

        isModelLoading = true
        let modelPath = GrammarModelManager.shared.modelPath.path

        loadingTask = Task.detached(priority: .userInitiated) {
            // llama context creation is blocking and CPU-intensive
            let ref = llama_grammar_engine_create(modelPath)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.engineRef    = ref
                self.isModelLoading = false
                self.loadingTask  = nil
            }
        }
    }

    func unloadModel() {
        loadingTask?.cancel()
        loadingTask = nil
        if let ref = engineRef {
            let captured = ref
            engineRef = nil
            Task.detached { llama_grammar_engine_free(captured) }
        }
        isModelLoading = false
    }

    // MARK: - Inference

    func fixGrammar(_ text: String, systemPrompt: String? = nil) async throws -> String {
        guard GrammarModelManager.shared.isModelDownloaded else {
            throw GrammarEngineError.modelNotDownloaded
        }

        // Start loading if we haven't yet
        if !isModelLoaded && !isModelLoading {
            loadModelIfNeeded()
        }

        // Wait for loading to complete
        if let task = loadingTask {
            await task.value
        }

        guard let ref = engineRef else {
            throw GrammarEngineError.modelLoadFailed
        }

        isFixingGrammar = true
        defer { isFixingGrammar = false }

        // Pass nil for system_prompt to use the built-in fallback when no custom prompt set
        let prompt = (systemPrompt?.isEmpty == false) ? systemPrompt : nil

        return try await Task.detached(priority: .userInitiated) {
            guard let ptr = llama_grammar_engine_fix(ref, text, prompt) else {
                throw GrammarEngineError.inferenceFailed
            }
            defer { free(ptr) }
            return String(cString: ptr)
        }.value
    }
}
