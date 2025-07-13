//
//  RecordingCleanupService.swift
//  OpenSuperWhisper
//
//  Created by user on 13.07.2025.
//

import Foundation
import GRDB
import UserNotifications
import os.log

@MainActor
class RecordingCleanupService: ObservableObject {
    static let shared = RecordingCleanupService()
    
    @Published var isCleaningUp = false
    @Published var cleanupProgress: Double = 0.0
    @Published var lastCleanupResult: CleanupResult?
    
    private var cleanupTimer: Timer?
    private let recordingStore = RecordingStore.shared
    private let audioRecorder = AudioRecorder.shared
    private let transcriptionService = TranscriptionService.shared

    // Logging
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenSuperWhisper", category: "RecordingCleanup")

    // Performance optimization settings
    private let batchSize = 50 // Process recordings in batches
    private let maxConcurrentDeletions = 5 // Limit concurrent file operations
    
    private init() {
        setupPeriodicCleanup()
        requestNotificationPermissions()
    }
    
    deinit {
        cleanupTimer?.invalidate()
    }
    
    /// Perform cleanup based on current preferences
    /// - Parameter forced: If true, ignores the last cleanup date and performs cleanup regardless
    /// - Returns: CleanupResult with details of the operation
    func performCleanup(forced: Bool = false) async -> CleanupResult {
        let preferences = AppPreferences.shared

        logger.info("Starting cleanup operation (forced: \(forced))")

        // Check if cleanup is enabled
        guard preferences.cleanupEnabled else {
            logger.info("Cleanup disabled, skipping")
            return CleanupResult(deletedCount: 0, deletedSize: 0, errors: [], duration: 0)
        }

        // Check if we need to cleanup based on interval
        if !forced && !shouldPerformCleanup() {
            logger.info("Cleanup not needed based on interval and last cleanup date")
            return CleanupResult(deletedCount: 0, deletedSize: 0, errors: [], duration: 0)
        }

        let startTime = Date()
        isCleaningUp = true
        cleanupProgress = 0.0

        defer {
            isCleaningUp = false
            cleanupProgress = 0.0
        }
        
        do {
            let result = try await performCleanupOperation()
            
            // Update last cleanup date on success
            if result.isSuccess || result.hasPartialSuccess {
                preferences.lastCleanupDate = Date()
            }
            
            let finalResult = CleanupResult(
                deletedCount: result.deletedCount,
                deletedSize: result.deletedSize,
                errors: result.errors,
                duration: Date().timeIntervalSince(startTime)
            )
            
            lastCleanupResult = finalResult

            // Show notification for significant cleanup results
            if forced || finalResult.deletedCount > 0 || !finalResult.errors.isEmpty {
                showCleanupNotification(result: finalResult)
            }

            return finalResult
            
        } catch {
            let errorResult = CleanupResult(
                deletedCount: 0,
                deletedSize: 0,
                errors: [.unknown(error.localizedDescription)],
                duration: Date().timeIntervalSince(startTime)
            )
            
            lastCleanupResult = errorResult
            return errorResult
        }
    }
    
    /// Check if cleanup should be performed based on preferences and last cleanup date
    private func shouldPerformCleanup() -> Bool {
        let preferences = AppPreferences.shared
        let cleanupInterval = preferences.cleanupInterval
        
        // Never cleanup if set to never
        guard cleanupInterval != .never else { return false }
        
        // Always cleanup if no last cleanup date
        guard let lastCleanup = preferences.lastCleanupDate else { return true }
        
        // Check if enough time has passed since last cleanup (daily check)
        let daysSinceLastCleanup = Date().timeIntervalSince(lastCleanup) / (24 * 60 * 60)
        return daysSinceLastCleanup >= 1.0
    }
    
    /// Perform the actual cleanup operation with batching for performance
    private func performCleanupOperation() async throws -> CleanupResult {
        let preferences = AppPreferences.shared
        let cleanupInterval = preferences.cleanupInterval

        guard cleanupInterval != .never else {
            logger.info("Cleanup interval set to never, skipping")
            return CleanupResult(deletedCount: 0, deletedSize: 0, errors: [], duration: 0)
        }

        // Get all recordings
        let allRecordings = recordingStore.recordings
        logger.info("Found \(allRecordings.count) total recordings")

        // Filter recordings that should be cleaned up
        let recordingsToDelete = allRecordings.filter { recording in
            cleanupInterval.shouldCleanup(recordingDate: recording.timestamp)
        }

        guard !recordingsToDelete.isEmpty else {
            logger.info("No recordings match cleanup criteria")
            return CleanupResult(deletedCount: 0, deletedSize: 0, errors: [], duration: 0)
        }

        logger.info("Found \(recordingsToDelete.count) recordings to delete")

        var deletedCount = 0
        var deletedSize: Int64 = 0
        var errors: [CleanupError] = []

        let totalRecordings = recordingsToDelete.count

        // Process recordings in batches for better performance
        let batches = recordingsToDelete.chunked(into: batchSize)

        for (batchIndex, batch) in batches.enumerated() {
            logger.debug("Processing batch \(batchIndex + 1) of \(batches.count) (size: \(batch.count))")

            // Process batch with limited concurrency
            await withTaskGroup(of: (Recording, Result<Int64, CleanupError>).self) { group in
                let semaphore = AsyncSemaphore(value: maxConcurrentDeletions)

                for recording in batch {
                    group.addTask {
                        await semaphore.wait()
                        defer {
                            Task { await semaphore.signal() }
                        }

                        // Check if recording is safe to delete
                        guard await self.isRecordingSafeToDelete(recording) else {
                            return (recording, .failure(.recordingInUse(recording.fileName)))
                        }

                        do {
                            // Get file size before deletion
                            let fileSize = try await self.getFileSize(for: recording)

                            // Delete the recording
                            try await self.deleteRecording(recording)

                            return (recording, .success(fileSize))
                        } catch let error as CleanupError {
                            return (recording, .failure(error))
                        } catch {
                            return (recording, .failure(.unknown(error.localizedDescription)))
                        }
                    }
                }

                // Collect results from batch
                for await (recording, result) in group {
                    switch result {
                    case .success(let fileSize):
                        deletedCount += 1
                        deletedSize += fileSize
                        logger.debug("Deleted recording: \(recording.fileName)")
                    case .failure(let error):
                        errors.append(error)
                        logger.warning("Failed to delete recording \(recording.fileName): \(error.localizedDescription)")
                    }
                }
            }

            // Update progress after each batch
            let processedCount = (batchIndex + 1) * batchSize
            cleanupProgress = Double(min(processedCount, totalRecordings)) / Double(totalRecordings)

            // Yield to allow UI updates
            await Task.yield()
        }

        cleanupProgress = 1.0
        logger.info("Cleanup completed: deleted \(deletedCount) recordings, \(deletedSize) bytes, \(errors.count) errors")

        return CleanupResult(
            deletedCount: deletedCount,
            deletedSize: deletedSize,
            errors: errors,
            duration: 0 // Will be set by caller
        )
    }
    
    /// Check if a recording is safe to delete (not currently in use)
    private func isRecordingSafeToDelete(_ recording: Recording) -> Bool {
        // Check if currently recording
        if audioRecorder.isRecording {
            return false
        }

        // Check if currently playing this recording
        if let currentlyPlaying = audioRecorder.currentlyPlayingURL,
           currentlyPlaying == recording.url {
            return false
        }

        // Check if currently transcribing
        if transcriptionService.isTranscribing {
            return false
        }

        // Check if file is locked or in use by another process
        if isFileLocked(recording.url) {
            return false
        }

        return true
    }

    /// Check if a file is locked or in use by another process
    private func isFileLocked(_ url: URL) -> Bool {
        do {
            // Try to open the file for writing to check if it's locked
            let fileHandle = try FileHandle(forWritingTo: url)
            fileHandle.closeFile()
            return false
        } catch {
            // If we can't open for writing, it might be locked
            return true
        }
    }
    
    /// Get file size for a recording
    private func getFileSize(for recording: Recording) throws -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: recording.url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            throw CleanupError.fileNotFound(recording.fileName)
        }
    }
    
    /// Delete a recording safely
    private func deleteRecording(_ recording: Recording) async throws {
        do {
            // Delete file only - the app will handle database cleanup naturally
            // when it detects missing files during normal operation
            try FileManager.default.removeItem(at: recording.url)

        } catch let error as NSError {
            // Handle specific file system errors
            switch error.code {
            case NSFileReadNoSuchFileError:
                throw CleanupError.fileNotFound(recording.fileName)
            case NSFileWriteFileExistsError, NSFileWriteNoPermissionError:
                throw CleanupError.permissionDenied(recording.fileName)
            default:
                if error.domain == NSCocoaErrorDomain {
                    throw CleanupError.databaseError(error.localizedDescription)
                } else {
                    throw CleanupError.unknown(error.localizedDescription)
                }
            }
        }
    }
    
    /// Setup periodic cleanup timer (daily check)
    private func setupPeriodicCleanup() {
        // Schedule daily cleanup check at 3 AM
        let calendar = Calendar.current
        let now = Date()
        
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 3
        components.minute = 0
        components.second = 0
        
        guard let nextCleanupTime = calendar.date(from: components) else { return }
        
        let timeUntilNextCleanup = nextCleanupTime.timeIntervalSince(now)
        let adjustedTime = timeUntilNextCleanup > 0 ? timeUntilNextCleanup : timeUntilNextCleanup + 24 * 60 * 60
        
        DispatchQueue.main.asyncAfter(deadline: .now() + adjustedTime) {
            self.startDailyCleanupTimer()
        }
    }
    
    /// Start the daily cleanup timer
    private func startDailyCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in
            Task {
                await self.performCleanup()
            }
        }
    }
    
    /// Cancel any ongoing cleanup operation
    func cancelCleanup() {
        isCleaningUp = false
        cleanupProgress = 0.0
    }

    /// Show user notification for cleanup results
    private func showCleanupNotification(result: CleanupResult) {
        guard result.deletedCount > 0 || !result.errors.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "Recording Cleanup Complete"

        if result.isSuccess && result.deletedCount > 0 {
            let sizeString = ByteCountFormatter().string(fromByteCount: result.deletedSize)
            content.body = "Deleted \(result.deletedCount) recordings, freed \(sizeString)"
            content.sound = .default
        } else if result.hasPartialSuccess {
            content.body = "Deleted \(result.deletedCount) recordings with \(result.errors.count) errors"
            content.sound = .default
        } else if !result.errors.isEmpty {
            content.body = "Cleanup failed with \(result.errors.count) errors"
            content.sound = .defaultCritical
        }

        let request = UNNotificationRequest(
            identifier: "cleanup-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to show cleanup notification: \(error)")
            }
        }
    }

    /// Request notification permissions if needed
    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Failed to request notification permissions: \(error)")
            }
        }
    }
}



// MARK: - Helper Extensions and Classes

/// Async semaphore for limiting concurrent operations
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.count = value
    }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if waiters.isEmpty {
            count += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}

/// Array extension for chunking
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
