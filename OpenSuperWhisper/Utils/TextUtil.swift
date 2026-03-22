import Foundation

enum TextUtil {

    /// Counts words in a string, handling leading/trailing whitespace,
    /// multiple consecutive spaces, and newlines.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Formats a TimeInterval as a localized, human-readable duration string.
    /// Sub-second precision is truncated. Leading zero units are dropped.
    /// e.g. 65 → "1m 5s", 30 → "30s", 3661 → "1h 1m 1s"
    static func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: duration) ?? "\(Int(duration))s"
    }
}
