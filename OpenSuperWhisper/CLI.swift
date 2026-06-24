import AppKit
import Foundation

/// Headless command-line transcription (#150). Reached from the app's entry point when the first
/// argument is `transcribe`, so it reuses the exact same engines as the GUI without a second target.
///
///   OpenSuperWhisper transcribe <audio-file> [--json]
///
/// Uses whatever engine/model is configured in the app. Prints the transcription to stdout (plain
/// text, or a JSON object with `--json`) and exits — no dock icon, no menu bar, no windows.
enum CLI {
    static let usage = """
    OpenSuperWhisper — command-line transcription

    Usage:
      OpenSuperWhisper transcribe <audio-file> [--json]
      OpenSuperWhisper bench <dir-of-wavs>

    Options:
      --json       Print a JSON object ({ "file", "text" }) instead of plain text.
      -h, --help   Show this help.

    `bench` loads the configured model once and transcribes every .wav in the directory, printing a
    JSON array of { "file", "ms" (transcription time), "text" } — used to benchmark engines.

    Both use the engine and settings configured in the app. Set up a model in the app first.
    """

    /// Returns true if these arguments are a CLI invocation (and the GUI should not launch).
    static func shouldHandle(_ args: [String]) -> Bool {
        guard args.count >= 2 else { return false }
        return ["transcribe", "bench", "--help", "-h"].contains(args[1])
    }

    static func run(_ args: [String]) -> Never {
        if args.count >= 2, args[1] == "--help" || args[1] == "-h" {
            print(usage); exit(0)
        }
        let mode = args[1]
        guard mode == "transcribe" || mode == "bench", args.count >= 3 else {
            fail(usage, code: 2)
        }
        let json = args.dropFirst(3).contains("--json")
        let target = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: target.path) else {
            fail("error: not found: \(target.path)")
        }

        // The engines + FluidAudio's logger print to stdout. Keep stdout clean & pipeable by
        // redirecting it to stderr, and writing only the final result to the real stdout.
        let realStdout = dup(STDOUT_FILENO)
        resultOut = FileHandle(fileDescriptor: realStdout, closeOnDealloc: false)
        dup2(STDERR_FILENO, STDOUT_FILENO)

        // No dock icon / activation for a CLI run.
        NSApplication.shared.setActivationPolicy(.prohibited)

        Task { @MainActor in
            let service = TranscriptionService.shared
            // Wait for the configured engine to finish loading (model load can take a moment).
            var waited = 0.0
            while service.isLoading && waited < 120 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 0.1
            }
            if let engineError = service.engineError {
                fail("error: \(engineError)\n(set up a model in the app first)")
            }
            if mode == "transcribe" {
                do {
                    let text = try await service.transcribeAudio(url: target, settings: Settings())
                    emit(text, file: target.path, json: json)
                    exit(0)
                } catch {
                    fail("error: \(error.localizedDescription)")
                }
            } else {
                await runBench(dir: target, service: service)
                exit(0)
            }
        }
        // Keep the process alive on the main dispatch queue (where the @MainActor task runs) until
        // the task calls exit(). dispatchMain() never returns, satisfying the -> Never contract.
        dispatchMain()
    }

    /// Transcribe every .wav in `dir` with the already-loaded engine, timing each transcription.
    /// Prints a JSON array of { file, ms, text } — the model is loaded once, so timings reflect
    /// steady-state transcription speed (not per-run model load).
    @MainActor
    private static func runBench(dir: URL, service: TranscriptionService) async {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var results: [[String: Any]] = []
        for file in files {
            let start = CFAbsoluteTimeGetCurrent()
            let text = (try? await service.transcribeAudio(url: file, settings: Settings())) ?? ""
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            results.append([
                "file": file.lastPathComponent, "ms": ms,
                "text": text.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
        let data = (try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])) ?? Data()
        resultOut.write(data)
        resultOut.write(Data("\n".utf8))
    }

    /// The real stdout (engine/library logs are redirected away from it during a run).
    private static var resultOut = FileHandle.standardOutput

    private static func emit(_ text: String, file: String, json: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let out: Data
        if json {
            out = (try? JSONSerialization.data(
                withJSONObject: ["file": file, "text": trimmed],
                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        } else {
            out = Data(trimmed.utf8)
        }
        resultOut.write(out)
        resultOut.write(Data("\n".utf8))
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(code)
    }
}
