import Foundation

class TextUtil {

    /// Counts words in a string, handling leading/trailing whitespace,
    /// multiple consecutive spaces, and newlines.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Formats a TimeInterval as a human-readable duration string.
    /// e.g. 65 → "1m 5s", 30 → "30s", 3661 → "1h 1m 1s"
    static func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}
