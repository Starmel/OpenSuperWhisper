import Foundation

@MainActor
final class AppErrorCenter: ObservableObject {
    struct Issue: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// The fix the app can apply right here, when there is one: the button
        /// the alert shows and what it does. Without it the alert is the plain
        /// OK alert every report has always produced.
        var remedyTitle: String?
        var remedy: (() -> Void)?
    }
    static let shared = AppErrorCenter()
    @Published var issue: Issue?

    func report(_ title: String, error: Error) {
        report(title, message: error.localizedDescription)
    }

    func report(_ title: String, message: String) {
        issue = Issue(title: title, message: message)
    }

    /// Reports a problem the app can also fix, so the fix is offered where the
    /// problem is stated instead of being left to the reader. The remedy only
    /// ever runs because someone pressed its button.
    func report(_ title: String, message: String, remedyTitle: String, remedy: @escaping () -> Void) {
        issue = Issue(title: title, message: message, remedyTitle: remedyTitle, remedy: remedy)
    }
}

struct RecordingStartFailure {
    let sessionID: UUID
    let message: String
}
