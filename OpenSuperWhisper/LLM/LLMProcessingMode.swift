import Foundation

enum LLMProcessingMode: String, CaseIterable, Identifiable, Codable {
    case raw, clean, dev, markdown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw: return "Raw"
        case .clean: return "Clean"
        case .dev: return "Dev"
        case .markdown: return "Markdown"
        }
    }

    var description: String {
        switch self {
        case .raw: return "No processing (original transcription)"
        case .clean: return "Remove filler words, fix grammar and punctuation"
        case .dev: return "Restructure into a structured coding prompt"
        case .markdown: return "Organize with headers, bullets, logical structure"
        }
    }

    func buildSystemPrompt(for text: String) -> String {
        switch self {
        case .raw:
            return ""
        case .clean:
            return Self.cleanPrompt
        case .dev:
            return DevModePrompts.buildPrompt()
        case .markdown:
            return Self.markdownPrompt
        }
    }

    private static let cleanPrompt = """
        You are a text editor. You receive raw speech transcription and output clean text.

        Rules:
        - Remove filler words: um, uh, like, basically, you know, I mean, so yeah, right
        - Fix grammar and punctuation
        - Merge broken sentences
        - Do NOT add information. Do NOT summarize. Do NOT change meaning.
        - Output ONLY the cleaned text, nothing else.

        Example input: "so um basically I want to uh fix the bug where the login um form doesn't like validate the email"
        Example output: "I want to fix the bug where the login form doesn't validate the email."
        """

    private static let markdownPrompt = """
        You are a document formatter. You receive raw speech transcription and organize it into clean markdown.

        Rules:
        - Remove filler words (um, uh, like, basically, you know)
        - Add markdown headers (##) for distinct topics
        - Use bullet points for lists or multiple items
        - Use bold for emphasis on key terms
        - Keep all original meaning and detail
        - Do NOT add information or commentary
        - Output ONLY the formatted markdown

        Example input: "so first we need to set up the database then we need to create the API endpoints and finally we need to build the frontend with React"
        Example output:
        ## Database Setup
        - Set up the database

        ## API Layer
        - Create the API endpoints

        ## Frontend
        - Build the frontend with React
        """
}
