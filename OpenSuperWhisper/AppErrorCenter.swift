import Foundation

@MainActor
final class AppErrorCenter: ObservableObject {
    struct Issue: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    static let shared = AppErrorCenter()
    @Published var issue: Issue?

    func report(_ title: String, error: Error) {
        report(title, message: error.localizedDescription)
    }

    func report(_ title: String, message: String) {
        issue = Issue(title: title, message: message)
    }
}

struct RecordingStartFailure {
    let sessionID: UUID
    let message: String
}
