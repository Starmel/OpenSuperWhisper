import Foundation

struct LLMModelInfo: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let huggingFaceId: String
    let sizeLabel: String
    let description: String
    let recommended: Bool

    static func == (lhs: LLMModelInfo, rhs: LLMModelInfo) -> Bool {
        lhs.id == rhs.id
    }
}

struct LLMModelRegistry {
    // MARK: - General Purpose Models

    static let generalModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "qwen3-0.6b",
            displayName: "Qwen3 0.6B",
            huggingFaceId: "mlx-community/Qwen3-0.6B-4bit",
            sizeLabel: "~335 MB",
            description: "Fastest processing",
            recommended: false
        ),
        LLMModelInfo(
            id: "gemma3-1b",
            displayName: "Gemma 3 1B",
            huggingFaceId: "mlx-community/gemma-3-1b-it-4bit",
            sizeLabel: "~733 MB",
            description: "Fast processing, good accuracy",
            recommended: false
        ),
        LLMModelInfo(
            id: "llama3.2-3b",
            displayName: "Llama 3.2 3B Instruct",
            huggingFaceId: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            sizeLabel: "~1.8 GB",
            description: "Balanced speed and accuracy",
            recommended: true
        ),
        LLMModelInfo(
            id: "qwen3-4b",
            displayName: "Qwen3 4B Instruct",
            huggingFaceId: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            sizeLabel: "~2.3 GB",
            description: "High accuracy, multilingual",
            recommended: false
        ),
        LLMModelInfo(
            id: "phi4-mini",
            displayName: "Phi-4 Mini 3.8B",
            huggingFaceId: "mlx-community/Phi-4-mini-instruct-4bit",
            sizeLabel: "~2.2 GB",
            description: "High accuracy, best reasoning",
            recommended: false
        ),
    ]

    // MARK: - Code-Specialized Models

    static let codeModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "qwen2.5-coder-0.5b",
            displayName: "Qwen2.5 Coder 0.5B",
            huggingFaceId: "mlx-community/Qwen2.5-Coder-0.5B-Instruct-4bit",
            sizeLabel: "~278 MB",
            description: "Fastest processing, code-tuned",
            recommended: false
        ),
        LLMModelInfo(
            id: "qwen2.5-coder-1.5b",
            displayName: "Qwen2.5 Coder 1.5B",
            huggingFaceId: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            sizeLabel: "~869 MB",
            description: "Fast processing, code-tuned",
            recommended: false
        ),
        LLMModelInfo(
            id: "qwen2.5-coder-3b",
            displayName: "Qwen2.5 Coder 3B",
            huggingFaceId: "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
            sizeLabel: "~1.7 GB",
            description: "Balanced speed and accuracy, code-tuned",
            recommended: false
        ),
    ]

    static let availableModels: [LLMModelInfo] = generalModels + codeModels

    static func model(forHuggingFaceId hfId: String) -> LLMModelInfo? {
        availableModels.first { $0.huggingFaceId == hfId }
    }

    static var defaultModel: LLMModelInfo {
        availableModels.first { $0.recommended } ?? availableModels[0]
    }
}
