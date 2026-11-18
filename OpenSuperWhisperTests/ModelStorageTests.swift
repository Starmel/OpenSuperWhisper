import XCTest

@testable import OpenSuperWhisper

/// The Model tab's storage controls, checked against real files: removing a
/// model deletes it from disk and says how much that freed, verifying compares a
/// file against the digest its publisher reports, and a selection that points at
/// a file which is gone is reported instead of quietly switching models.
///
/// Everything here runs in a fixture directory — `WhisperModelManager.modelsDirectory`
/// is the seam — so no test touches the models the running app uses.
@MainActor
final class ModelStorageTests: XCTestCase {

    private var fixtureDirectory: URL!
    private var savedModelsDirectory: URL!
    private var savedSelection: String?

    /// The sha256 of the bytes `writeFixtureModel` writes, computed with
    /// `shasum -a 256`, i.e. outside this code.
    private static let fixtureDigest = "3ab4ed3a368a23a487128eebab724f5323b5daacc97dc5dd8aeb617b5f59cdf9"
    private static let fixtureContents = Data("OpenSuperWhisper model fixture\n".utf8)

    /// The digest Hugging Face publishes for `ggml-tiny.en.bin`, the model this
    /// repository ships inside the app bundle.
    private static let publishedTinyEnSHA256 =
        "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"

    override func setUp() {
        super.setUp()
        savedModelsDirectory = WhisperModelManager.modelsDirectory
        savedSelection = AppPreferences.shared.selectedWhisperModelPath

        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-model-storage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        WhisperModelManager.modelsDirectory = fixtureDirectory
        AppPreferences.shared.selectedWhisperModelPath = nil
    }

    override func tearDown() {
        WhisperModelManager.modelsDirectory = savedModelsDirectory
        AppPreferences.shared.selectedWhisperModelPath = savedSelection
        try? FileManager.default.removeItem(at: fixtureDirectory)
        super.tearDown()
    }

    @discardableResult
    private func writeFixtureModel(named name: String, contents: Data? = nil) throws -> URL {
        let url = fixtureDirectory.appendingPathComponent(name)
        try (contents ?? Self.fixtureContents).write(to: url)
        return url
    }

    // MARK: - G-04: removal

    func testRemovingAModelDeletesTheFileAndReportsTheSpaceFreed() throws {
        let model = try writeFixtureModel(named: "ggml-large-v3-turbo-q5_0.bin")
        // A second model, so this is the ordinary case and not the
        // "nothing left, put the bundled one back" one.
        try writeFixtureModel(named: "hand-placed-model.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path), "precondition: the file is on disk")

        let notice = try WhisperModelManager.shared.removeModel(at: model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path),
                       "removing a model has to delete the file from disk")
        XCTAssertEqual(notice, .removed(name: model.lastPathComponent,
                                        bytesFreed: Int64(Self.fixtureContents.count)))
        XCTAssertEqual(WhisperModelManager.shared.lastNotice, notice,
                       "the Model tab shows this notice")
    }

    func testRemovingTheSelectedModelClearsTheSelectionSoAnotherOneTakesOver() throws {
        let selected = try writeFixtureModel(named: "ggml-large-v3-turbo-q5_0.bin")
        let other = try writeFixtureModel(named: "hand-placed-model.bin")
        AppPreferences.shared.selectedWhisperModelPath = selected.path

        _ = try WhisperModelManager.shared.removeModel(at: selected)

        XCTAssertNil(AppPreferences.shared.selectedWhisperModelPath,
                     "the removed file was the selection; leaving the path there would fail every dictation")
        XCTAssertEqual(WhisperModelManager.shared.getAvailableModels().map(\.lastPathComponent),
                       [other.lastPathComponent])
    }

    func testRemovingTheLastModelPutsTheBundledOneBack() throws {
        let only = try writeFixtureModel(named: "hand-placed-model.bin")

        let notice = try WhisperModelManager.shared.removeModel(at: only)

        XCTAssertEqual(notice, .restoredBundled(name: WhisperModelManager.defaultModelName))
        let bundled = fixtureDirectory.appendingPathComponent(WhisperModelManager.defaultModelName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.path),
                      "an empty models directory has to get the bundled model back")
        XCTAssertEqual(AppPreferences.shared.selectedWhisperModelPath, bundled.path)
    }

    // MARK: - G-05: what is on disk and which one is in use

    func testTheInstalledListMarksTheSelectedModelAndIncludesFilesOutsideTheCatalogue() throws {
        let catalogueName = "ggml-large-v3-turbo-q5_0.bin"
        let catalogueFile = try writeFixtureModel(named: catalogueName)
        try writeFixtureModel(named: "hand-placed-model.bin")
        AppPreferences.shared.selectedWhisperModelPath = catalogueFile.path

        let viewModel = SettingsViewModel()

        XCTAssertEqual(viewModel.installedWhisperModels.map(\.name).sorted(),
                       ["ggml-large-v3-turbo-q5_0.bin", "hand-placed-model.bin"],
                       "every file on disk is listed, catalogue entry or not")
        XCTAssertEqual(viewModel.installedWhisperModels.filter(\.isSelected).map(\.name), [catalogueName],
                       "exactly one model is marked as the one in use")
        XCTAssertEqual(viewModel.selectedModelDescription, catalogueName)

        let handPlaced = viewModel.installedWhisperModels.first { $0.name == "hand-placed-model.bin" }
        XCTAssertNil(handPlaced?.pinnedSHA256,
                     "a file outside the catalogue has no published checksum to compare against")
        XCTAssertEqual(viewModel.installedWhisperModels.first { $0.name == catalogueName }?.pinnedSHA256,
                       "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
                       "a catalogue file carries the digest its publisher reports")
        XCTAssertEqual(viewModel.installedWhisperModels.first { $0.name == catalogueName }?.sizeBytes,
                       Int64(Self.fixtureContents.count),
                       "the row shows the size actually on disk")
    }

    // MARK: - G-06: verification

    func testVerifyingAModelComparesTheFileAgainstThePinnedDigest() throws {
        let model = try writeFixtureModel(named: "ggml-large-v3-turbo-q5_0.bin")

        let matched = try WhisperModelManager.shared.verifyModel(at: model, pinnedSHA256: Self.fixtureDigest)
        XCTAssertEqual(matched.sha256, Self.fixtureDigest,
                       "the digest computed here has to be the digest of the bytes on disk")
        XCTAssertEqual(matched.matchesPinnedDigest, true)

        let mismatched = try WhisperModelManager.shared.verifyModel(at: model, pinnedSHA256: String(repeating: "0", count: 64))
        XCTAssertEqual(mismatched.matchesPinnedDigest, false,
                       "a file whose bytes differ from the pinned digest must not pass")

        let unpinned = try WhisperModelManager.shared.verifyModel(at: model, pinnedSHA256: nil)
        XCTAssertNil(unpinned.matchesPinnedDigest,
                     "with no published digest there is nothing to compare, and the row says so")
    }

    /// The check end to end, on the real model this repository ships: its digest
    /// has to be the one Hugging Face publishes for `ggml-tiny.en.bin`.
    func testTheBundledModelMatchesTheChecksumItsPublisherReports() throws {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "ggml-tiny.en", withExtension: "bin"),
                                   "the app bundle has to ship its speech model")

        let verification = try WhisperModelManager.shared
            .verifyModel(at: bundled, pinnedSHA256: Self.publishedTinyEnSHA256)

        XCTAssertEqual(verification.sha256, Self.publishedTinyEnSHA256,
                       "the bundled ggml-tiny.en.bin is not the file Hugging Face publishes")
        XCTAssertEqual(verification.matchesPinnedDigest, true)
        XCTAssertEqual(verification.sizeBytes, 77704715)
    }

    // MARK: - G-07: the fallback is reported

    func testAMissingSelectionIsReportedInsteadOfSwitchingModelsSilently() throws {
        let bundled = fixtureDirectory.appendingPathComponent(WhisperModelManager.defaultModelName)
        try Self.fixtureContents.write(to: bundled)
        let gone = fixtureDirectory.appendingPathComponent("was-here-yesterday.bin")
        AppPreferences.shared.selectedWhisperModelPath = gone.path

        WhisperModelManager.shared.ensureDefaultModelPresent()

        XCTAssertEqual(WhisperModelManager.shared.lastNotice,
                       .selectionWasMissing(was: "was-here-yesterday.bin",
                                            now: WhisperModelManager.defaultModelName),
                       "the Model tab has to say the model changed under the user")
        XCTAssertEqual(AppPreferences.shared.selectedWhisperModelPath, bundled.path)

        // …and the notice is a sentence the Model tab can print.
        XCTAssertTrue(WhisperModelManager.shared.lastNotice?.message.contains("was not on disk") == true)
    }
}
