import SwiftUI

/// Live-tunable notch geometry, shared between the settings sliders and the indicator view so the
/// notch updates in real time while you drag. Values persist in UserDefaults.
final class NotchTuning: ObservableObject {
    static let shared = NotchTuning()

    @Published var width: Double { didSet { save(width, "notchWidth") } }
    @Published var height: Double { didSet { save(height, "notchHeight") } }
    @Published var topRadius: Double { didSet { save(topRadius, "notchTopRadius") } }
    @Published var bottomRadius: Double { didSet { save(bottomRadius, "notchBottomRadius") } }

    private init() {
        let d = UserDefaults.standard
        width = d.object(forKey: "notchWidth") as? Double ?? 220
        height = d.object(forKey: "notchHeight") as? Double ?? 42
        topRadius = d.object(forKey: "notchTopRadius") as? Double ?? 10
        bottomRadius = d.object(forKey: "notchBottomRadius") as? Double ?? 14
    }

    private func save(_ value: Double, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
