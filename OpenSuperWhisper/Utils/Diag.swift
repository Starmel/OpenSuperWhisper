import Foundation
import os

/// Lightweight diagnostic tracing for the record-start / hotkey hot path.
///
/// Why `os.Logger` and not `print`/a file: these lines are written to the
/// unified log immediately, so they **survive a force-quit** of a hung app —
/// exactly the situation we need to diagnose. After a freeze, retrieve them with:
///
///     log show --predicate 'subsystem == "fr.my-monkey.opensuperwhisper"' --last 30m --info --debug
///
/// The key trick for a *hang*: every potentially-blocking call is wrapped so it
/// logs `▶ name` before and `◀ name (Nms)` after. If the app freezes mid-call,
/// you'll find the last `▶` with no matching `◀` — that names the culprit, and
/// it's already on disk.
enum Diag {
    static let log = Logger(subsystem: "fr.my-monkey.opensuperwhisper", category: "hotpath")

    /// On by default in DEBUG (the build used day-to-day). In release, enable with:
    ///   defaults write fr.my-monkey.opensuperwhisper diagnosticLogging -bool YES
    static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "diagnosticLogging")
        #endif
    }

    /// A call that takes longer than this is flagged as a stall risk (`.error`).
    private static let slowThresholdMs: Double = 200

    private static let lock = NSLock()
    private static var inFlight: String?

    static func mark(_ message: String) {
        guard isEnabled else { return }
        log.notice("\(message, privacy: .public)")
    }

    /// Runs `body`, logging entry/exit and elapsed time. Do not nest `measure`
    /// calls — the in-flight name (used by the watchdog) tracks a single level.
    @discardableResult
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        setInFlight(name)
        log.notice("▶ \(name, privacy: .public)")
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
            if ms >= slowThresholdMs {
                log.error("⚠️ \(name, privacy: .public) blocked caller for \(ms, format: .fixed(precision: 0))ms")
            } else {
                log.notice("◀ \(name, privacy: .public) (\(ms, format: .fixed(precision: 0))ms)")
            }
            setInFlight(nil)
        }
        return try body()
    }

    private static func setInFlight(_ name: String?) {
        lock.lock(); inFlight = name; lock.unlock()
    }

    /// The name passed to the innermost active `measure`, or nil. Read by the
    /// watchdog to report what the main thread is stuck on.
    static func currentInFlight() -> String? {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }
}

/// Detects a frozen main thread. A main-thread timer stamps a heartbeat; a
/// background timer notices when the heartbeat goes stale and logs a `.fault`
/// (with the in-flight operation name) so a freeze is captured even if the
/// begin/end markers around it never get their matching `◀`.
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    private let stallThresholdNs: UInt64 = 3_000_000_000 // 3s
    private let lock = NSLock()
    private var lastBeatNs = DispatchTime.now().uptimeNanoseconds
    private var reported = false
    private var heartbeatTimer: Timer?
    private var checkTimer: DispatchSourceTimer?

    private init() {}

    func start() {
        guard Diag.isEnabled, checkTimer == nil else { return }

        let beat = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.beat()
        }
        RunLoop.main.add(beat, forMode: .common)
        heartbeatTimer = beat

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "diag.watchdog"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.check() }
        checkTimer = timer
        timer.resume()

        Diag.mark("watchdog started")
    }

    /// Runs on the main thread; if it stops running, the main thread is stuck.
    private func beat() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        lastBeatNs = now
        let recovered = reported
        reported = false
        lock.unlock()
        if recovered {
            Diag.log.notice("✅ main thread responsive again")
        }
    }

    private func check() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let gapNs = now &- lastBeatNs
        let shouldReport = gapNs >= stallThresholdNs && !reported
        if shouldReport { reported = true }
        lock.unlock()

        if shouldReport {
            let op = Diag.currentInFlight() ?? "(unknown)"
            Diag.log.fault("🛑 main thread stalled ≥\(gapNs / 1_000_000_000)s — in-flight: \(op, privacy: .public)")
        }
    }
}
