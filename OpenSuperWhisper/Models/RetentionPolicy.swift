import Foundation

/// Time unit used by the age-based retention policy.
enum RetentionUnit: String, CaseIterable, Identifiable {
    case minutes
    case hours
    case days

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minutes: return "Minutes"
        case .hours: return "Hours"
        case .days: return "Days"
        }
    }

    /// Number of seconds in a single unit.
    var seconds: TimeInterval {
        switch self {
        case .minutes: return 60
        case .hours: return 60 * 60
        case .days: return 60 * 60 * 24
        }
    }
}

/// Snapshot of the user's retention preferences.
///
/// Two independent switches can be active at the same time:
/// - a maximum number of recordings / transcriptions to keep, and
/// - a maximum age, after which recordings are deleted.
struct RetentionPolicy {
    var maxCountEnabled: Bool
    var maxCount: Int
    var maxAgeEnabled: Bool
    var maxAgeValue: Int
    var maxAgeUnit: RetentionUnit

    init(from prefs: AppPreferences = .shared) {
        self.maxCountEnabled = prefs.retentionMaxCountEnabled
        self.maxCount = prefs.retentionMaxCount
        self.maxAgeEnabled = prefs.retentionMaxAgeEnabled
        self.maxAgeValue = prefs.retentionMaxAgeValue
        self.maxAgeUnit = RetentionUnit(rawValue: prefs.retentionMaxAgeUnit) ?? .days
    }

    /// Whether at least one retention switch is active and meaningful.
    var isActive: Bool {
        (maxCountEnabled && maxCount > 0) || (maxAgeEnabled && maxAgeValue > 0)
    }

    /// Cutoff date for the age policy. Recordings with a timestamp strictly
    /// before this date are considered expired. `nil` when the age policy is off.
    func ageCutoffDate(now: Date = Date()) -> Date? {
        guard maxAgeEnabled, maxAgeValue > 0 else { return nil }
        let interval = Double(maxAgeValue) * maxAgeUnit.seconds
        return now.addingTimeInterval(-interval)
    }
}
