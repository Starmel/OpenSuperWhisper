import CryptoKit
import Foundation
import XCTest
@testable import OpenSuperWhisper

/// The transform, driven against real weights.
///
/// Skipped when this machine does not have the file, exactly like
/// `LlamaRuntimeIntegrationTests`: CI stays hermetic, and a machine that has it
/// proves the product's promise — **English clean-up alone runs on S1-mini
/// through the app's own normalizer prompt, while a Polish clean-up alone is the
/// deterministic scrub and reaches no model** — and what the normalizer costs in
/// wired memory and warm-up latency.
///
/// Only the normalizer's weights are staged here. Tone and the e-mail mode run on
/// the instruction model, whose routing is asserted without weights in
/// `TransformBackendTests`; this suite exercises the normalizer's own path. And
/// nothing is substituted behind a missing model: a switched-on dictation whose
/// weights are absent is delivered as it was transcribed and the failure names
/// the file to download.
///
/// The weights are hard-linked into a staging directory, so nothing here copies
/// the file and nothing here can write to the one in `~/models`.
final class SameLanguageTransformIntegrationTests: XCTestCase {

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var normalizerWeights: URL { home.appendingPathComponent("models/s1-mini-q4_k_m.gguf") }

    private var directory: URL!
    private var manager: TransformModelManager!
    private var runtime: TransformRuntime!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Same volume as `~/models`, which is what makes the hard link below
        // possible. Under the user's caches, so a run leaves nothing behind.
        directory = Self.home
            .appendingPathComponent("Library/Caches/OpenSuperWhisperTests-transform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = TransformModelManager(directory: directory, catalogue: TransformModelManager.availableModels)
        runtime = TransformRuntime(models: manager)
    }

    override func tearDownWithError() throws {
        runtime.unload()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Stages real weights under the name the catalogue expects. A hard link:
    /// no copy of the file, and removing the staged name later cannot touch the
    /// file it points at.
    private func stage(_ model: TransformModel, from source: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no weights at \(source.path)")
        }
        let destination = manager.fileURL(for: model)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.linkItem(at: source, to: destination)
    }

    private func stagedNormalizerWeights() throws -> URL {
        try stage(manager.normalizerModel, from: Self.normalizerWeights)
        return Self.normalizerWeights
    }

    /// A `TransformService` whose built-in runtime is this test's runtime — the
    /// production wiring, pointing at staged weights instead of the user's
    /// Application Support. `calls` records every model call the service makes.
    private final class CallCounter {
        var models: [String] = []
        var calls: Int { models.count }
    }

    /// Catches what the service tells the user when a transform cannot run, so
    /// the missing-file case can be judged by its own words instead of a print.
    private final class NoticeRecorder {
        var notices: [TransformFailureNotice] = []
    }

    private func service(
        settings: GateSettings,
        calls: CallCounter,
        failure: @escaping (TransformFailureNotice) -> Void = { _ in }
    ) -> TransformService {
        TransformService(
            localTransform: { systemPrompt, userText, model in
                calls.models.append(model.id)
                return try await self.runtime.transform(
                    systemPrompt: systemPrompt,
                    userText: userText,
                    model: model
                )
            },
            modelForPolicy: { self.manager.model(for: $0) },
            gateSettings: { settings },
            reportFailure: failure
        )
    }

    /// The system's wired page count. The instrument `fm-20260923-24` validated
    /// for a Metal-backed model: its weights, KV cache and compute buffer are
    /// wired, and neither RSS nor `footprint` reports them. System-wide, so the
    /// numbers below are read as a *step* across a load or an unload, never as
    /// an absolute.
    private func wiredBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(stats.wire_count) * UInt64(vm_kernel_page_size)
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }

    private func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.2f s", interval)
    }

    private func report(_ label: String, wiredSince baseline: UInt64) {
        let now = wiredBytes()
        TestFixtures.report("[same-language] wired \(label): \(gigabytes(now)) "
                    + "(step \(gigabytes(now &- min(now, baseline))), baseline \(gigabytes(baseline)))")
    }

    // MARK: - The contract, end to end, against real weights

    /// **English clean-up alone, through the app's own prompt**: the normalizer's
    /// control line, run on the real weights by the real runtime, with the answer
    /// judged by the app's own detector.
    ///
    /// The dictation is the kind the model was built for — fillers, a repeated
    /// word, and a self-correction the speaker resolved — and the assertions are
    /// the properties the card promises: the answer is English, it carries what
    /// was said, and the fillers are gone. The raw input and output are reported
    /// so a drift in quality is visible instead of hidden behind a green run.
    func testEnglishRunsOnTheNormalizerThroughTheRealWeights() async throws {
        _ = try stagedNormalizerWeights()

        let input = "so um i need to like send the the report by uh friday no wait make that thursday"
        let calls = CallCounter()
        // Clean-up alone resolves the normalizer; a tone would resolve the
        // instruction model, which this test does not stage.
        let subject = service(
            settings: GateSettings(tone: false, cleanUp: true, toneMode: .neutral),
            calls: calls
        )

        let started = Date()
        let outcome = await subject.transformDetailed(input, sourceLanguage: "en")
        TestFixtures.report("[s1-mini] model \(calls.models.joined(separator: ", ")) "
                    + "| policy \(outcome.policy?.summary ?? "none") | didRunModel \(outcome.didRunModel) "
                    + "| \(seconds(Date().timeIntervalSince(started)))")
        TestFixtures.report("[s1-mini] input:  \(input)")
        TestFixtures.report("[s1-mini] output: \(outcome.text)")

        XCTAssertEqual(calls.models, [TransformModelManager.normalizerModelID],
                       "English clean-up alone runs on the normalizer once it is installed")
        XCTAssertTrue(outcome.didRunModel)
        XCTAssertEqual(outcome.policy, .cleanUp(language: .english))
        XCTAssertFalse(outcome.text.isEmpty, "the model produced nothing")
        XCTAssertNil(outcome.guardRejection, "a legitimate normalizer answer must survive the guard")
        XCTAssertFalse(outcome.text.contains("<|im_start|>"),
                       "the chat template must not leak into the answer: \(outcome.text)")
        XCTAssertFalse(outcome.text.lowercased().contains("think"),
                       "the empty think block belongs to the prompt, not the answer: \(outcome.text)")
        XCTAssertEqual(LanguageDetector.detect(outcome.text), .english,
                       "English in must be English out: \(outcome.text)")
        XCTAssertNotNil(outcome.text.range(of: "thursday", options: .caseInsensitive),
                        "the self-correction must resolve to what the speaker landed on: \(outcome.text)")
        XCTAssertFalse(outcome.text.lowercased().contains("the the"),
                       "the repeated word is the model's job: \(outcome.text)")
    }

    /// **Polish clean-up alone is delivered as it was transcribed.** Clean-up
    /// alone in Polish is the deterministic scrub — there is no model call to
    /// make — so nothing is asked of a model and no weights are loaded.
    func testPolishCleanUpAloneIsDeliveredAsTranscribedWithNoModelCall() async throws {
        _ = try stagedNormalizerWeights()

        let input = "no hej, sluchaj, musimy przelozyc to spotkanie z klientem na przyszly tydzien, ok?"
        let calls = CallCounter()
        let subject = service(settings: GateSettings(tone: false, cleanUp: true, toneMode: .neutral), calls: calls)

        let outcome = await subject.transformDetailed(input, sourceLanguage: "pl")

        XCTAssertEqual(outcome.text, input, "the transcript is delivered unchanged")
        XCTAssertNil(outcome.policy, "Polish clean-up alone resolves no policy: it is the scrub, not a model call")
        XCTAssertFalse(outcome.didRunModel)
        XCTAssertEqual(calls.calls, 0, "no model may be asked for Polish clean-up")
        XCTAssertNil(runtime.loadedModelID, "and no weights may be loaded for it")
        TestFixtures.report("[transform] Polish clean-up alone: policy none, calls \(calls.calls), "
                    + "text unchanged \(outcome.text == input)")
    }

    /// **Polish tone now resolves to the instruction model.** With the tone switch
    /// on it is the policy that runs, in Polish; the weights are not staged here,
    /// so the attempt fails and the transcript is delivered — but a model *is*
    /// asked, which is the routing the two-model catalogue exists for.
    func testPolishToneResolvesToTheInstructionModelAndIsAttempted() async throws {
        let input = "no hej, sluchaj, musimy przelozyc to spotkanie z klientem na przyszly tydzien, ok?"
        let calls = CallCounter()
        let notices = NoticeRecorder()
        let subject = service(
            settings: GateSettings(tone: true, cleanUp: false, toneMode: .formal),
            calls: calls,
            failure: { notices.notices.append($0) }
        )

        let outcome = await subject.transformDetailed(input, sourceLanguage: "pl")

        XCTAssertEqual(calls.models, [TransformModelManager.toneModelID],
                       "Polish tone runs on the instruction model")
        XCTAssertEqual(outcome.policy, .tone(language: .polish, tone: .formal))
        XCTAssertFalse(outcome.didRunModel, "the weights are not staged, so nothing answered")
        XCTAssertEqual(outcome.text, input, "the transcript is delivered when the model is missing")
        XCTAssertEqual(notices.notices.count, 1, "the missing weights are visible")
        TestFixtures.report("[transform] Polish tone: attempted \(calls.models), policy "
                    + "\(outcome.policy.map(String.init(describing:)) ?? "none"), "
                    + "didRunModel \(outcome.didRunModel)")
    }

    /// The engine reported no language, so the app's own detector places the
    /// text — and Polish it places under clean-up alone is delivered raw just the
    /// same.
    func testPolishTheDetectorPlacesIsAlsoDeliveredRaw() async throws {
        let input = "no więc ja myślę że trzeba wysłać ten raport do klienta jutro rano"
        let calls = CallCounter()
        let subject = service(
            settings: GateSettings(tone: false, cleanUp: true, toneMode: .neutral),
            calls: calls
        )

        let outcome = await subject.transformDetailed(input, sourceLanguage: nil)
        TestFixtures.report("[s1-mini] Polish with no engine language: policy "
                    + "\(outcome.policy.map(String.init(describing:)) ?? "none"), calls \(calls.calls)")

        XCTAssertNil(outcome.policy, "Polish clean-up alone is not transformed either: it is the scrub")
        XCTAssertEqual(outcome.text, input)
        XCTAssertEqual(calls.calls, 0)
    }

    /// With the normalizer not staged, English clean-up still resolves a policy
    /// — the job is the transform's, installed or not — but there is nothing
    /// behind it: the normalizer is attempted, `didRunModel` is false, the raw
    /// transcript is delivered, and the notice names the missing file. Nothing
    /// else steps in.
    func testEnglishCleanUpWithoutTheNormalizerAttemptsItAndNamesTheMissingFile() async throws {
        XCTAssertFalse(manager.isNormalizerInstalled, "precondition: nothing is staged")

        let input = "please send the report to the client today and copy me on the reply"
        let calls = CallCounter()
        let notices = NoticeRecorder()
        let subject = service(
            settings: GateSettings(tone: false, cleanUp: true, toneMode: .neutral),
            calls: calls,
            failure: { notices.notices.append($0) }
        )

        let outcome = await subject.transformDetailed(input, sourceLanguage: "en")
        TestFixtures.report("[s1-mini] English with nothing staged: model "
                    + "\(calls.models.joined(separator: ", ")) | didRunModel \(outcome.didRunModel) "
                    + "| output \(outcome.text)")

        XCTAssertEqual(calls.models, [TransformModelManager.normalizerModelID],
                       "the normalizer is attempted even when it is not installed")
        XCTAssertFalse(outcome.didRunModel, "nothing answered, so nothing may claim to have run")
        XCTAssertEqual(outcome.policy, .cleanUp(language: .english),
                       "English clean-up still resolves its policy; only the file is missing")
        XCTAssertEqual(outcome.text, input, "the raw transcript is delivered")

        let notice = try XCTUnwrap(notices.notices.first, "the failure has to be visible")
        XCTAssertEqual(notice.message,
                       TransformModelError.notInstalled(manager.normalizerModel.displayName).localizedDescription,
                       "the notice is the runtime's notInstalled, word for word")
        XCTAssertTrue(notice.message.contains(manager.normalizerModel.displayName),
                      "and it names S1-mini: \(notice.message)")
    }

    /// Nothing installed: an English tone still resolves its policy, the
    /// instruction model is attempted, the attempt is reported, and the transcript
    /// is still delivered — nothing pretends to have run.
    func testNothingInstalledStillDeliversTheTranscript() async throws {
        let calls = CallCounter()
        let subject = service(
            settings: GateSettings(tone: true, cleanUp: true, toneMode: .formal),
            calls: calls
        )
        let input = "Please send the report to the client today."

        let outcome = await subject.transformDetailed(input, sourceLanguage: "en")

        XCTAssertEqual(outcome.text, input)
        XCTAssertFalse(outcome.didRunModel)
        XCTAssertEqual(calls.models, [TransformModelManager.toneModelID],
                       "a tone resolves the instruction model, which is what is attempted")
        TestFixtures.report("[transform] no weights staged: delivered the raw transcript, "
                    + "didRunModel \(outcome.didRunModel), attempted \(calls.models)")
    }

    /// Both switches off: zero model calls, the transcript bit-for-bit what the
    /// engine produced, and no weights loaded by the attempt — the installed
    /// file is there and still untouched.
    func testBothSwitchesOffMakeNoModelCallAtAll() async throws {
        _ = try stagedNormalizerWeights()

        let calls = CallCounter()
        let subject = service(
            settings: GateSettings(tone: false, cleanUp: false, toneMode: .formal),
            calls: calls
        )
        let input = "Dzień dobry, proszę wysłać raport do klienta."

        let outcome = await subject.transformDetailed(input, sourceLanguage: "pl")
        TestFixtures.report("[same-language] both switches off: model calls \(calls.calls), "
                    + "policy \(outcome.policy.map(String.init(describing:)) ?? "none"), "
                    + "runtime resident \(runtime.loadedModelID ?? "none"), text unchanged \(outcome.text == input)")

        XCTAssertEqual(calls.calls, 0, "no switch on must not touch a model")
        XCTAssertNil(outcome.policy)
        XCTAssertFalse(outcome.didRunModel)
        XCTAssertEqual(outcome.text, input, "the transcript is passed through unchanged")
        XCTAssertNil(runtime.loadedModelID, "nothing may be loaded for a dictation that asked for nothing")
    }

    /// The card names both models and the jobs each serves, so it can no longer be
    /// read as one model doing everything. It is asserted on the card's semantics
    /// — the catalogue's two rows, the routing, and the presence line naming the
    /// tone model — not on whole sentences.
    @MainActor
    func testTheCardNamesBothModelsAndTheirJobs() async throws {
        let card = SettingsViewModel(transformModelManager: manager)
        card.refreshTransformModelState()
        try await waitForInstalledCount(of: card, toBe: 0)

        XCTAssertEqual(card.transformModels.map(\.id),
                       [TransformModelManager.normalizerModelID, TransformModelManager.toneModelID])
        XCTAssertEqual(card.transformModel.id, manager.normalizerModel.id)
        XCTAssertEqual(card.toneTransformModel.id, manager.toneModel.id)

        let without = card.transformLanguageModelDescription
        TestFixtures.report("[transform] card without the weights: \(without)")
        XCTAssertTrue(without.contains(manager.toneModel.displayName), without)
        XCTAssertTrue(without.contains("Polish"), without)
        XCTAssertTrue(without.contains("installed"), without)

        // Each row is for its own job: the normalizer for clean-up, the
        // instruction model for tone and e-mail.
        let normalizerRole = card.transformModelRoleDescription(card.transformModel)
        XCTAssertTrue(normalizerRole.lowercased().contains("clean-up"), normalizerRole)
        let toneRole = card.transformModelRoleDescription(card.toneTransformModel)
        XCTAssertTrue(toneRole.lowercased().contains("tone"), toneRole)
        XCTAssertTrue(toneRole.lowercased().contains("e-mail"), toneRole)

        _ = try stagedNormalizerWeights()
        card.refreshTransformModelState()
        try await waitForInstalledCount(of: card, toBe: 1)

        let with = card.transformLanguageModelDescription
        TestFixtures.report("[transform] card with the normalizer installed: \(with)")
        XCTAssertTrue(with.contains(manager.toneModel.displayName), with)
    }

    // MARK: - The normalizer: what a load costs, and when it is released

    /// The wired-memory step of the normalizer in this process, and that it is
    /// resident for exactly as long as it is needed: the load leaves it
    /// resident, and `unload()` leaves nothing behind. The step is what the
    /// catalogue pins as `memoryBytes`.
    ///
    /// There is a second model in the catalogue, but this suite stages only the
    /// normalizer, so the contract it proves is the one every backend has:
    /// loaded, resident, released.
    func testTheModelLoadsResidentAndUnloadReleasesItWithItsWiredStepMeasured() async throws {
        _ = try stagedNormalizerWeights()
        let normalizer = manager.normalizerModel

        let baseline = wiredBytes()
        _ = try await runtime.transform(
            systemPrompt: TransformService.normalizerSystemPrompt,
            userText: TransformService.normalizerUserPrompt(for: "please send the report", tone: nil),
            model: normalizer
        )
        XCTAssertEqual(runtime.loadedModelID, normalizer.id)
        report("with the model resident", wiredSince: baseline)
        let resident = wiredBytes()

        runtime.unload()
        XCTAssertNil(runtime.loadedModelID, "unload leaves nothing resident")
        report("after unload", wiredSince: baseline)
        TestFixtures.report("[s1-mini] wired: baseline \(gigabytes(baseline)), model "
                    + "\(gigabytes(resident)), step "
                    + "\(gigabytes(resident &- min(resident, baseline))) "
                    + "against a pinned \(normalizer.memoryBytes) bytes")
    }

    /// The warm-up carries the cold load, and a dictation that arrives while the
    /// warm-up is still running waits for it instead of loading a second copy.
    func testWarmUpCarriesTheColdLoadAndTheFirstUtterance() async throws {
        _ = try stagedNormalizerWeights()
        let normalizer = manager.normalizerModel
        // Verify first, so the one-off hash of the weights is not measured as
        // load time. (That hash does leave the file in the page cache, so this is
        // the warm-cache load: the app's second use of the weights. The cold
        // figure, with the cache evicted, is measured outside this suite — see
        // the task report for both numbers.)
        XCTAssertNotNil(manager.verifiedPath(for: normalizer))

        let prompt = TransformService.systemPrompt(for: .cleanUp(language: .english), cleanUp: true)
        let input = "Please send the report to the client today."
        // Greedy decoding, so the race below compares outputs rather than draws.
        let baseline = wiredBytes()

        let warmStart = Date()
        runtime.warmUp(for: normalizer)
        try await waitUntilLoaded(timeout: 180)
        TestFixtures.report("[same-language] warm-up (load + throwaway decode): "
                    + "\(seconds(Date().timeIntervalSince(warmStart)))")
        report("after the warm-up", wiredSince: baseline)

        let firstStart = Date()
        let first = try await runtime.transform(systemPrompt: prompt, userText: input, model: normalizer)
        TestFixtures.report("[same-language] first utterance after a finished warm-up: "
                    + "\(seconds(Date().timeIntervalSince(firstStart)))")
        XCTAssertFalse(first.isEmpty)

        // And the race: the warm-up still running when the dictation needs the
        // model. The runtime's serial queue makes the transform wait for the
        // load — the utterance is slower, never wrong, and never doubled.
        runtime.unload()
        let raceStart = Date()
        runtime.warmUp(for: normalizer)
        let raced = try await runtime.transform(systemPrompt: prompt, userText: input, model: normalizer)
        TestFixtures.report("[same-language] first utterance overlapping the warm-up: "
                    + "\(seconds(Date().timeIntervalSince(raceStart)))")
        XCTAssertEqual(raced, first, "a dictation that races the warm-up must still come back identical to the warmed one")
    }

    private func waitUntilLoaded(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !runtime.isLoaded {
            if Date() > deadline { throw XCTSkip("the warm-up did not finish in \(timeout)s") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - The digest

    /// The download's verification step, against a real weight file: a mutated
    /// copy is refused and leaves nothing installed, and the file on disk still
    /// hashes to the pin.
    func testAMutatedCopyIsRefusedAndThePinnedFileStillVerifies() throws {
        let normalizer = manager.normalizerModel
        let source = Self.normalizerWeights
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no weights at \(source.path)")
        }

        // A clone: shares its blocks with the original, so this costs no disk
        // and the byte below cannot reach the pinned file.
        let clone = directory.appendingPathComponent("mutated-s1-mini.gguf")
        try? FileManager.default.removeItem(at: clone)
        XCTAssertEqual(clonefile(source.path, clone.path, 0), 0, "clonefile failed for \(source.path)")

        let handle = try FileHandle(forUpdating: clone)
        defer { try? handle.close() }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: clone.path)[.size] as? NSNumber)
        try handle.seek(toOffset: size.uint64Value / 2)
        try handle.write(contentsOf: Data([0xFF]))

        XCTAssertThrowsError(try manager.install(fileAt: clone, model: normalizer)) { error in
            guard case TransformModelError.checksumMismatch = error else {
                return XCTFail("a mutated copy must be refused by the checksum, got \(error)")
            }
            TestFixtures.report("[same-language] mutated copy refused: \(error.localizedDescription)")
        }
        XCTAssertFalse(manager.hasModelFile(normalizer), "a refused file must not be installed")
        XCTAssertNil(manager.verifiedPath(for: normalizer))
        XCTAssertFalse(manager.isNormalizerInstalled, "a refused file is not 'the English backend is installed'")

        // …while the file the app would have downloaded still matches the pin.
        XCTAssertEqual(try TransformModelManager.sha256(ofFileAt: source), normalizer.sha256)
        TestFixtures.report("[same-language] on-disk \(source.lastPathComponent) re-verifies "
                    + "against \(normalizer.sha256)")
    }

    /// The file the machine already has is the file the catalogue pins, so the
    /// app's own verification accepts it without a re-download.
    func testTheInstalledEnglishBackendVerifiesAgainstThePin() throws {
        let normalizer = manager.normalizerModel
        _ = try stagedNormalizerWeights()

        XCTAssertTrue(manager.hasModelFile(normalizer), "the staged size must match the pinned size")
        XCTAssertNotNil(manager.verifiedPath(for: normalizer))
        XCTAssertTrue(manager.verifyInstalledModel(normalizer))
        XCTAssertTrue(manager.isNormalizerInstalled)
        TestFixtures.report("[same-language] \(Self.normalizerWeights.path) verifies: "
                    + "\(normalizer.sizeBytes) bytes, \(normalizer.sha256)")
    }

    // MARK: - The idle-unload contract

    /// The fleet's 10-minute contract: the timer is armed by a transform and by a
    /// warm-up, and after a whole interval with no request it releases the
    /// weights and forgets which model they were.
    ///
    /// The interval is injected so this run does not have to sit here for ten
    /// minutes — the shipped one is asserted, and the real ten-minute wait was
    /// measured once against the default (task `fm-20260923-28`, its report).
    func testTheIdleUnloadReleasesTheWeightsAndForgetsTheModel() async throws {
        XCTAssertEqual(TransformRuntime.idleUnloadInterval, 600, "the shipped idle window is ten minutes")
        let normalizer = manager.normalizerModel
        _ = try stagedNormalizerWeights()

        let shortLived = TransformRuntime(models: manager, idleUnloadInterval: 1)
        let start = Date()
        _ = try await shortLived.transform(
            systemPrompt: TransformService.normalizerSystemPrompt,
            userText: TransformService.normalizerUserPrompt(for: "Please send the report to the client today.", tone: nil),
            model: normalizer
        )
        XCTAssertEqual(shortLived.loadedModelID, normalizer.id)

        let deadline = Date().addingTimeInterval(60)
        while shortLived.isLoaded, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        TestFixtures.report("[same-language] idle unload with the interval injected as 1 s: released "
                    + "\(!shortLived.isLoaded) after \(seconds(Date().timeIntervalSince(start)))")
        XCTAssertFalse(shortLived.isLoaded, "the idle timer must release the weights")
        XCTAssertNil(shortLived.loadedModelID, "and clear the resident model with them")
    }

    /// Each model is its own requirement: if one is missing, the card says so for
    /// that row — the normalizer's absence costs English clean-up, the tone
    /// model's costs tone and the e-mail mode — and says nothing once it is
    /// installed. The notice is asserted against a directory that really has
    /// nothing in it, and its silence against one that has the file.
    @MainActor
    func testTheCardWarnsPerModel() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let card = SettingsViewModel(
            transformModelManager: TransformModelManager(directory: empty,
                                                        catalogue: TransformModelManager.availableModels)
        )

        let normalizerNotice = try XCTUnwrap(card.transformMissingNotice(for: card.transformModel),
                                             "the normalizer missing is a real problem and has to be said")
        XCTAssertTrue(normalizerNotice.contains("clean-up"), normalizerNotice)
        let toneNotice = try XCTUnwrap(card.transformMissingNotice(for: card.toneTransformModel),
                                       "the tone model missing costs tone and e-mail, and has to be said")
        XCTAssertTrue(toneNotice.contains("tone") || toneNotice.contains("e-mail"), toneNotice)
        TestFixtures.report("[transform] normalizer missing: \(normalizerNotice)")
        TestFixtures.report("[transform] tone model missing: \(toneNotice)")

        _ = try stagedNormalizerWeights()
        let installed = SettingsViewModel(transformModelManager: manager)
        installed.refreshTransformModelState()
        try await waitForInstalledCount(of: installed, toBe: 1)
        XCTAssertNil(installed.transformMissingNotice(for: installed.transformModel),
                     "an installed normalizer has nothing to warn about")
    }

    /// The card refreshes off the main thread (`refreshTransformModelState`), so
    /// wait for its verdict rather than assuming it has landed. The assertion
    /// after the call is what fails if it never does.
    @MainActor
    private func waitForInstalledCount(of card: SettingsViewModel, toBe count: Int,
                                       timeout: TimeInterval = 300) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while card.installedTransformModelIDs.count != count, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
