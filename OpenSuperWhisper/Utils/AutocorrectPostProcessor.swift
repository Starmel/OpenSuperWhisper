import Foundation
import WhisperCore

struct AutocorrectPostProcessor: TextPostProcessor {
    func process(_ text: String, language: String) -> String {
        AutocorrectWrapper.format(text)
    }
}
