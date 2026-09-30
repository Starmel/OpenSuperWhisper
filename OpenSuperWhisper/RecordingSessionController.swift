import Foundation

@MainActor
final class RecordingSessionController {
    static let shared = RecordingSessionController()
    private(set) var currentID: UUID?
    private(set) var isCapturing = false
    private var stopAction: (() -> Void)?
    private let volumeController: OutputVolumeControlling
    private let shouldMute: () -> Bool
    var hasSession: Bool { currentID != nil }

    init(
        volumeController: OutputVolumeControlling = OutputVolumeController.shared,
        shouldMute: @escaping () -> Bool = { AppPreferences.shared.muteOutputWhileRecording }
    ) {
        self.volumeController = volumeController
        self.shouldMute = shouldMute
    }

    func begin(stop: @escaping () -> Void) -> UUID? {
        guard currentID == nil else { return nil }
        let id = UUID()
        currentID = id
        isCapturing = true
        stopAction = stop
        // Mute before the recorder opens so nothing the Mac plays leaks into the
        // capture. finish() owns the restore, and every terminal path runs it.
        if shouldMute() {
            volumeController.mute()
        }
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
        // A stale finish must not unmute: the current id belongs to a newer
        // session that muted again when it began.
        volumeController.restore()
    }
}
