import Foundation
import SwiftUI

enum ToastStyle { case info, success, warning, error }

struct ToastItem: Identifiable {
    let id = UUID()
    let title: String
    let style: ToastStyle
    let actionTitle: String?
    let action: (() -> Void)?
    let source: String
}

@MainActor
class ToastManager: ObservableObject {
    static let shared = ToastManager()
    @Published var current: ToastItem?
    private var lastKey: String?
    private var lastShownAt: Date = .distantPast
    private var queue: [ToastItem] = []

    private func key(for item: ToastItem) -> String { "\(item.style)-\(item.title)-\(item.source)" }

    func closeCurrent() {
        lastKey = nil
        current = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run { [weak self] in self?.dequeueNext() }
        }
    }

    private func dequeueNext() {
        guard current == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        let k = key(for: next)
        let now = Date()
        if k == lastKey && now.timeIntervalSince(lastShownAt) < 5 { return }
        lastKey = k
        lastShownAt = now
        current = next
    }

    func show(_ item: ToastItem, autoDismiss: TimeInterval = 4) {
        let k = key(for: item)
        let now = Date()
        if k == lastKey && now.timeIntervalSince(lastShownAt) < 5 { return }
        if current == nil {
            lastKey = k
            lastShownAt = now
            current = item
        } else {
            queue.append(item)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(autoDismiss * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                if self?.current?.id == item.id { self?.current = nil; self?.dequeueNext() }
            }
        }
    }

    func showError(_ message: String, source: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        show(ToastItem(title: message, style: .error, actionTitle: actionTitle, action: action, source: source))
    }

    func showInfo(_ message: String, source: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        show(ToastItem(title: message, style: .info, actionTitle: actionTitle, action: action, source: source))
    }
}
