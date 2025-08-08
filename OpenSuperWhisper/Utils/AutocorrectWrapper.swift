import Foundation

/// Swift wrapper for the autocorrect C library
class AutocorrectWrapper {
    
    /// Format text using autocorrect
    /// - Parameter text: The text to format
    /// - Returns: The formatted text, or original text if autocorrect fails
    static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        
        guard let cText = text.cString(using: .utf8) else {
            print("Failed to convert text to C string")
            return text
        }
        
        guard let formattedCString = autocorrect_format(cText) else {
            print("Autocorrect format returned null")
            return text
        }
        
        defer {
            autocorrect_free_string(formattedCString)
        }
        
        guard let formattedText = String(cString: formattedCString, encoding: .utf8) else {
            print("Failed to convert formatted C string back to Swift string")
            return text
        }
        
        return formattedText
    }
    
    /// Format text for a specific file type
    /// - Parameters:
    ///   - text: The text to format
    ///   - filename: The filename to determine formatting rules
    /// - Returns: The formatted text, or original text if autocorrect fails
    static func format(_ text: String, for filename: String) -> String {
        guard !text.isEmpty else { return text }
        
        guard let cText = text.cString(using: .utf8),
              let cFilename = filename.cString(using: .utf8) else {
            print("Failed to convert text or filename to C string")
            return text
        }
        
        guard let formattedCString = autocorrect_format_for(cText, cFilename) else {
            print("Autocorrect format_for returned null")
            return text
        }
        
        defer {
            autocorrect_free_string(formattedCString)
        }
        
        guard let formattedText = String(cString: formattedCString, encoding: .utf8) else {
            print("Failed to convert formatted C string back to Swift string")
            return text
        }
        
        return formattedText
    }
    
    /// Check if autocorrect library is available
    /// - Returns: true if the library can be used, false otherwise
    static func isAvailable() -> Bool {
        // Test by trying to format an empty string
        let testResult = autocorrect_format("")
        if testResult != nil {
            autocorrect_free_string(testResult)
            return true
        }
        return false
    }
}