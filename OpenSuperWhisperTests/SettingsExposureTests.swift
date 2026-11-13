import CryptoKit
import XCTest

@testable import OpenSuperWhisper

/// The Advanced tab's Debug Mode used to be a toggle that wrote a preference
/// nothing read, so it changed nothing at all. It now reaches the decoder's
/// parameters, which is the difference between a control and a decoration.
@MainActor
final class SettingsExposureTests: XCTestCase {

    private var savedDebugMode: Bool!

    override func setUp() {
        super.setUp()
        savedDebugMode = AppPreferences.shared.debugMode
    }

    override func tearDown() {
        AppPreferences.shared.debugMode = savedDebugMode
        super.tearDown()
    }

    func testDebugModeReachesTheDecoderParameters() {
        AppPreferences.shared.debugMode = true
        let on = WhisperEngine.makeFullParams(settings: Settings(), nThreads: 4,
                                              modelTextContext: 448, initialPromptTokenCount: 0)
        XCTAssertTrue(on.debugMode, "Debug Mode has to turn the decoder's verbose trace on")

        AppPreferences.shared.debugMode = false
        let off = WhisperEngine.makeFullParams(settings: Settings(), nThreads: 4,
                                               modelTextContext: 448, initialPromptTokenCount: 0)
        XCTAssertFalse(off.debugMode, "…and off again when the toggle is off")
    }

    func testTheSettingsSnapshotCarriesTheStoredDebugMode() {
        AppPreferences.shared.debugMode = true
        XCTAssertTrue(Settings().debugMode, "the per-dictation settings read the preference")
    }

    // MARK: - The transform model card

    /// A view model over a temporary directory and small stand-ins for the
    /// catalogue's two entries (same ids, same shapes, bytes instead of
    /// gigabytes), so what the card says is decided by this test's staging and
    /// nothing here touches the user's Application Support.
    private func card() throws -> (SettingsViewModel, TransformModelManager, URL, TransformModel, TransformModel) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let payload = Data(repeating: 0x5A, count: 512)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        func entry(_ id: String, _ name: String, _ file: String,
                   style: TransformPromptStyle) -> TransformModel {
            TransformModel(
                id: id,
                displayName: name,
                fileName: file,
                style: style,
                downloadURL: URL(string: "https://example.invalid/\(file)")!,
                sha256: digest,
                sizeBytes: Int64(payload.count),
                memoryBytes: 1024,
                licence: "Apache-2.0",
                source: "test"
            )
        }
        let normalizer = entry(TransformModelManager.normalizerModelID, "S1-mini Test Model", "s1-mini.gguf",
                               style: .normalizer)
        let tone = entry(TransformModelManager.toneModelID, "Qwen2.5 Test Model", "qwen7b.gguf",
                         style: .instruction)

        let manager = TransformModelManager(directory: directory,
                                           catalogue: [normalizer, tone])
        let model = SettingsViewModel(transformModelManager: manager)
        return (model, manager, directory, normalizer, tone)
    }

    /// Stages `model`'s bytes in the manager's own directory, so the card's
    /// "is it installed" answer comes from a real verified file.
    private func stage(_ model: TransformModel, in manager: TransformModelManager, directory: URL) throws {
        let source = directory.appendingPathComponent("source-\(model.id).gguf")
        let payload = Data(repeating: 0x5A, count: Int(model.sizeBytes))
        try payload.write(to: source)
        try manager.install(fileAt: source, model: model)
    }

    /// The card names both models, each for the job it does, and the presence
    /// line states what is installed. What is asserted is the semantics: the two
    /// rows are the real catalogue, `model(for:)` routes each job, and the
    /// description names the tone model rather than claiming the transform is
    /// English-only.
    func testTheCardNamesBothBackendsAndTheirJobs() throws {
        let (model, manager, directory, normalizer, tone) = try card()
        defer { try? FileManager.default.removeItem(at: directory) }

        model.installedTransformModelIDs = []

        // The card lists the real catalogue, both rows in order.
        XCTAssertEqual(model.transformModels.map(\.id),
                       [TransformModelManager.normalizerModelID, TransformModelManager.toneModelID])
        XCTAssertEqual(model.transformModel.id, normalizer.id)
        XCTAssertEqual(model.toneTransformModel.id, tone.id)

        // The description names the tone model — the model that reads Polish —
        // so the transform can no longer be read as English-only.
        let description = model.transformLanguageModelDescription
        XCTAssertTrue(description.contains(tone.displayName), description)
        XCTAssertTrue(description.contains("Polish"), description)
        XCTAssertTrue(description.contains("installed"), description)

        // The resolution behind the card's sentence: tone and the e-mail mode on
        // the instruction model, in either language; English clean-up alone on
        // the normalizer.
        XCTAssertEqual(manager.model(for: .tone(language: .english, tone: .neutral)).id, tone.id)
        XCTAssertEqual(manager.model(for: .tone(language: .polish, tone: .formal)).id, tone.id)
        XCTAssertEqual(manager.model(for: .email(language: .polish, tone: .neutral)).id, tone.id)
        XCTAssertEqual(manager.model(for: .cleanUp(language: .english)).id, normalizer.id)

        // Each row is its own requirement: the notice is per model and non-nil
        // whenever that model is absent, and each describes its own job.
        let normalizerNotice = try XCTUnwrap(model.transformMissingNotice(for: normalizer))
        let toneNotice = try XCTUnwrap(model.transformMissingNotice(for: tone))
        XCTAssertTrue(normalizerNotice.contains("clean-up"), normalizerNotice)
        XCTAssertNotEqual(normalizerNotice, toneNotice,
                          "each missing model costs a different job, so the notices differ")
    }

    /// With the weights on disk the card confirms both models and the warnings it
    /// gave while they were missing are gone.
    func testWithTheWeightsInstalledTheCardReportsBothPresent() throws {
        let (model, manager, directory, normalizer, tone) = try card()
        defer { try? FileManager.default.removeItem(at: directory) }

        try stage(normalizer, in: manager, directory: directory)
        try stage(tone, in: manager, directory: directory)
        model.installedTransformModelIDs = [normalizer.id, tone.id]

        let description = model.transformLanguageModelDescription
        XCTAssertTrue(description.contains(tone.displayName), description)
        XCTAssertNil(model.transformMissingNotice(for: normalizer), "nothing is missing here")
        XCTAssertNil(model.transformMissingNotice(for: tone), "nothing is missing here")
        TestFixtures.report("[settings] the card with both models installed: \(description)")
    }

    /// Each row states its job and what its model costs before it is paid, and the
    /// routing is asserted as the resolution itself — the row's words cannot fail,
    /// the routing can.
    func testTheRowsStateTheirJobsAndTheirCosts() throws {
        let (model, _, directory, normalizer, tone) = try card()
        defer { try? FileManager.default.removeItem(at: directory) }

        // What each row is for, in behaviour words: the normalizer is the
        // clean-up backend, the instruction model the tone and e-mail one, and
        // the two rows must not say the same thing.
        let normalizerRole = model.transformModelRoleDescription(normalizer)
        XCTAssertTrue(normalizerRole.lowercased().contains("clean-up"), normalizerRole)
        let toneRole = model.transformModelRoleDescription(tone)
        XCTAssertTrue(toneRole.lowercased().contains("tone"), toneRole)
        XCTAssertTrue(toneRole.lowercased().contains("e-mail"), toneRole)
        XCTAssertNotEqual(normalizerRole, toneRole, "the two rows must not share one role sentence")

        // The header names both models, so neither row can be read as the whole
        // product.
        let header = model.transformModelsHeaderDescription
        XCTAssertTrue(header.contains("S1-mini"), header)
        XCTAssertTrue(header.contains("Qwen2.5"), header)

        // Each row's state: not downloaded first, with its own disk and RAM cost.
        for row in [normalizer, tone] {
            let state = model.transformModelStateDescription(row)
            XCTAssertTrue(state.hasPrefix("Not downloaded"), state)
            XCTAssertTrue(state.contains(row.memoryDescription), state)
            XCTAssertTrue(state.contains(row.sizeDescription), state)
        }

        model.installedTransformModelIDs = [normalizer.id, tone.id]
        for row in [normalizer, tone] {
            XCTAssertTrue(model.transformModelStateDescription(row).hasPrefix("Installed"),
                          model.transformModelStateDescription(row))
        }
    }
}
