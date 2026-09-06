import XCTest
@testable import OpenSuperWhisper

final class RecordingFileIdentityTests: XCTestCase {
    func testSimultaneousRecordingsKeepIndependentAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent(Recording.fileName(for: UUID()))
        let second = directory.appendingPathComponent(Recording.fileName(for: UUID()))
        XCTAssertNotEqual(first, second)
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        try FileManager.default.removeItem(at: first)
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }

    func testSavingCannotOverwriteExistingAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let destination = directory.appendingPathComponent("saved.wav")
        try Data([1]).write(to: source)
        try Data([2]).write(to: destination)
        XCTAssertThrowsError(try AudioRecorder.shared.moveTemporaryRecording(from: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data([2]))
        XCTAssertEqual(try Data(contentsOf: source), Data([1]))
    }
}
