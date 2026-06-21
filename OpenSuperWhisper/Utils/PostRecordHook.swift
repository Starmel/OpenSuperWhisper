import Foundation

/// Runs a user-configured shell command after a successful transcription, so people can wire
/// their own automations (save JSON, sync to git, trigger a script…). Opt-in.
///
/// The command runs via `/bin/sh -c`, fire-and-forget (never blocks the UI). The transcription
/// data is exposed two ways so any script can consume it:
/// - environment variables: `OSW_TEXT`, `OSW_AUDIO_PATH`, `OSW_TIMESTAMP` (ISO 8601), `OSW_DURATION`
/// - a JSON object on stdin: `{ "text", "audioPath", "timestamp", "duration" }`
enum PostRecordHook {
    static func runIfEnabled(text: String, audioPath: String?, timestamp: Date, duration: Double) {
        let prefs = AppPreferences.shared
        guard prefs.postRecordHookEnabled else { return }
        let command = prefs.postRecordHookCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        let isoTimestamp = ISO8601DateFormatter().string(from: timestamp)
        let durationString = String(format: "%.2f", duration)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        var env = ProcessInfo.processInfo.environment
        env["OSW_TEXT"] = text
        env["OSW_AUDIO_PATH"] = audioPath ?? ""
        env["OSW_TIMESTAMP"] = isoTimestamp
        env["OSW_DURATION"] = durationString
        process.environment = env

        let payload: [String: Any] = [
            "text": text,
            "audioPath": audioPath ?? "",
            "timestamp": isoTimestamp,
            "duration": duration,
        ]
        let stdin = Pipe()
        process.standardInput = stdin

        do {
            try process.run()
            if let json = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
                stdin.fileHandleForWriting.write(json)
            }
            try? stdin.fileHandleForWriting.close()
        } catch {
            print("Post-record hook failed to launch: \(error)")
        }
    }
}
