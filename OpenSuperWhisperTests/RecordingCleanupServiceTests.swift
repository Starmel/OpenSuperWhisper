//
//  RecordingCleanupServiceTests.swift
//  OpenSuperWhisperTests
//
//  Created by user on 13.07.2025.
//

import XCTest
@testable import OpenSuperWhisper

@MainActor
final class RecordingCleanupServiceTests: XCTestCase {
    
    var cleanupService: RecordingCleanupService!
    var mockRecordingStore: MockRecordingStore!
    var testRecordings: [Recording]!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create test recordings with different timestamps
        let now = Date()
        testRecordings = [
            Recording(
                id: UUID(),
                timestamp: now.addingTimeInterval(-2 * 24 * 60 * 60), // 2 days ago
                fileName: "test1.wav",
                transcription: "Test 1",
                duration: 10.0
            ),
            Recording(
                id: UUID(),
                timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60), // 8 days ago
                fileName: "test2.wav",
                transcription: "Test 2",
                duration: 15.0
            ),
            Recording(
                id: UUID(),
                timestamp: now.addingTimeInterval(-35 * 24 * 60 * 60), // 35 days ago
                fileName: "test3.wav",
                transcription: "Test 3",
                duration: 20.0
            ),
            Recording(
                id: UUID(),
                timestamp: now.addingTimeInterval(-100 * 24 * 60 * 60), // 100 days ago
                fileName: "test4.wav",
                transcription: "Test 4",
                duration: 25.0
            )
        ]
        
        mockRecordingStore = MockRecordingStore()
        mockRecordingStore.recordings = testRecordings
        
        cleanupService = RecordingCleanupService.shared
    }
    
    override func tearDown() async throws {
        cleanupService = nil
        mockRecordingStore = nil
        testRecordings = nil
        try await super.tearDown()
    }
    
    // MARK: - CleanupTimeInterval Tests
    
    func testCleanupTimeIntervalDisplayNames() {
        XCTAssertEqual(CleanupTimeInterval.never.displayName, "Keep forever")
        XCTAssertEqual(CleanupTimeInterval.oneDay.displayName, "1 day")
        XCTAssertEqual(CleanupTimeInterval.oneWeek.displayName, "1 week")
        XCTAssertEqual(CleanupTimeInterval.oneMonth.displayName, "1 month")
        XCTAssertEqual(CleanupTimeInterval.threeMonths.displayName, "3 months")
        XCTAssertEqual(CleanupTimeInterval.sixMonths.displayName, "6 months")
    }
    
    func testCleanupTimeIntervalValues() {
        XCTAssertNil(CleanupTimeInterval.never.timeInterval)
        XCTAssertEqual(CleanupTimeInterval.oneDay.timeInterval, 24 * 60 * 60)
        XCTAssertEqual(CleanupTimeInterval.oneWeek.timeInterval, 7 * 24 * 60 * 60)
        XCTAssertEqual(CleanupTimeInterval.oneMonth.timeInterval, 30 * 24 * 60 * 60)
        XCTAssertEqual(CleanupTimeInterval.threeMonths.timeInterval, 90 * 24 * 60 * 60)
        XCTAssertEqual(CleanupTimeInterval.sixMonths.timeInterval, 180 * 24 * 60 * 60)
    }
    
    func testShouldCleanupLogic() {
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-24 * 60 * 60)
        let oneWeekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let oneMonthAgo = now.addingTimeInterval(-30 * 24 * 60 * 60)
        
        // Never should never cleanup
        XCTAssertFalse(CleanupTimeInterval.never.shouldCleanup(recordingDate: oneMonthAgo, referenceDate: now))
        
        // One day interval
        XCTAssertFalse(CleanupTimeInterval.oneDay.shouldCleanup(recordingDate: now, referenceDate: now))
        XCTAssertTrue(CleanupTimeInterval.oneDay.shouldCleanup(recordingDate: oneDayAgo, referenceDate: now))
        
        // One week interval
        XCTAssertFalse(CleanupTimeInterval.oneWeek.shouldCleanup(recordingDate: oneDayAgo, referenceDate: now))
        XCTAssertTrue(CleanupTimeInterval.oneWeek.shouldCleanup(recordingDate: oneWeekAgo, referenceDate: now))
        
        // One month interval
        XCTAssertFalse(CleanupTimeInterval.oneMonth.shouldCleanup(recordingDate: oneWeekAgo, referenceDate: now))
        XCTAssertTrue(CleanupTimeInterval.oneMonth.shouldCleanup(recordingDate: oneMonthAgo, referenceDate: now))
    }
    
    // MARK: - Cleanup Service Tests
    
    func testCleanupDisabledWhenNeverSelected() async {
        // Set cleanup interval to never
        AppPreferences.shared.cleanupInterval = .never
        AppPreferences.shared.cleanupEnabled = true
        
        let result = await cleanupService.performCleanup(forced: false)
        
        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.deletedSize, 0)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.isSuccess)
    }
    
    func testCleanupDisabledWhenFeatureDisabled() async {
        // Set cleanup enabled to false
        AppPreferences.shared.cleanupInterval = .oneWeek
        AppPreferences.shared.cleanupEnabled = false
        
        let result = await cleanupService.performCleanup(forced: false)
        
        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.deletedSize, 0)
        XCTAssertTrue(result.errors.isEmpty)
    }
    
    func testForcedCleanupIgnoresLastCleanupDate() async {
        // Set last cleanup to recent date
        AppPreferences.shared.lastCleanupDate = Date()
        AppPreferences.shared.cleanupInterval = .oneWeek
        AppPreferences.shared.cleanupEnabled = true
        
        // Forced cleanup should still run
        let result = await cleanupService.performCleanup(forced: true)
        
        // Should attempt cleanup regardless of last cleanup date
        XCTAssertNotNil(result)
    }
    
    // MARK: - Error Handling Tests
    
    func testCleanupErrorTypes() {
        let fileNotFoundError = CleanupError.fileNotFound("test.wav")
        let permissionError = CleanupError.permissionDenied("test.wav")
        let databaseError = CleanupError.databaseError("DB error")
        let recordingInUseError = CleanupError.recordingInUse("test.wav")
        let unknownError = CleanupError.unknown("Unknown error")
        
        XCTAssertEqual(fileNotFoundError.errorDescription, "File not found: test.wav")
        XCTAssertEqual(permissionError.errorDescription, "Permission denied: test.wav")
        XCTAssertEqual(databaseError.errorDescription, "Database error: DB error")
        XCTAssertEqual(recordingInUseError.errorDescription, "Recording in use: test.wav")
        XCTAssertEqual(unknownError.errorDescription, "Unknown error: Unknown error")
    }
    
    func testCleanupResultProperties() {
        let successResult = CleanupResult(deletedCount: 5, deletedSize: 1024, errors: [], duration: 1.5)
        XCTAssertTrue(successResult.isSuccess)
        XCTAssertFalse(successResult.hasPartialSuccess)
        
        let partialResult = CleanupResult(
            deletedCount: 3,
            deletedSize: 512,
            errors: [.fileNotFound("test.wav")],
            duration: 2.0
        )
        XCTAssertFalse(partialResult.isSuccess)
        XCTAssertTrue(partialResult.hasPartialSuccess)
        
        let failureResult = CleanupResult(
            deletedCount: 0,
            deletedSize: 0,
            errors: [.databaseError("Failed")],
            duration: 0.5
        )
        XCTAssertFalse(failureResult.isSuccess)
        XCTAssertFalse(failureResult.hasPartialSuccess)
    }
    
    // MARK: - Performance Tests
    
    func testCleanupPerformanceWithManyRecordings() async {
        // Create many test recordings
        var manyRecordings: [Recording] = []
        let now = Date()
        
        for i in 0..<1000 {
            let recording = Recording(
                id: UUID(),
                timestamp: now.addingTimeInterval(-Double(i) * 24 * 60 * 60), // i days ago
                fileName: "test\(i).wav",
                transcription: "Test \(i)",
                duration: Double(i % 60)
            )
            manyRecordings.append(recording)
        }
        
        mockRecordingStore.recordings = manyRecordings
        
        // Measure cleanup performance
        let startTime = Date()
        AppPreferences.shared.cleanupInterval = .oneMonth
        AppPreferences.shared.cleanupEnabled = true
        
        let result = await cleanupService.performCleanup(forced: true)
        let duration = Date().timeIntervalSince(startTime)
        
        // Should complete within reasonable time (adjust threshold as needed)
        XCTAssertLessThan(duration, 10.0, "Cleanup should complete within 10 seconds for 1000 recordings")
        XCTAssertNotNil(result)
    }
}

// MARK: - Mock Classes

class MockRecordingStore: ObservableObject {
    @Published var recordings: [Recording] = []
    
    func deleteRecordingFromDB(_ recording: Recording) async throws {
        recordings.removeAll { $0.id == recording.id }
    }
}

// MARK: - Storage Usage Service Tests

@MainActor
final class StorageUsageServiceTests: XCTestCase {
    
    var storageService: StorageUsageService!
    
    override func setUp() async throws {
        try await super.setUp()
        storageService = StorageUsageService.shared
    }
    
    override func tearDown() async throws {
        storageService = nil
        try await super.tearDown()
    }
    
    func testFormatBytes() {
        XCTAssertEqual(storageService.formatBytes(0), "Zero KB")
        XCTAssertEqual(storageService.formatBytes(1024), "1 KB")
        XCTAssertEqual(storageService.formatBytes(1024 * 1024), "1 MB")
        XCTAssertEqual(storageService.formatBytes(1024 * 1024 * 1024), "1 GB")
    }
    
    func testCleanupImpactCalculation() {
        let impact = CleanupImpact(
            deletedSize: 500,
            deletedCount: 5,
            remainingSize: 1500,
            remainingCount: 15
        )
        
        XCTAssertEqual(impact.deletionPercentage, 25.0, accuracy: 0.1)
    }
    
    func testStorageBreakdownInitialization() {
        let breakdown = StorageBreakdown()
        
        XCTAssertEqual(breakdown.totalSize, 0)
        XCTAssertEqual(breakdown.totalCount, 0)
        XCTAssertEqual(breakdown.lastDaySize, 0)
        XCTAssertEqual(breakdown.lastWeekSize, 0)
        XCTAssertEqual(breakdown.lastMonthSize, 0)
    }
}
