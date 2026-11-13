import CryptoKit
import XCTest
@testable import OpenSuperWhisper

/// The transform weights are app-owned, checksum-verified and installed
/// atomically. These tests run against a temporary directory and a fake model,
/// so they never touch the user's Application Support.
final class TransformModelManagerTests: XCTestCase {

    private var directory: URL!
    private var manager: TransformModelManager!
    private var payload: Data!
    private var model: TransformModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-transform-\(UUID().uuidString)")
        payload = Data((0..<4096).map { UInt8($0 % 251) })
        model = TransformModel(
            id: "test-model",
            displayName: "Test Model",
            fileName: "test-model.gguf",
            style: .instruction,
            downloadURL: URL(string: "https://example.invalid/test-model.gguf")!,
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: Int64(payload.count),
            memoryBytes: 8_589_934_592,
            licence: "Apache-2.0",
            source: "test"
        )
        manager = TransformModelManager(directory: directory, catalogue: [model])
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func writeSourceFile(_ data: Data) throws -> URL {
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).download")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func model(withSHA256 sha256: String) -> TransformModel {
        TransformModel(
            id: model.id,
            displayName: model.displayName,
            fileName: model.fileName,
            style: model.style,
            downloadURL: model.downloadURL,
            sha256: sha256,
            sizeBytes: model.sizeBytes,
            memoryBytes: model.memoryBytes,
            licence: model.licence,
            source: model.source
        )
    }

    // MARK: - Install

    func testInstall_storesTheFileAndAcceptsThePinnedChecksum() throws {
        let source = try writeSourceFile(payload)

        try manager.install(fileAt: source, model: model)

        XCTAssertTrue(manager.hasModelFile(model))
        XCTAssertEqual(manager.verifiedPath(for: model), manager.fileURL(for: model).path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: manager.fileURL(for: model).path + ".part"),
            "the partial file must not survive a successful install"
        )
    }

    func testInstall_rejectsAMismatchedChecksumAndLeavesNothingBehind() throws {
        let source = try writeSourceFile(Data(repeating: 0xAB, count: 4096))
        let wrong = model(withSHA256: String(repeating: "0", count: 64))

        XCTAssertThrowsError(try manager.install(fileAt: source, model: wrong)) { error in
            guard case TransformModelError.checksumMismatch = error else {
                return XCTFail("expected a checksum mismatch, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(for: wrong).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(for: wrong).path + ".part"))
        XCTAssertNil(manager.verifiedPath(for: wrong))
    }

    // MARK: - Verification

    func testVerifiedPath_rehashesAFileThatWasReplacedBehindTheApp() throws {
        let source = try writeSourceFile(payload)
        try manager.install(fileAt: source, model: model)
        XCTAssertNotNil(manager.verifiedPath(for: model), "precondition: just installed and verified")

        // Same size, different bytes: the size check alone would accept this.
        let replacement = Data(repeating: 0x11, count: payload.count)
        try replacement.write(to: manager.fileURL(for: model))

        XCTAssertNil(
            manager.verifiedPath(for: model),
            "a file whose checksum no longer matches must never be handed to the runtime"
        )
    }

    func testVerifyInstalledModel_reportsTheChecksumOfTheFileOnDisk() throws {
        let source = try writeSourceFile(payload)
        XCTAssertFalse(manager.verifyInstalledModel(model), "nothing installed yet")

        try manager.install(fileAt: source, model: model)
        XCTAssertTrue(manager.verifyInstalledModel(model))

        try Data(repeating: 0x22, count: payload.count).write(to: manager.fileURL(for: model))
        XCTAssertFalse(manager.verifyInstalledModel(model))
    }

    func testHasModelFile_rejectsAFileOfTheWrongSize() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 10).write(to: manager.fileURL(for: model))

        XCTAssertFalse(manager.hasModelFile(model))
        XCTAssertNil(manager.verifiedPath(for: model))
    }

    // MARK: - Removal

    func testRemove_isIdempotentAndTakesTheStampWithIt() throws {
        let source = try writeSourceFile(payload)
        try manager.install(fileAt: source, model: model)

        try manager.remove(model)
        XCTAssertNil(manager.verifiedPath(for: model))

        // Twice, and with the file already gone: both are fine.
        XCTAssertNoThrow(try manager.remove(model))
        XCTAssertNil(manager.verifiedPath(for: model))
    }

    func testInit_dropsAPartialDownloadFromAKilledApp() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(model.fileName + ".part")
        try payload.write(to: partial)

        _ = TransformModelManager(directory: directory, catalogue: [model])

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: - Model ids

    func testModelLooksUpACatalogueEntryByID() {
        XCTAssertEqual(manager.model(forID: "test-model")?.id, "test-model")
        XCTAssertNil(manager.model(forID: "nope"), "an id this build does not ship is not a model")
    }

    /// The catalogue holds two entries, in the order the Settings card lists
    /// them: the normalizer first, the instruction model second. The job decides
    /// which one runs — English clean-up alone takes the normalizer, tone and the
    /// e-mail mode take the instruction model — so the two styles are what each
    /// entry *is*, not a preference. Both models an earlier build offered are gone
    /// from the product rather than left unrouted: the 8B no job resolved to, and
    /// the 1.5B instruction follower that used to stand behind S1-mini.
    func testTheCatalogueHoldsBothBackendsInOrder() throws {
        let normalizer = TransformModelManager.shared.normalizerModel
        let tone = TransformModelManager.shared.toneModel

        XCTAssertEqual(normalizer.id, TransformModelManager.normalizerModelID)
        XCTAssertEqual(tone.id, TransformModelManager.toneModelID)
        XCTAssertEqual(
            TransformModelManager.availableModels.map(\.id),
            [TransformModelManager.normalizerModelID, TransformModelManager.toneModelID],
            "two rows in the card's order: the normalizer, then the tone and e-mail backend"
        )
        XCTAssertFalse(TransformModelManager.availableModels.contains { $0.id == "qwen3-8b-q4_k_m" },
                       "the 8B no job resolved to is gone from the product, not merely unrouted")
        XCTAssertFalse(
            TransformModelManager.availableModels.contains { $0.id == "qwen2.5-1.5b-instruct-q4_k_m" },
            "the floor S1-mini used to fall back to is gone too: nothing is substituted quietly, so a "
                + "machine without a file is told which file to get"
        )

        // The style is what each entry is: one normalizer that cannot be
        // instructed and reads English only, one instruction follower that reads
        // both languages.
        XCTAssertEqual(normalizer.style, .normalizer)
        XCTAssertEqual(tone.style, .instruction)
    }

    /// The English backend is pinned by the brief: the URL, the size and the
    /// digest the download is verified against, with no second source of truth.
    /// The digest is the repository's own published one, and the file this
    /// machine downloaded hashes to it.
    func testTheEnglishBackendIsPinned() throws {
        let normalizer = TransformModelManager.shared.normalizerModel

        XCTAssertEqual(
            normalizer.downloadURL.absoluteString,
            "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/main/s1-mini-q4_k_m.gguf"
        )
        XCTAssertEqual(normalizer.sha256,
                       "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634",
                       "the digest the repository publishes for s1-mini-q4_k_m.gguf")
        XCTAssertEqual(normalizer.sizeBytes, 484_219_808)
        XCTAssertEqual(normalizer.fileName, "s1-mini-q4_k_m.gguf")
    }

    /// The tone and e-mail backend is pinned the same way as the normalizer: the
    /// URL, the size and the digest the download is verified against, with no
    /// second source of truth. It is the one model that rewrites a register in
    /// both languages the app serves, and the 4.68 GB it costs is why the card
    /// states the price before the download.
    func testTheInstructionBackendIsPinned() throws {
        let tone = TransformModelManager.shared.toneModel

        XCTAssertEqual(
            tone.downloadURL.absoluteString,
            "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
        )
        XCTAssertEqual(tone.sha256,
                       "65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423",
                       "the digest the catalogue pins for the 7B instruction model")
        XCTAssertEqual(tone.sizeBytes, 4_683_074_240)
        XCTAssertEqual(tone.fileName, "Qwen2.5-7B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(tone.licence, "Apache-2.0")
        XCTAssertTrue(tone.displayName.contains("Qwen2.5"), tone.displayName)
    }

    /// The licence is Apache-2.0 plus one additional term, and the name it
    /// requires is in the name the app shows: any use "must continue to identify
    /// it by its original name, \"S1-mini\" by \"Superwhisper\", using that exact
    /// capitalization".
    func testTheEnglishBackendKeepsItsNameAndStatesItsLicence() throws {
        let normalizer = TransformModelManager.shared.normalizerModel

        XCTAssertTrue(normalizer.displayName.contains("S1-mini"), normalizer.displayName)
        XCTAssertTrue(normalizer.displayName.contains("Superwhisper"), normalizer.displayName)
        XCTAssertTrue(normalizer.licence.contains("Apache-2.0"), normalizer.licence)
        XCTAssertTrue(normalizer.licence.contains("S1-mini"), normalizer.licence)
        XCTAssertTrue(normalizer.licence.contains("Superwhisper"), normalizer.licence)
        TestFixtures.report("[transform] licence line shown for the English backend: "
                    + "\(normalizer.licence) — from \(normalizer.source)")
    }

    /// The two facts the runtime reads off the style, both straight from the
    /// card: the assistant turn opens with an empty think block — the literal
    /// llama.cpp would take through a template kwarg this build does not have —
    /// and the answer is decoded greedily.
    func testTheNormalizersContractIsTheCardsAndTheInstructModelsIsNot() throws {
        let openThink = "\u{3C}think\u{3E}"
        let closeThink = "\u{3C}/think\u{3E}"

        XCTAssertEqual(TransformPromptStyle.normalizer.assistantPrefix,
                       "\(openThink)\n\n\(closeThink)\n\n",
                       "two newlines inside the empty block, two after it")
        XCTAssertTrue(TransformPromptStyle.normalizer.isGreedy)
        XCTAssertEqual(TransformPromptStyle.instruction.assistantPrefix, "")
        XCTAssertFalse(TransformPromptStyle.instruction.isGreedy)
    }

    // MARK: - The model is a preference

    /// Nothing installed: the routing still answers with the backend each job
    /// belongs to — the job and the language decide, not what is on disk — and it
    /// is the **runtime** that refuses, with `notInstalled` and the file to
    /// download. `isNormalizerInstalled` is what says the English clean-up
    /// backend is absent, not whether a transform can run at all.
    func testNothingInstalledStillResolvesEachJobToItsBackend() throws {
        // The real catalogue, pointed at a directory with nothing in it — so
        // "nothing is installed" is this test's fact and not the machine's.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-preference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TransformModelManager(
            directory: directory,
            catalogue: TransformModelManager.availableModels
        )

        XCTAssertFalse(manager.isNormalizerInstalled)
        XCTAssertEqual(manager.model(for: .cleanUp(language: .english)).id,
                       TransformModelManager.normalizerModelID,
                       "the normalizer is what English clean-up resolves to, installed or not")
        XCTAssertEqual(manager.model(for: .tone(language: .polish, tone: .formal)).id,
                       TransformModelManager.toneModelID,
                       "Polish tone resolves to the instruction model even with nothing installed")
        XCTAssertEqual(manager.model(for: .email(language: .english, tone: .neutral)).id,
                       TransformModelManager.toneModelID,
                       "the e-mail mode resolves to the instruction model too")
        XCTAssertNil(manager.verifiedPath(for: manager.toneModel), "nothing is staged, so nothing verifies")
    }
}
