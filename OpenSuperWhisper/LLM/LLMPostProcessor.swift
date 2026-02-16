import Foundation

#if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
#endif

enum LLMError: LocalizedError {
    case unavailable
    case modelNotLoaded
    case emptyOutput
    case processingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "LLM runtime is unavailable in this build"
        case .modelNotLoaded:
            return "LLM model is not loaded"
        case .emptyOutput:
            return "LLM produced empty output"
        case .processingFailed(let error):
            return "LLM processing failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
class LLMPostProcessor: ObservableObject {
    static let shared = LLMPostProcessor()

    @Published var isModelLoaded = false
    @Published var isLoadingModel = false
    @Published var isProcessing = false
    @Published var loadingProgress: Double = 0.0
    @Published var lastError: String?
    @Published private(set) var installedModelIds: Set<String> = []

    var isBusy: Bool {
        isLoadingModel || isProcessing
    }

    var isAvailable: Bool {
        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        true
        #else
        false
        #endif
    }

    #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
    private var modelContainer: ModelContainer?
    private var currentModelId: String?
    private var activeLoadTask: Task<ModelContainer, Error>?
    private var activeLoadModelId: String?
    private var activeLoadGeneration: UInt64 = 0
    #endif

    private init() {
        installedModelIds = Set(AppPreferences.shared.installedLLMModelIds)
        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        #endif
    }

    func isModelInstalled(_ modelId: String) -> Bool {
        installedModelIds.contains(modelId)
    }

    func loadModel(modelId: String) async throws {
        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        if currentModelId == modelId && isModelLoaded {
            if !installedModelIds.contains(modelId) {
                installedModelIds.insert(modelId)
                AppPreferences.shared.installedLLMModelIds = Array(installedModelIds).sorted()
            }
            return
        }

        if activeLoadModelId == modelId, let activeLoadTask {
            _ = try await activeLoadTask.value
            return
        }

        if let activeLoadTask {
            activeLoadTask.cancel()
        }

        modelContainer = nil
        currentModelId = nil
        isModelLoaded = false
        isLoadingModel = true
        isProcessing = false
        loadingProgress = 0.0
        lastError = nil
        let configuration = ModelConfiguration(id: modelId)
        activeLoadGeneration += 1
        let generation = activeLoadGeneration

        let task = Task.detached {
            try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.activeLoadGeneration == generation else { return }
                    self.loadingProgress = progress.fractionCompleted
                }
            }
        }

        activeLoadTask = task
        activeLoadModelId = modelId

        defer {
            if activeLoadGeneration == generation {
                isLoadingModel = false
                activeLoadTask = nil
                activeLoadModelId = nil
            }
        }

        do {
            let container = try await task.value
            guard activeLoadGeneration == generation else { return }

            modelContainer = container
            currentModelId = modelId
            isModelLoaded = true
            loadingProgress = 1.0
            installedModelIds.insert(modelId)
            AppPreferences.shared.installedLLMModelIds = Array(installedModelIds).sorted()
        } catch {
            guard activeLoadGeneration == generation else { return }

            modelContainer = nil
            currentModelId = nil
            isModelLoaded = false
            loadingProgress = 0.0
            lastError = error.localizedDescription
            throw error
        }
        #else
        lastError = LLMError.unavailable.localizedDescription
        throw LLMError.unavailable
        #endif
    }

    func installModel(modelId: String) async throws {
        try await loadModel(modelId: modelId)
    }

    func processText(_ text: String, mode: LLMProcessingMode) async throws -> String {
        guard mode != .raw else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        let modelId = AppPreferences.shared.llmModelId

        if !isModelLoaded || currentModelId != modelId {
            try await loadModel(modelId: modelId)
        }

        guard let container = modelContainer else {
            throw LLMError.modelNotLoaded
        }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        let systemPrompt = mode.buildSystemPrompt(for: trimmed)
        let temperature = AppPreferences.shared.llmTemperature

        let result: String = try await container.perform { context in
            let messages: [[String: String]] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": trimmed],
            ]

            let input = try await context.processor.prepare(
                input: .init(messages: messages)
            )

            let maxTokens = 1024

            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: Float(temperature)),
                context: context
            )

            var output = ""
            var tokenCount = 0
            for await generation in stream {
                if case .chunk(let text) = generation {
                    output += text
                    tokenCount += 1
                    if tokenCount >= maxTokens { break }
                }
            }

            return output
        }

        let output = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? text : output
        #else
        lastError = LLMError.unavailable.localizedDescription
        return text
        #endif
    }

    func unloadModel() {
        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        activeLoadGeneration += 1
        activeLoadTask?.cancel()
        activeLoadTask = nil
        activeLoadModelId = nil
        modelContainer = nil
        currentModelId = nil
        #endif

        isModelLoaded = false
        isLoadingModel = false
        isProcessing = false
        loadingProgress = 0.0
    }
}
