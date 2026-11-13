import Foundation
import FluidAudio

/// The Parakeet models this app offers, and the one place a stored version
/// string becomes FluidAudio's `AsrModelVersion`.
///
/// The mapping used to be written out at every call site as
/// `version == "v2" ? .v2 : .v3`. That ternary has no case for a third model:
/// the string Redux is stored under ("redux") is not "v2", so it would have
/// resolved to `.v3`, and the app would have downloaded, verified, measured and
/// removed v3's weights while the row, the engine and the size on disk all said
/// Redux. Everything that turns a version string into a model goes through here.
enum ParakeetModelVersion: String, CaseIterable {
    case v2
    case v3
    case redux

    /// The model a stored string names, or `nil` for a string no model here answers to.
    init?(stored: String) {
        self.init(rawValue: stored)
    }

    /// FluidAudio's counterpart, used to download, load and decode.
    var asrVersion: AsrModelVersion {
        switch self {
        case .v2: return .v2
        case .v3: return .v3
        case .redux: return .redux
        }
    }

    /// The name the settings rows and the storage notice show.
    var displayName: String {
        switch self {
        case .v2: return "Parakeet v2"
        case .v3: return "Parakeet v3"
        case .redux: return "Parakeet Redux"
        }
    }

    /// The Hub repository FluidAudio downloads this model's files from.
    var huggingFaceRepo: String {
        switch self {
        case .v2: return "parakeet-tdt-0.6b-v2-coreml"
        case .v3: return "parakeet-tdt-0.6b-v3-coreml"
        case .redux: return "parakeet-redux-coreml"
        }
    }

    /// Redux's encoder is built out of iOS 18 / macOS 15 Core ML operations, so
    /// FluidAudio refuses to load it on anything older — the load fails with
    /// "requires iOS 18 / macOS 15 (its compressed encoder uses iOS 18 Core ML
    /// ops)". The app itself runs on macOS 14, so the row has to say this before
    /// a download starts; every other model here runs on the app's minimum.
    var requiresMacOS15OrNewer: Bool { self == .redux }

    /// Whether this Mac can load the model, measured the same way FluidAudio does.
    var isSupportedOnThisMac: Bool {
        if !requiresMacOS15OrNewer { return true }
        if #available(macOS 15, *) { return true }
        return false
    }
}

/// Why a Parakeet model the user picked cannot run on this Mac.
enum ParakeetModelError: LocalizedError {
    case requiresMacOS15(String)

    var errorDescription: String? {
        switch self {
        case .requiresMacOS15(let name):
            return "\(name) requires macOS 15 or newer — its encoder uses Core ML operations older "
                + "systems do not have. Parakeet v3 runs on this Mac."
        }
    }
}

extension AsrModelVersion {
    /// FluidAudio's version for a stored Parakeet version string.
    ///
    /// A string no model here answers to falls back to v3: that is what the app
    /// stores by default, and what a preference written by a build offering no
    /// other model means.
    init(storedParakeetVersion: String) {
        self = (ParakeetModelVersion(stored: storedParakeetVersion) ?? .v3).asrVersion
    }
}
