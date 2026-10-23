import Foundation

@MainActor
final class RecordingSessionController {
    static let shared = RecordingSessionController()
    private(set) var currentID: UUID?
    private(set) var isCapturing = false
    private var stopAction: (() -> Void)?
    var hasSession: Bool { currentID != nil }

    func begin(stop: @escaping () -> Void) -> UUID? {
        guard currentID == nil else { return nil }
        let id = UUID()
        currentID = id
        isCapturing = true
        stopAction = stop
        postRecordingStateChanged(true)
        return id
    }

    func requestStop() {
        guard isCapturing else { return }
        isCapturing = false
        let action = stopAction
        stopAction = nil
        action?()
    }

    func finish(_ id: UUID?) {
        guard let id, currentID == id else { return }
        currentID = nil
        isCapturing = false
        stopAction = nil
        postRecordingStateChanged(false)
    }

    /// Broadcasts capture state so companion apps (e.g. ECC Focus Queue) can
    /// mirror it without polling. Posted once per session transition, which
    /// covers both the global hotkey indicator and the in-window recording.
    private func postRecordingStateChanged(_ recording: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.haelyra.ecc-focus-queue.osw.recordingStateChanged"),
            object: nil,
            userInfo: ["recording": recording],
            deliverImmediately: true
        )
    }
}
