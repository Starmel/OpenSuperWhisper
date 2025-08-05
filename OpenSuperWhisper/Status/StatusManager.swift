import Foundation
import SwiftUI

enum AppStatus {
    case idle
    case recording
    case transcribing
    case error(String)
}

@MainActor
class StatusManager: ObservableObject {
    static let shared = StatusManager()
    @Published var status: AppStatus = .idle
    private(set) var currentSource: String?
    private var priorities: [String:Int] = ["error": 100, "transcription": 50, "default": 10]
    private func p(_ s: String?) -> Int { priorities[s ?? "default"] ?? 0 }

    func setPriority(_ source: String, value: Int) { priorities[source] = value }

    func setIdle(source: String = "default") {
        if p(source) >= p(currentSource) || source == currentSource {
            status = .idle
            currentSource = nil
        }
    }

    func setRecording(source: String = "default") {
        if p(source) >= p(currentSource) {
            status = .recording
            currentSource = source
        }
    }

    func setTranscribing(source: String = "transcription") {
        if p(source) >= p(currentSource) {
            status = .transcribing
            currentSource = source
        }
    }

    func setError(_ message: String, source: String = "error") {
        status = .error(message)
        currentSource = source
    }
}
