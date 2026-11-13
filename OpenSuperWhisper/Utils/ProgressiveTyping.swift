import CoreGraphics
import Foundation

/// Types a transcript into the target while it is still being produced.
///
/// What exists to stream from, measured rather than assumed: **nothing yet**.
/// `TranscriptionService.currentSegment` is only ever assigned the empty string,
/// `transcribedText` is assigned the decoded text once after the decode has
/// finished, and the decode itself starts when the utterance ends. So this type
/// is the delivery half of progressive typing — the half that is independent of
/// where the text comes from — and it is written to be driven by committed
/// segments the moment a source produces them.
///
/// # Committed segments only
///
/// The rule is one an independent judgment split on (0.43 for a revision ladder
/// against 0.37 for this, and 0.05 for backspace-and-retype), and it is the
/// smaller of the two: text is typed only when the source has finished with it,
/// and never revised afterwards. Nothing here backspaces, so nothing here can
/// destroy text a user edited in the target, and the typed transcript is always a
/// prefix-extension of what came before. The cost is stated where it belongs: a
/// source that revises a segment after committing it leaves the earlier wording
/// in the target for good. The revision path is a later option, not a missing
/// branch of this one.
///
/// # Interference
///
/// Every delivery goes through `KeyboardSimulator.typeText` with the caller's
/// watch, so the existing rules hold unchanged: a changed frontmost application
/// or a keystroke the user made stops the stream instead of typing into the wrong
/// place. This type adds one rule of its own: once a delivery has been
/// interrupted, it refuses to type anything else, because the text after an
/// interruption belongs to no one.
@MainActor
enum ProgressiveTyping {

    /// What a stream has typed so far and what it has been given.
    struct Stream {
        /// The transcript the target has, assembled from committed segments.
        private(set) var typed = ""
        /// How the last delivery ended, or `nil` while the stream is healthy.
        private(set) var stoppedBy: KeyboardSimulator.DeliveryInterruption?

        /// Whether anything more may be typed.
        var isHealthy: Bool { stoppedBy == nil }

        /// Adds a committed segment and answers what still has to be typed for
        /// the target to hold everything committed so far.
        ///
        /// - Returns: The text to type now — empty when the segment added nothing
        ///   (a duplicate, or a segment already covered), so a source that repeats
        ///   itself never types twice.
        mutating func commit(_ segment: String) -> String {
            guard isHealthy else { return "" }
            guard !segment.isEmpty else { return "" }
            if typed.isEmpty {
                typed = segment
                return segment
            }
            guard segment.hasPrefix(typed) else {
                // Committed text that is not an extension of what is already
                // typed: this type does not revise, so the only safe thing is to
                // keep what the target has and ignore the contradiction. Reported
                // by the caller through its own record, not silently swallowed:
                // `contradicted` is set.
                contradicted = true
                return ""
            }
            let tail = String(segment.dropFirst(typed.count))
            typed = segment
            return tail
        }

        /// True when a committed segment was not an extension of the text already
        /// typed — the case this type's rule cannot express, and the reason a
        /// revision path may be wanted later.
        private(set) var contradicted = false

        /// Records that a delivery was interrupted, after which nothing more is
        /// typed.
        mutating func stop(with interruption: KeyboardSimulator.DeliveryInterruption) {
            stoppedBy = interruption
        }
    }

    /// Types `tail` into the focused application, with the same path and the same
    /// interference rules as a finished transcript.
    ///
    /// - Returns: What the delivery observed, so the caller can record it and
    ///   stop the stream when the delivery stopped itself.
    @discardableResult
    static func type(
        _ tail: String,
        watch: KeyboardSimulator.DeliveryWatch? = nil,
        post: @escaping (CGEvent) -> Void = KeyboardSimulator.livePostSink
    ) -> KeyboardSimulator.InjectionResult {
        guard !tail.isEmpty else {
            return KeyboardSimulator.InjectionResult(trusted: KeyboardSimulator.isTrustedForInjection,
                                                    eventsPosted: 0)
        }
        return KeyboardSimulator.typeText(tail, watch: watch, post: post)
    }

    /// Commits a segment and types whatever it added.
    ///
    /// The stream is mutated in place, so a caller that keeps one `Stream` per
    /// dictation gets the append-only behaviour without re-deriving it.
    @discardableResult
    static func commit(
        _ segment: String,
        into stream: inout Stream,
        watch: KeyboardSimulator.DeliveryWatch? = nil,
        post: @escaping (CGEvent) -> Void = KeyboardSimulator.livePostSink
    ) -> KeyboardSimulator.InjectionResult {
        let tail = stream.commit(segment)
        guard !tail.isEmpty else {
            return KeyboardSimulator.InjectionResult(trusted: KeyboardSimulator.isTrustedForInjection,
                                                    eventsPosted: 0)
        }
        let result = type(tail, watch: watch, post: post)
        if let interruption = result.interruptedBy {
            stream.stop(with: interruption)
        }
        return result
    }
}
