import Foundation

/// Protocol for post-processing transcribed text.
/// Replaces the hard dependency on AutocorrectWrapper in WhisperEngine.
/// macOS: Implemented with AutocorrectWrapper (Rust CJK autocorrect)
/// iOS: No-op implementation initially (autocorrect deferred)
public protocol TextPostProcessor {
    func process(_ text: String, language: String) -> String
}

/// Default no-op implementation
public struct NoOpTextPostProcessor: TextPostProcessor {
    public init() {}
    public func process(_ text: String, language: String) -> String { text }
}
