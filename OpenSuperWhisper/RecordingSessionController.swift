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
    }
}
