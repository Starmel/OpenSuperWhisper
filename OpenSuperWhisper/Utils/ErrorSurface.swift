import Foundation

@MainActor
final class ErrorSurface {
    static let shared = ErrorSurface()
    private init() {}

    func surface(_ error: Error, source: String) {
        let friendly = map(error)
        StatusManager.shared.setError(friendly, source: "error")
        ToastManager.shared.show(ToastItem(title: friendly, style: .error, actionTitle: nil, action: nil, source: source))
    }

    private func map(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: return "No internet connection"
            case NSURLErrorTimedOut: return "Network timeout"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "Cannot reach server"
            case NSURLErrorNetworkConnectionLost: return "Network connection lost"
            default: break
            }
        }
        if ns.code == 401 { return "Authentication required" }
        return ns.localizedDescription
    }
}
