import Combine
import Foundation

/// One dictation, end to end, as the user should be able to see it.
///
/// The pipeline used to be invisible: the engine's language verdict and the
/// transform's decision lived inside the service, and only the pasted text came
/// out. This is what the indicator publishes after every dictation, so the app
/// can show which language was heard, what was actually transcribed (the raw
/// text, which is what history keeps), what the deterministic clean-up removed,
/// and what the transform produced.
struct DictationReport {
    /// The engine-reported language code, e.g. "pl", or `nil` when the engine
    /// had no signal at all.
    let language: String?
    /// The transcript exactly as the engine produced it — the text history saves.
    let raw: String
    /// What the deterministic scrub left (`raw` itself when clean-up is off).
    let cleaned: String
    /// The text that was actually pasted.
    let final: String
    /// The transform decision, or `nil` when nothing was sent to a model.
    let policy: TransformPolicy?
    /// Whether the model answered. `false` with a non-nil policy means the call
    /// failed and the transcript was pasted instead.
    let didRunModel: Bool
    /// Why the guard threw the tone answer away and pasted the transcript
    /// instead, or `nil` when there was nothing to reject. Without it the report
    /// would name the tone policy as if it had been applied — and the notice the
    /// user saw, the only explanation for their own words coming back, would
    /// have no record here. A `var` with a default so the memberwise initializer
    /// keeps it optional: a `let` with a default is dropped from it entirely.
    var guardRejection: TransformGuardRejection? = nil
    let cleanUpEnabled: Bool
    let removedFillers: Int
    let removedRepetitions: Int
    let removedAnnotations: Int
    let date: Date

    var languageLabel: String {
        guard let language, !language.isEmpty else { return "Not detected" }
        return LanguageUtil.languageNames[language] ?? language.uppercased()
    }

    /// Whether the scrub found anything to remove.
    var scrubRemovedAnything: Bool {
        removedFillers + removedRepetitions + removedAnnotations > 0
    }

    /// One line describing the scrub, e.g. "removed 4 fillers, 2 repetitions".
    var scrubSummary: String {
        guard scrubRemovedAnything else {
            return cleanUpEnabled ? "nothing to remove" : "clean-up off"
        }
        var parts: [String] = []
        if removedFillers > 0 { parts.append("\(removedFillers) filler\(removedFillers == 1 ? "" : "s")") }
        if removedRepetitions > 0 { parts.append("\(removedRepetitions) repetition\(removedRepetitions == 1 ? "" : "s")") }
        if removedAnnotations > 0 {
            parts.append("\(removedAnnotations) annotation\(removedAnnotations == 1 ? "" : "s")")
        }
        return "removed " + parts.joined(separator: ", ")
    }

    /// What to call the transform in the UI, including the honest cases: a call
    /// that failed, and a tone answer the guard threw away. A rejected answer is
    /// not a rewrite that happened — the transcript was pasted — so the label
    /// must not read as if the policy had been applied.
    var transformLabel: String {
        guard let policy else { return "No transform" }
        if guardRejection != nil {
            return "\(policy.summary) — answer rejected, transcript kept"
        }
        return didRunModel ? policy.summary : "\(policy.summary) — model call failed, transcript kept"
    }

    /// Why the guard rejected the tone answer, in the words the notice used, or
    /// `nil` when nothing was rejected. This is the user's only explanation for
    /// their own words coming back, so the surface shows it beside the label.
    var guardNotice: String? { guardRejection?.notice }

    /// Whether the pasted text differs from the transcript the engine produced.
    var changedAnything: Bool { final != raw }
}

/// Holds the last dictation for the UI.
///
/// Deliberately in memory only: history keeps the raw transcript, as it always
/// has, and this is the window onto what the pipeline did with it. Publishing
/// happens on the main actor from the dictation path.
@MainActor
final class DictationReportCenter: ObservableObject {
    static let shared = DictationReportCenter()

    @Published private(set) var last: DictationReport?

    func publish(_ report: DictationReport) {
        last = report
    }

    func dismiss() {
        last = nil
    }
}
