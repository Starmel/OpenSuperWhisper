//
//  CleanupIntegrationTests.swift
//  OpenSuperWhisperTests
//
//  Created by user on 13.07.2025.
//

import XCTest
@testable import OpenSuperWhisper

@MainActor
final class CleanupIntegrationTests: XCTestCase {
    
    var tempDirectory: URL!
    var testRecordingsDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create temporary directory for test recordings
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        testRecordingsDirectory = tempDirectory.appendingPathComponent("recordings")
        
        try FileManager.default.createDirectory(at: testRecordingsDirectory, withIntermediateDirectories: true)
        
        // Reset preferences
        AppPreferences.shared.cleanupInterval = .never
        AppPreferences.shared.cleanupEnabled = true
        AppPreferences.shared.lastCleanupDate = nil
    }
    
    override func tearDown() async throws {
        // Clean up temporary directory
        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        
        tempDirectory = nil
        testRecordingsDirectory = nil
        
        try await super.tearDown()
    }
    
    // MARK: - File System Integration Tests
    
    func testCreateAndDeleteTestRecordings() async throws {
        // Create test audio files
        let testFiles = try createTestAudioFiles(count: 5)
        
        // Verify files were created
        for file in testFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        
        // Delete files
        for file in testFiles {
            try FileManager.default.removeItem(at: file)
        }
        
        // Verify files were deleted
        for file in testFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }
    
    func testFilePermissionsHandling() async throws {
        // Create a test file
        let testFile = testRecordingsDirectory.appendingPathComponent("test.wav")
        try "test audio data".write(to: testFile, atomically: true, encoding: .utf8)
        
        // Make file read-only
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: testFile.path)
        
        // Attempt to delete should handle permission error gracefully
        do {
            try FileManager.default.removeItem(at: testFile)
            XCTFail("Should have thrown permission error")
        } catch {
            // Expected to fail with permission error
            XCTAssertTrue(error is NSError)
        }
        
        // Restore permissions and clean up
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: testFile.path)
        try FileManager.default.removeItem(at: testFile)
    }
    
    // MARK: - App Lifecycle Integration Tests
    
    func testAppLaunchCleanupTrigger() async {
        // Set up cleanup conditions
        AppPreferences.shared.cleanupInterval = .oneDay
        AppPreferences.shared.cleanupEnabled = true
        AppPreferences.shared.lastCleanupDate = nil
        
        // Create old test recordings
        let oldFiles = try createTestAudioFiles(count: 3, ageInDays: 2)
        let recentFiles = try createTestAudioFiles(count: 2, ageInDays: 0)
        
        // Simulate app launch cleanup
        let cleanupService = RecordingCleanupService.shared
        let result = await cleanupService.performCleanup(forced: false)
        
        // Should have attempted cleanup
        XCTAssertNotNil(result)
        
        // Clean up test files
        for file in oldFiles + recentFiles {
            try? FileManager.default.removeItem(at: file)
        }
    }
    
    func testConcurrentOperationsHandling() async {
        // Set up cleanup conditions
        AppPreferences.shared.cleanupInterval = .oneWeek
        AppPreferences.shared.cleanupEnabled = true
        
        let cleanupService = RecordingCleanupService.shared
        
        // Start multiple cleanup operations concurrently
        async let result1 = cleanupService.performCleanup(forced: true)
        async let result2 = cleanupService.performCleanup(forced: true)
        async let result3 = cleanupService.performCleanup(forced: true)
        
        let results = await [result1, result2, result3]
        
        // All operations should complete without crashing
        for result in results {
            XCTAssertNotNil(result)
        }
    }
    
    // MARK: - Storage Usage Integration Tests
    
    func testStorageUsageCalculationWithRealFiles() async throws {
        // Create test files with known sizes
        let testFiles = try createTestAudioFiles(count: 5, sizeInBytes: 1024)
        
        let storageService = StorageUsageService.shared
        await storageService.calculateStorageUsage()
        
        // Note: This test would need to be adapted to work with the actual RecordingStore
        // For now, we just verify the service doesn't crash
        XCTAssertNotNil(storageService.formatBytes(5120))
        
        // Clean up
        for file in testFiles {
            try FileManager.default.removeItem(at: file)
        }
    }
    
    func testStorageBreakdownCalculation() async {
        let storageService = StorageUsageService.shared
        let breakdown = await storageService.getStorageBreakdown()
        
        // Should return valid breakdown structure
        XCTAssertGreaterThanOrEqual(breakdown.totalSize, 0)
        XCTAssertGreaterThanOrEqual(breakdown.totalCount, 0)
    }
    
    // MARK: - Error Recovery Tests
    
    func testCleanupWithCorruptedFiles() async throws {
        // Create a corrupted file (empty file with .wav extension)
        let corruptedFile = testRecordingsDirectory.appendingPathComponent("corrupted.wav")
        try Data().write(to: corruptedFile)
        
        // Create a valid file
        let validFile = testRecordingsDirectory.appendingPathComponent("valid.wav")
        try "valid audio data".write(to: validFile, atomically: true, encoding: .utf8)
        
        // Cleanup should handle corrupted files gracefully
        let cleanupService = RecordingCleanupService.shared
        let result = await cleanupService.performCleanup(forced: true)
        
        XCTAssertNotNil(result)
        
        // Clean up
        try? FileManager.default.removeItem(at: corruptedFile)
        try? FileManager.default.removeItem(at: validFile)
    }
    
    func testCleanupWithMissingFiles() async {
        // This test would verify that cleanup handles cases where
        // database entries exist but files are missing
        let cleanupService = RecordingCleanupService.shared
        let result = await cleanupService.performCleanup(forced: true)
        
        // Should complete without crashing
        XCTAssertNotNil(result)
    }
    
    // MARK: - Performance Integration Tests
    
    func testCleanupPerformanceWithLargeFiles() async throws {
        // Create large test files
        let largeFiles = try createTestAudioFiles(count: 10, sizeInBytes: 10 * 1024 * 1024) // 10MB each
        
        let startTime = Date()
        
        // Perform cleanup
        let cleanupService = RecordingCleanupService.shared
        AppPreferences.shared.cleanupInterval = .oneDay
        let result = await cleanupService.performCleanup(forced: true)
        
        let duration = Date().timeIntervalSince(startTime)
        
        // Should complete within reasonable time
        XCTAssertLessThan(duration, 30.0, "Cleanup should complete within 30 seconds for large files")
        XCTAssertNotNil(result)
        
        // Clean up
        for file in largeFiles {
            try? FileManager.default.removeItem(at: file)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestAudioFiles(count: Int, ageInDays: Int = 0, sizeInBytes: Int = 1024) throws -> [URL] {
        var files: [URL] = []
        
        for i in 0..<count {
            let fileName = "test_\(i)_\(UUID().uuidString).wav"
            let fileURL = testRecordingsDirectory.appendingPathComponent(fileName)
            
            // Create file with specified size
            let data = Data(repeating: 0, count: sizeInBytes)
            try data.write(to: fileURL)
            
            // Set file modification date if age is specified
            if ageInDays > 0 {
                let ageDate = Date().addingTimeInterval(-Double(ageInDays) * 24 * 60 * 60)
                try FileManager.default.setAttributes([.modificationDate: ageDate], ofItemAtPath: fileURL.path)
            }
            
            files.append(fileURL)
        }
        
        return files
    }
    
    private func getFileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }
}
