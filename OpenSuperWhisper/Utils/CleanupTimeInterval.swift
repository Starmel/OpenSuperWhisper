//
//  CleanupTimeInterval.swift
//  OpenSuperWhisper
//
//  Created by user on 13.07.2025.
//

import Foundation

/// Represents different time intervals for automatic recording cleanup
enum CleanupTimeInterval: String, CaseIterable, Codable {
    case never = "never"
    case oneDay = "1day"
    case oneWeek = "1week"
    case oneMonth = "1month"
    case threeMonths = "3months"
    case sixMonths = "6months"
    
    /// Human-readable display name for the cleanup interval
    var displayName: String {
        switch self {
        case .never: return "Keep forever"
        case .oneDay: return "1 day"
        case .oneWeek: return "1 week"
        case .oneMonth: return "1 month"
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        }
    }
    
    /// Time interval in seconds, nil for never
    var timeInterval: TimeInterval? {
        switch self {
        case .never: return nil
        case .oneDay: return 24 * 60 * 60
        case .oneWeek: return 7 * 24 * 60 * 60
        case .oneMonth: return 30 * 24 * 60 * 60
        case .threeMonths: return 90 * 24 * 60 * 60
        case .sixMonths: return 180 * 24 * 60 * 60
        }
    }
    
    /// Description of what will be cleaned up
    var cleanupDescription: String {
        switch self {
        case .never: return "Recordings will be kept forever"
        case .oneDay: return "Recordings older than 1 day will be deleted"
        case .oneWeek: return "Recordings older than 1 week will be deleted"
        case .oneMonth: return "Recordings older than 1 month will be deleted"
        case .threeMonths: return "Recordings older than 3 months will be deleted"
        case .sixMonths: return "Recordings older than 6 months will be deleted"
        }
    }
    
    /// Calculate the cutoff date for cleanup based on current time
    func cutoffDate(from referenceDate: Date = Date()) -> Date? {
        guard let interval = timeInterval else { return nil }
        return referenceDate.addingTimeInterval(-interval)
    }
    
    /// Check if a recording should be cleaned up based on its timestamp
    func shouldCleanup(recordingDate: Date, referenceDate: Date = Date()) -> Bool {
        guard let cutoff = cutoffDate(from: referenceDate) else { return false }
        return recordingDate < cutoff
    }
}

/// Result of a cleanup operation
struct CleanupResult {
    let deletedCount: Int
    let deletedSize: Int64
    let errors: [CleanupError]
    let duration: TimeInterval
    
    var isSuccess: Bool {
        return errors.isEmpty
    }
    
    var hasPartialSuccess: Bool {
        return deletedCount > 0 && !errors.isEmpty
    }
}

/// Errors that can occur during cleanup operations
enum CleanupError: Error, LocalizedError {
    case fileNotFound(String)
    case permissionDenied(String)
    case databaseError(String)
    case recordingInUse(String)
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound(let file):
            return "File not found: \(file)"
        case .permissionDenied(let file):
            return "Permission denied: \(file)"
        case .databaseError(let message):
            return "Database error: \(message)"
        case .recordingInUse(let file):
            return "Recording in use: \(file)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}
