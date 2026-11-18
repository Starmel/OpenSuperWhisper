import XCTest
@testable import OpenSuperWhisper

/// The app's half of the uninstall contract: the script must be in the bundle,
/// the confirmation sheet may only promise what the script actually removes --
/// and what the sheet says is kept has to be kept.
final class UninstallServiceTests: XCTestCase {

    func testUninstallerScriptShipsInsideTheApp() throws {
        let url = try XCTUnwrap(
            UninstallService.scriptURL,
            "packaging/uninstall.sh must be copied into the app bundle as a resource"
        )
        let script = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(script.contains("ru.starmel.OpenSuperWhisper"))
        XCTAssertTrue(script.contains("--wait-pid"))
    }

    func testEveryPromisedRemovalIsInTheShippedScript() throws {
        let script = try String(contentsOf: try XCTUnwrap(UninstallService.scriptURL), encoding: .utf8)

        for item in UninstallService.removedItems {
            XCTAssertTrue(
                script.contains(item.scriptMarker),
                "the confirmation sheet promises '\(item.title)' (\(item.scriptMarker)) but the uninstaller does not do it"
            )
        }
    }

    /// Kept is a promise too. The sheet tells the user the recordings, the
    /// transcriptions and the settings survive, and the script has to be the
    /// thing that says so.
    func testTheKeptListIsWhatTheScriptKeeps() throws {
        let script = try String(contentsOf: try XCTUnwrap(UninstallService.scriptURL), encoding: .utf8)

        XCTAssertFalse(UninstallService.keptItems.isEmpty, "the sheet has to say what stays")
        XCTAssertTrue(
            script.contains(UninstallService.keptMarker),
            "the sheet says the recordings and settings are kept (\(UninstallService.keptMarker)) but the uninstaller does not keep them"
        )
    }

    /// Every removal in the script goes through a path variable that is built
    /// from the install root. Nothing outside the app's own paths can be named
    /// literally, which is what keeps the uninstaller away from ~/models,
    /// /opt/homebrew and other applications.
    func testEveryRemovalTargetIsARootRelativeVariable() throws {
        let script = try String(contentsOf: try XCTUnwrap(UninstallService.scriptURL), encoding: .utf8)
        let removals = script
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("rm ") || $0.hasPrefix("rm -") }

        XCTAssertFalse(removals.isEmpty, "precondition: the uninstaller removes something")

        for line in removals {
            XCTAssertTrue(
                line.contains("\"$"),
                "the uninstaller removes a hardcoded path instead of a root-relative variable: \(line)"
            )
        }
    }

    func testScriptRefusesUnknownArguments() throws {
        // A scratch root even here: no test may ever point the uninstaller at
        // the real /Applications.
        let result = try runScript(["--not-a-flag"], root: try makeScratchInstall())

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.output.contains("unknown argument"))
    }

    // MARK: - Running the script against a scratch root
    //
    // `OSW_INSTALL_ROOT` prefixes every path, and everything that needs the real
    // machine (quitting the app, cfprefsd, the installer receipt, TCC) runs only
    // for the real root. That makes the whole path list testable without
    // touching anything the user owns -- verified from the shell too, by
    // Scripts/verify-packaging.sh.

    func testUninstallRemovesTheInstallAndIsIdempotent() throws {
        let root = try makeScratchInstall()

        let first = try runScript([], root: root)
        XCTAssertEqual(first.status, 0, first.output)

        for path in removedPaths(in: root) {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: path.path),
                "\(path.lastPathComponent) should have been removed"
            )
        }

        // Second run: nothing left to remove, still exit 0.
        let second = try runScript([], root: root)
        XCTAssertEqual(second.status, 0, second.output)
        XCTAssertTrue(second.output.contains("has been removed"))
    }

    func testUninstallKeepsTheRecordingsAndThePreferences() throws {
        let root = try makeScratchInstall()

        let result = try runScript([], root: root)
        XCTAssertEqual(result.status, 0, result.output)

        for path in keptPaths(in: root) {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path.path),
                "uninstalling the app must not take \(path.path)"
            )
        }
        XCTAssertTrue(
            result.output.contains("Kept:"),
            "the uninstaller has to say what it kept: \(result.output)"
        )
    }

    func testRemoveUserDataRemovesTheRecordingsAndThePreferences() throws {
        let root = try makeScratchInstall()

        let result = try runScript(["--remove-user-data"], root: root)
        XCTAssertEqual(result.status, 0, result.output)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: supportDirectory(in: root).path),
            "--remove-user-data is the one thing that takes the recordings and the settings"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: preferencesPlist(in: root).path),
            "--remove-user-data has to take the settings too"
        )
        // ... and still nothing outside the app's own paths.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedFile(in: root).path),
            "--remove-user-data must still leave another application's data alone"
        )
    }

    func testUninstallWorksWhenTheAppIsAlreadyGone() throws {
        let root = try makeScratchInstall()
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Applications/OpenSuperWhisper.app")
        )

        let result = try runScript([], root: root)

        XCTAssertEqual(result.status, 0, result.output)
        for path in removedPaths(in: root) {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: path.path),
                "\(path.lastPathComponent) should have been removed even with the app gone"
            )
        }
    }

    func testUninstallLeavesUnrelatedFilesAlone() throws {
        let root = try makeScratchInstall()

        _ = try runScript([], root: root)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedFile(in: root).path),
            "the uninstaller must never touch ~/models"
        )
    }

    // MARK: - Helpers

    private struct ScriptRun {
        let status: Int32
        let output: String
    }

    private func uninstallerSource() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("packaging/uninstall.sh")
    }

    /// Runs the uninstaller against a scratch root. There is deliberately no way
    /// to run it against the real one from a test.
    private func runScript(_ arguments: [String], root: URL) throws -> ScriptRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [try uninstallerSource().path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["OSW_INSTALL_ROOT"] = root.path
        environment["HOME"] = "/Users/tester"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ScriptRun(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    // MARK: - The scratch tree
    //
    // Shaped like a real install: what the package's payload places (the app,
    // the uninstall command, the models under /Library) and what the app writes
    // on first use (its own copies of the models, the recordings, the database,
    // the caches and the preferences).

    private func supportDirectory(in root: URL) -> URL {
        root.appendingPathComponent("Users/tester/Library/Application Support/ru.starmel.OpenSuperWhisper")
    }

    private func preferencesDirectory(in root: URL) -> URL {
        root.appendingPathComponent("Users/tester/Library/Preferences")
    }

    private func preferencesPlist(in root: URL) -> URL {
        preferencesDirectory(in: root)
            .appendingPathComponent("ru.starmel.OpenSuperWhisper.plist")
    }

    private func shippedModels(in root: URL) -> URL {
        root.appendingPathComponent("Library/Application Support/ru.starmel.OpenSuperWhisper/Models")
    }

    private func unrelatedFile(in root: URL) -> URL {
        root.appendingPathComponent("Users/tester/models/Qwen3-30B-A3B.gguf")
    }

    /// What the uninstaller has to be gone from the tree after it ran.
    private func removedPaths(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("Applications/OpenSuperWhisper.app"),
            root.appendingPathComponent("Applications/Uninstall OpenSuperWhisper.command"),
            shippedModels(in: root),
            supportDirectory(in: root).appendingPathComponent("whisper-models"),
            supportDirectory(in: root).appendingPathComponent("transform-models"),
            supportDirectory(in: root).appendingPathComponent("qwen3-asr-models"),
            root.appendingPathComponent("Users/tester/Library/Caches/ru.starmel.OpenSuperWhisper")
        ]
    }

    /// What it has to be still there.
    private func keptPaths(in root: URL) -> [URL] {
        [
            supportDirectory(in: root).appendingPathComponent("recordings/dictation.wav"),
            supportDirectory(in: root).appendingPathComponent("recordings.sqlite"),
            preferencesPlist(in: root)
        ]
    }

    private func makeScratchInstall() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-uninstall-\(UUID().uuidString)")
        let support = supportDirectory(in: root)
        let caches = root.appendingPathComponent("Users/tester/Library/Caches/ru.starmel.OpenSuperWhisper")
        let preferences = preferencesDirectory(in: root)
        let app = root.appendingPathComponent("Applications/OpenSuperWhisper.app/Contents/MacOS")
        let shipped = shippedModels(in: root)

        let directories = [
            app,
            root.appendingPathComponent("Applications"),
            support.appendingPathComponent("recordings"),
            support.appendingPathComponent("whisper-models"),
            support.appendingPathComponent("transform-models"),
            support.appendingPathComponent("qwen3-asr-models"),
            caches,
            preferences,
            shipped.appendingPathComponent("whisper-models"),
            shipped.appendingPathComponent("transform-models")
        ]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try Data("app".utf8).write(to: app.appendingPathComponent("OpenSuperWhisper"))
        try Data("uninstaller".utf8).write(
            to: root.appendingPathComponent("Applications/Uninstall OpenSuperWhisper.command")
        )
        // The models the package installed under /Library.
        try Data("shipped-whisper".utf8).write(
            to: shipped.appendingPathComponent("whisper-models/ggml-large-v3-turbo.bin")
        )
        try Data("shipped-transform".utf8).write(
            to: shipped.appendingPathComponent("transform-models/Qwen2.5-7B-Instruct-Q4_K_M.gguf")
        )
        // The models the app downloaded for itself.
        try Data("downloaded".utf8).write(
            to: support.appendingPathComponent("whisper-models/ggml-large-v3-turbo-q5_0.bin")
        )
        try Data("downloaded".utf8).write(
            to: support.appendingPathComponent("transform-models/s1-mini-q4_k_m.gguf")
        )
        try Data("downloaded".utf8).write(
            to: support.appendingPathComponent("qwen3-asr-models/Qwen3-ASR-1.7B-Q8_0.gguf")
        )
        // The user's own data.
        try Data("db".utf8).write(to: support.appendingPathComponent("recordings.sqlite"))
        try Data("wav".utf8).write(to: support.appendingPathComponent("recordings/dictation.wav"))
        try Data("plist".utf8).write(to: preferencesPlist(in: root))
        try Data("cache".utf8).write(to: caches.appendingPathComponent("Cache.db"))

        let unrelated = unrelatedFile(in: root)
        try FileManager.default.createDirectory(
            at: unrelated.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep me".utf8).write(to: unrelated)

        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
