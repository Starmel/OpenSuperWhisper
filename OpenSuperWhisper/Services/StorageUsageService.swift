//
//  StorageUsageService.swift
//  OpenSuperWhisper
//
//  Created by user on 13.07.2025.
//

import Foundation

@MainActor
class StorageUsageService: ObservableObject {
    static let shared = StorageUsageService()
    
    @Published var totalStorageUsed: Int64 = 0
    @Published var recordingCount: Int = 0
    @Published var estimatedCleanupSavings: Int64 = 0
    @Published var isCalculating = false
    
    private let recordingStore = RecordingStore.shared
    
    private init() {
        // Calculate initial storage usage
        Task {
            await calculateStorageUsage()
        }
        
        // Listen for recording changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingsChanged),
            name: NSNotification.Name("RecordingsChanged"),
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func recordingsChanged() {
        Task {
            await calculateStorageUsage()
        }
    }
    
    /// Calculate total storage usage and potential cleanup savings
    func calculateStorageUsage() async {
        isCalculating = true
        
        defer {
            isCalculating = false
        }
        
        let recordings = recordingStore.recordings
        recordingCount = recordings.count
        
        var totalSize: Int64 = 0
        var cleanupSize: Int64 = 0
        
        let cleanupInterval = AppPreferences.shared.cleanupInterval
        
        for recording in recordings {
            do {
                let fileSize = try getFileSize(for: recording)
                totalSize += fileSize
                
                // Check if this recording would be cleaned up
                if cleanupInterval.shouldCleanup(recordingDate: recording.timestamp) {
                    cleanupSize += fileSize
                }
            } catch {
                // File might not exist, skip it
                continue
            }
        }
        
        totalStorageUsed = totalSize
        estimatedCleanupSavings = cleanupSize
    }
    
    /// Get file size for a recording
    private func getFileSize(for recording: Recording) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: recording.url.path)
        return attributes[.size] as? Int64 ?? 0
    }
    
    /// Format bytes into human-readable string
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
    
    /// Get storage usage breakdown by time period
    func getStorageBreakdown() async -> StorageBreakdown {
        let recordings = recordingStore.recordings
        let now = Date()
        
        var breakdown = StorageBreakdown()
        
        for recording in recordings {
            do {
                let fileSize = try getFileSize(for: recording)
                let age = now.timeIntervalSince(recording.timestamp)
                
                breakdown.totalSize += fileSize
                breakdown.totalCount += 1
                
                if age <= 24 * 60 * 60 { // 1 day
                    breakdown.lastDaySize += fileSize
                    breakdown.lastDayCount += 1
                } else if age <= 7 * 24 * 60 * 60 { // 1 week
                    breakdown.lastWeekSize += fileSize
                    breakdown.lastWeekCount += 1
                } else if age <= 30 * 24 * 60 * 60 { // 1 month
                    breakdown.lastMonthSize += fileSize
                    breakdown.lastMonthCount += 1
                } else if age <= 90 * 24 * 60 * 60 { // 3 months
                    breakdown.lastThreeMonthsSize += fileSize
                    breakdown.lastThreeMonthsCount += 1
                } else if age <= 180 * 24 * 60 * 60 { // 6 months
                    breakdown.lastSixMonthsSize += fileSize
                    breakdown.lastSixMonthsCount += 1
                } else {
                    breakdown.olderSize += fileSize
                    breakdown.olderCount += 1
                }
            } catch {
                continue
            }
        }
        
        return breakdown
    }
    
    /// Calculate estimated cleanup impact for a given interval
    func calculateCleanupImpact(for interval: CleanupTimeInterval) async -> CleanupImpact {
        let recordings = recordingStore.recordings
        
        var impactSize: Int64 = 0
        var impactCount = 0
        
        for recording in recordings {
            if interval.shouldCleanup(recordingDate: recording.timestamp) {
                do {
                    let fileSize = try getFileSize(for: recording)
                    impactSize += fileSize
                    impactCount += 1
                } catch {
                    continue
                }
            }
        }
        
        return CleanupImpact(
            deletedSize: impactSize,
            deletedCount: impactCount,
            remainingSize: totalStorageUsed - impactSize,
            remainingCount: recordingCount - impactCount
        )
    }
    
    /// Get recordings directory URL
    var recordingsDirectoryURL: URL {
        return Recording.recordingsDirectory
    }
    
    /// Check if recordings directory exists and is accessible
    func checkDirectoryAccess() -> Bool {
        let url = recordingsDirectoryURL
        var isDirectory: ObjCBool = false
        
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    
    /// Get available disk space
    func getAvailableDiskSpace() -> Int64? {
        do {
            let url = recordingsDirectoryURL
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            return values.volumeAvailableCapacity as? Int64
        } catch {
            return nil
        }
    }
}

/// Storage usage breakdown by time periods
struct StorageBreakdown {
    var totalSize: Int64 = 0
    var totalCount: Int = 0
    
    var lastDaySize: Int64 = 0
    var lastDayCount: Int = 0
    
    var lastWeekSize: Int64 = 0
    var lastWeekCount: Int = 0
    
    var lastMonthSize: Int64 = 0
    var lastMonthCount: Int = 0
    
    var lastThreeMonthsSize: Int64 = 0
    var lastThreeMonthsCount: Int = 0
    
    var lastSixMonthsSize: Int64 = 0
    var lastSixMonthsCount: Int = 0
    
    var olderSize: Int64 = 0
    var olderCount: Int = 0
}

/// Impact of cleanup operation
struct CleanupImpact {
    let deletedSize: Int64
    let deletedCount: Int
    let remainingSize: Int64
    let remainingCount: Int
    
    var deletionPercentage: Double {
        guard deletedSize + remainingSize > 0 else { return 0 }
        return Double(deletedSize) / Double(deletedSize + remainingSize) * 100
    }
}
