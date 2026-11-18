import XCTest
@testable import OpenSuperWhisper

/// Installing a new version over an old one must converge: no preference may
/// keep pointing at a file the app does not own, and a model id this build does
/// not ship must not be handed to the built-in runtime.
final class PreferencesMigrationTests: XCTestCase {

    private var root: URL!
    private var modelsDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-migration-\(UUID().uuidString)")
        modelsDirectory = root.appendingPathComponent("Library/Application Support/ru.starmel.OpenSuperWhisper/whisper-models")
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Whisper model paths

    func testAdoptedModelPath_keepsAPathAlreadyInsideAppStorage() throws {
        let owned = modelsDirectory.appendingPathComponent("ggml-tiny.en.bin")
        try Data(repeating: 1, count: 16).write(to: owned)

        XCTAssertEqual(
            AppPreferences.adoptedModelPath(stored: owned.path, modelsDirectory: modelsDirectory),
            owned.path
        )
    }

    func testAdoptedModelPath_copiesAModelFromOutsideAppStorage() throws {
        let foreign = root.appendingPathComponent("checkout/ggml-tiny.en.bin")
        try FileManager.default.createDirectory(
            at: foreign.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 7, count: 32).write(to: foreign)

        let adopted = try XCTUnwrap(
            AppPreferences.adoptedModelPath(stored: foreign.path, modelsDirectory: modelsDirectory)
        )

        XCTAssertEqual(adopted, modelsDirectory.appendingPathComponent("ggml-tiny.en.bin").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: adopted), "the model must survive the move")
    }

    func testAdoptedModelPath_doesNotClobberAnAppOwnedCopy() throws {
        let owned = modelsDirectory.appendingPathComponent("ggml-tiny.en.bin")
        try Data(repeating: 1, count: 16).write(to: owned)

        let foreign = root.appendingPathComponent("elsewhere/ggml-tiny.en.bin")
        try FileManager.default.createDirectory(
            at: foreign.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 9, count: 16).write(to: foreign)

        XCTAssertEqual(
            AppPreferences.adoptedModelPath(stored: foreign.path, modelsDirectory: modelsDirectory),
            owned.path
        )
        XCTAssertEqual(try Data(contentsOf: owned), Data(repeating: 1, count: 16))
    }

    func testAdoptedModelPath_dropsAPathWhoseFileIsGone() {
        let missing = root.appendingPathComponent("checkout/ggml-tiny.en.bin")

        XCTAssertNil(AppPreferences.adoptedModelPath(stored: missing.path, modelsDirectory: modelsDirectory))
        XCTAssertNil(AppPreferences.adoptedModelPath(stored: "  ", modelsDirectory: modelsDirectory))
    }

    func testAdoptedModelPath_isIdempotent() throws {
        let foreign = root.appendingPathComponent("checkout/ggml-small.bin")
        try FileManager.default.createDirectory(
            at: foreign.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 5, count: 16).write(to: foreign)

        let first = AppPreferences.adoptedModelPath(stored: foreign.path, modelsDirectory: modelsDirectory)
        let second = AppPreferences.adoptedModelPath(stored: foreign.path, modelsDirectory: modelsDirectory)

        XCTAssertEqual(first, second, "running the migration twice must not move anything twice")
        XCTAssertEqual(first, modelsDirectory.appendingPathComponent("ggml-small.bin").path)
    }
}
