import Combine
import CryptoKit
import Foundation

enum TransformModelError: Error, LocalizedError {
    /// Nothing installed for the model the transform resolved to. Carries the
    /// model's name: the catalogue holds one entry today, and the name is still
    /// what says which file to download.
    case notInstalled(String)
    /// The file is there and is not what it says it is: the size or the
    /// checksum the catalogue pins does not match the bytes on disk. It is a
    /// different problem from a file that was never downloaded — one is fixed
    /// by downloading, the other by downloading again — and the user is told
    /// which one he has.
    case notVerified(String)
    case checksumMismatch(expected: String, actual: String)
    case downloadFailed(String)
    case cancellation

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            return "The \(name) transform model is not downloaded yet."
        case .notVerified(let name):
            return "The \(name) transform model is on disk but does not match its pinned checksum, so it was not loaded."
        case .checksumMismatch(let expected, let actual):
            return "The downloaded transform model does not match the pinned checksum (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .downloadFailed(let reason):
            return "The transform model download failed: \(reason)"
        case .cancellation:
            return "The transform model download was cancelled."
        }
    }
}

/// The input contract a backend was trained on.
///
/// The backend is not an instruction follower: S1-mini's card states it "is not a
/// chat model and will not follow general instructions", that it takes one exact
/// system prompt and a control line, and that rewording either makes it
/// "hallucinate or produce garbled output". So its prompt is composed by a
/// different builder (`TransformService.normalizerSystemPrompt` /
/// `normalizerUserPrompt`) and its answers are decoded greedily.
enum TransformPromptStyle: Equatable {
    /// The app's instruction prompt, for an instruct model.
    case instruction
    /// Superwhisper S1-mini: the card's exact system prompt, then a control
    /// line, then the raw transcript, and nothing else.
    case normalizer

    /// The literal the normalizer's assistant turn has to open with.
    ///
    /// The card requires the template be applied with thinking disabled and
    /// gives the literal that means: the assistant turn, then an empty think
    /// block — two newlines inside it, two after it. llama.cpp's server does it
    /// with `--chat-template-kwargs '{"enable_thinking":false}'`, but the C API
    /// this app drives (`llama_chat_apply_template`, `include/llama.h`) takes no
    /// template kwargs at all, and the card warns against the two substitutes a
    /// server offers. So the app writes the block into the prompt string it
    /// sends, byte for byte, and this is that block.
    ///
    /// Built from Unicode scalars, for the same reason
    /// `TransformService.stripReasoning` builds its tags that way: the source
    /// then carries no literal angle brackets that an editor or a patch can
    /// corrupt.
    var assistantPrefix: String {
        switch self {
        case .instruction: return ""
        case .normalizer: return "\u{3C}think\u{3E}\n\n\u{3C}/think\u{3E}\n\n"
        }
    }

    /// Whether this backend's answers are decoded greedily.
    ///
    /// The card: "Decode greedily. `generation_config.json` already ships
    /// `do_sample: false` … If you override the config, use temperature 0." The
    /// GGUF's own metadata (temp 0.6, top_p 0.95, top_k 20, inherited from
    /// Qwen3-0.6B) and the app's established chain (top_k 40, top_p 0.95, min_p
    /// 0.05, temp 0.2) are both wrong for it, so the sampler follows this and
    /// neither of those.
    var isGreedy: Bool { self == .normalizer }
}

/// One downloadable transform model.
struct TransformModel: Equatable, Identifiable {
    /// The id the built-in runtime loads this entry for. It is the file's stem.
    let id: String
    let displayName: String
    let fileName: String
    /// The input contract these weights were trained on. It decides how the
    /// prompt is composed and how the answer is decoded — it is a fact about the
    /// model, not a preference.
    let style: TransformPromptStyle
    let downloadURL: URL
    /// Pinned by the repository, and the only place the digest lives: the
    /// download, the install and every later use are all checked against this
    /// value.
    let sha256: String
    let sizeBytes: Int64
    /// What the model costs in wired memory while it is loaded — weights, KV
    /// cache and compute buffer on the Metal device, measured in-process for
    /// this machine family (`fm-20260923-24`). Shown next to the switch, so the
    /// footprint is visible before it is paid.
    let memoryBytes: Int64
    /// Shown before anything is fetched.
    let licence: String
    let source: String

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var memoryDescription: String {
        ByteCountFormatter.string(fromByteCount: memoryBytes, countStyle: .memory)
    }
}

/// Owns the transform weights: app-owned storage, pinned hash, atomic install.
///
/// Weights are NOT shipped in the app bundle (a 1–5 GB payload in every update
/// is the wrong trade for a menu-bar utility). They live in
/// `~/Library/Application Support/<bundle id>/transform-models/`, exactly like
/// the whisper models next door, so uninstalling the app removes them and
/// reinstalling fetches them again. The catalogue holds the one model the
/// transform knows: S1-mini, the normalizer every English transform runs on.
/// `model(for:)` is what the runtime asks, and what it hands back is the model
/// that will really run — with nothing behind it, a machine without the weights
/// gets a notice naming the file to download instead of a second model quietly
/// doing the work.
final class TransformModelManager {
    static let shared = TransformModelManager()

    /// The English backend: `superwhisper/s1-mini`, a 0.6B text normalizer
    /// trained for exactly this job — it takes a raw ASR transcript and returns
    /// clean written text, fillers and false starts resolved, punctuation and
    /// capitalisation applied, spoken numbers, dates, times, currency and email
    /// addresses written out. Every English transform runs on it, on both
    /// switches — it is the one model the transform has, and a *download*, not a
    /// requirement: without its file the dictation is delivered as transcribed
    /// and the notice names the file to fetch.
    ///
    /// It is not an instruct model and cannot be given the app's prompt: its
    /// card states it "is not a chat model and will not follow general
    /// instructions", and that rewriting the system prompt, dropping the control
    /// line or sending values outside the trained sets makes it "hallucinate or
    /// produce garbled output". Hence `TransformPromptStyle.normalizer`, its own
    /// prompt builder and its own greedy sampler.
    ///
    /// One thing the app used to give the English transform that this one cannot
    /// take: the reference list of names and jargon. The normalizer's input is
    /// the system prompt, a control line and the transcript, in that order, with
    /// nothing else — there is no slot for it, and inventing one is what the
    /// card forbids. The list still rides the instruction prompt, which no model
    /// this build ships takes.
    static let normalizerModelID = "s1-mini-q4_k_m"

    /// The tone and e-mail backend: `Qwen2.5 7B Instruct`, the one model that
    /// rewrites a register in **both** languages this app serves.
    ///
    /// It is here because the smaller candidates were measured and did not
    /// qualify: at 0.5B–3B the models echoed the instruction, copied a worked
    /// example out of the prompt instead of transforming the input, or left the
    /// Polish profanity in place — and the bar is the captain's, that a formal
    /// tone takes "kurwa" out and re-registers the wording, in Polish as well as
    /// English. A Polish-native 4.5B (Bielik v3.0) was measured too: it writes a
    /// good e-mail shape, its English drifts and it framed or looped on tone.
    ///
    /// What it costs is why the card says so before the download: 4.7 GB on disk
    /// and roughly 5.3 GB of memory while a rewrite runs, against S1-mini's
    /// 462 MB. Nothing loads it until a tone switch or the e-mail trigger asks
    /// for it. `memoryBytes` is the engine's own accounting (weights + KV at this
    /// app's 4096-token context + compute buffers), not a wired measurement.
    static let toneModelID = "qwen2.5-7b-instruct-q4_k_m"

    /// The catalogue: the normalizer for English clean-up, the instruction model
    /// for tone and e-mail.
    ///
    /// Two roles, deliberately: S1-mini cannot be instructed and speaks English
    /// only, so it can neither take a register nor read Polish, and the
    /// instruction model is ten times its size for work that is one dictation in
    /// a few. A third entry used to sit here — a 1.5B fallback for a missing
    /// S1-mini — and it is gone: nothing is substituted quietly any more, and a
    /// machine without a file is told which file to download.
    static let availableModels: [TransformModel] = [
        TransformModel(
            id: "s1-mini-q4_k_m",
            displayName: "S1-mini by Superwhisper (Q4_K_M)",
            fileName: "s1-mini-q4_k_m.gguf",
            style: .normalizer,
            downloadURL: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/main/s1-mini-q4_k_m.gguf")!,
            sha256: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634",
            sizeBytes: 484_219_808,
            // The engine's own breakdown for these weights at this app's
            // 4096-token context, every layer on the GPU (llama.cpp's
            // `common_memory_breakdown_print`): 456 MiB weights + 448 MiB KV +
            // 50 MiB compute = 954 MiB. A wired step was not measurable in
            // process on this machine — the suite's instrument reported 0.00 GB
            // across the load — so this is the engine's accounting rather than
            // the wired figure the other two entries carry.
            memoryBytes: 1_000_341_504,
            // Apache-2.0 with one additional term, quoted in the report this
            // entry was added from: any use "must continue to identify it by its
            // original name, \"S1-mini\" by \"Superwhisper\", using that exact
            // capitalization". The display name is where this app does that.
            licence: "Apache-2.0 plus a naming clause: it keeps the name \"S1-mini\" by \"Superwhisper\"",
            source: "superwhisper/s1-mini-GGUF on Hugging Face"
        ),
        TransformModel(
            id: "qwen2.5-7b-instruct-q4_k_m",
            displayName: "Qwen2.5 7B Instruct (Q4_K_M)",
            fileName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
            style: .instruction,
            downloadURL: URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!,
            sha256: "65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423",
            sizeBytes: 4_683_074_240,
            memoryBytes: 5_700_000_000,
            licence: "Apache-2.0",
            source: "bartowski/Qwen2.5-7B-Instruct-GGUF on Hugging Face"
        )
    ]

    /// Where the GGUF files live. Overridable so tests can install into a
    /// temporary directory instead of the user's Application Support.
    let modelsDirectory: URL
    private let catalogue: [TransformModel]
    private let fileManager: FileManager

    private var activeDownloads: [String: URLSessionDownloadTask] = [:]
    private let downloadLock = NSLock()

    init(
        directory: URL? = nil,
        catalogue: [TransformModel] = TransformModelManager.availableModels,
        fileManager: FileManager = .default
    ) {
        self.modelsDirectory = directory ?? Self.defaultDirectory
        self.catalogue = catalogue
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        removeStalePartialDownloads()
    }

    /// `~/Library/Application Support/<bundle id>/transform-models/`
    static var defaultDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "ru.starmel.OpenSuperWhisper"
        return applicationSupport
            .appendingPathComponent(bundleID)
            .appendingPathComponent("transform-models")
    }

    // MARK: - Catalogue

    func model(forID id: String) -> TransformModel? {
        catalogue.first { $0.id == id }
    }

    /// The normalizer: the English clean-up backend.
    var normalizerModel: TransformModel {
        catalogue.first { $0.id == Self.normalizerModelID } ?? catalogue[0]
    }

    /// The instruction model: the tone and e-mail backend, in both languages.
    var toneModel: TransformModel {
        catalogue.first { $0.id == Self.toneModelID } ?? catalogue[0]
    }

    /// Whether the normalizer is installed and its bytes verified. False is a
    /// state the app reports, not one it works around: the weights are a
    /// download, and a transform with none of them fails with the file to fetch.
    var isNormalizerInstalled: Bool {
        verifiedPath(for: normalizerModel) != nil
    }

    /// The backend a *policy* runs on. The job decides first, the language
    /// second — because the two backends are not interchangeable:
    ///
    /// * a **tone**, and the **e-mail** mode (a register change with a shape on
    ///   top), runs on the instruction model, in Polish or English;
    /// * **clean-up alone in English** runs on the normalizer, which was built
    ///   for exactly that job and costs a tenth of the memory;
    /// * a clean-up-alone policy in Polish never exists — `TransformPolicy.resolve`
    ///   refuses it, and the deterministic scrub is what Polish clean-up is.
    func model(for policy: TransformPolicy) -> TransformModel {
        switch policy {
        case .tone, .cleanUpWithTone, .email:
            return toneModel
        case .cleanUp(let language):
            return language == .english ? normalizerModel : toneModel
        }
    }

    func fileURL(for model: TransformModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    // MARK: - Installed state

    /// Cheap check: the file is there and its size matches what is pinned.
    /// Says nothing about the checksum — `verifiedPath(for:)` does that.
    func hasModelFile(_ model: TransformModel) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL(for: model).path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value == model.sizeBytes
    }

    func verifiedPath(for model: TransformModel) -> String? {
        let url = fileURL(for: model)
        guard hasModelFile(model) else { return nil }
        if let stamp = readVerificationStamp(for: model), stamp.sha256 == model.sha256 {
            return url.path
        }
        guard verifyChecksum(ofFileAt: url, model: model) else { return nil }
        writeVerificationStamp(for: model, url: url)
        return url.path
    }

    /// Recomputes the pinned sha256 of the installed file.
    func verifyInstalledModel(_ model: TransformModel) -> Bool {
        let url = fileURL(for: model)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let ok = verifyChecksum(ofFileAt: url, model: model)
        if ok { writeVerificationStamp(for: model, url: url) } else { clearVerificationStamp(for: model) }
        return ok
    }

    private func verifyChecksum(ofFileAt url: URL, model: TransformModel) -> Bool {
        guard let digest = try? Self.sha256(ofFileAt: url) else { return false }
        return digest == model.sha256.lowercased()
    }

    /// Streaming SHA-256 of a file. `CryptoKit` keeps it constant-memory, which
    /// matters for a 5 GB GGUF.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Install

    /// Installs `source` as `model`, atomically and only after the bytes on disk
    /// in the app's own directory hash to the pinned checksum.
    func install(fileAt source: URL, model: TransformModel) throws {
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let destination = fileURL(for: model)
        let partial = modelsDirectory.appendingPathComponent(model.fileName + ".part")
        try? fileManager.removeItem(at: partial)
        try? fileManager.removeItem(at: destination)

        // Copy into the destination directory first, so the hash below is
        // computed over the bytes that actually land, and the final move is a
        // same-volume rename that either happened or did not.
        try fileManager.copyItem(at: source, to: partial)

        let digest: String
        do {
            digest = try Self.sha256(ofFileAt: partial)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw TransformModelError.downloadFailed("\(error)")
        }
        guard digest == model.sha256.lowercased() else {
            try? fileManager.removeItem(at: partial)
            throw TransformModelError.checksumMismatch(expected: model.sha256, actual: digest)
        }

        do {
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw TransformModelError.downloadFailed("\(error)")
        }
        writeVerificationStamp(for: model, url: destination)
    }

    /// Fetches the weights with a URLSession download task (progress, atomic
    /// install, checksum before use) — the same idiom `WhisperModelManager` uses.
    func download(model: TransformModel, progress: @escaping (Double) -> Void) async throws {
        if verifiedPath(for: model) != nil {
            progress(1.0)
            return
        }

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = ModelDownloadDelegate(progressCallback: progress)
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 24 * 60 * 60

            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            let downloadTask = session.downloadTask(with: model.downloadURL)
            delegate.downloadTask = downloadTask

            downloadLock.lock()
            activeDownloads[model.id] = downloadTask
            downloadLock.unlock()

            delegate.completionHandler = { [weak self] location, error in
                session.finishTasksAndInvalidate()

                guard let self else {
                    continuation.resume(throwing: TransformModelError.cancellation)
                    return
                }

                self.downloadLock.lock()
                let isCurrent = self.activeDownloads[model.id] === downloadTask
                if isCurrent { self.activeDownloads.removeValue(forKey: model.id) }
                self.downloadLock.unlock()
                guard isCurrent else {
                    continuation.resume(throwing: TransformModelError.cancellation)
                    return
                }

                if let error = error as? URLError, error.code == .cancelled {
                    continuation.resume(throwing: TransformModelError.cancellation)
                    return
                }
                if let error {
                    continuation.resume(throwing: TransformModelError.downloadFailed(error.localizedDescription))
                    return
                }
                guard let location else {
                    continuation.resume(throwing: TransformModelError.downloadFailed("no file was received"))
                    return
                }

                do {
                    try self.install(fileAt: location, model: model)
                    try? FileManager.default.removeItem(at: location)
                    progress(1.0)
                    continuation.resume()
                } catch {
                    try? FileManager.default.removeItem(at: location)
                    continuation.resume(throwing: error)
                }
            }

            downloadTask.resume()
        }
    }

    func cancelDownload(modelID: String) {
        downloadLock.lock()
        defer { downloadLock.unlock() }
        activeDownloads[modelID]?.cancel()
        activeDownloads.removeValue(forKey: modelID)
    }

    /// Removes the installed weights (and any partial download). Idempotent.
    func remove(_ model: TransformModel) throws {
        cancelDownload(modelID: model.id)
        try? fileManager.removeItem(at: fileURL(for: model))
        try? fileManager.removeItem(at: partialURL(for: model))
        clearVerificationStamp(for: model)
    }

    func removeAll() throws {
        for model in catalogue { try remove(model) }
    }

    // MARK: - Verification stamp
    //
    // Records the checksum that was confirmed for the file currently on disk,
    // keyed by the file's size and modification date, so a launch only hashes
    // once per download instead of once per start.

    private struct VerificationStamp: Codable {
        let sha256: String
        let size: Int64
        let modified: Double
    }

    private func partialURL(for model: TransformModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName + ".part")
    }

    private func stampURL(for model: TransformModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName + ".verified.json")
    }

    private func readVerificationStamp(for model: TransformModel) -> VerificationStamp? {
        let url = fileURL(for: model)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970,
              let data = try? Data(contentsOf: stampURL(for: model)),
              let stamp = try? JSONDecoder().decode(VerificationStamp.self, from: data) else {
            return nil
        }
        // Exact comparison: any change to the file's size or modification time
        // invalidates the stamp and forces a re-hash. APFS keeps sub-second
        // modification times, so a rewrite is always visible here.
        guard stamp.size == size, stamp.modified == modified else { return nil }
        return stamp
    }

    private func writeVerificationStamp(for model: TransformModel, url: URL) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return
        }
        let stamp = VerificationStamp(sha256: model.sha256.lowercased(), size: size, modified: modified)
        guard let data = try? JSONEncoder().encode(stamp) else { return }
        try? data.write(to: stampURL(for: model), options: .atomic)
    }

    private func clearVerificationStamp(for model: TransformModel) {
        try? fileManager.removeItem(at: stampURL(for: model))
    }

    /// A partial download from a killed app is never resumable: drop it.
    private func removeStalePartialDownloads() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.pathExtension == "part" {
            try? fileManager.removeItem(at: entry)
        }
    }
}
