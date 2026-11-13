import Foundation

/// What a dictation's failure owes the user, decided once for every surface
/// that can produce one: the indicator, the main window's record button, the
/// transcription queue, and the recorder's own capture failures.
///
/// The rule the whole app follows — a dictation that yielded no transcript
/// because there was nothing to transcribe is silent, with no alert and no
/// failed history row, while a failure over real audio is reported and keeps
/// that audio. The two silent cases differ in what happens to the audio:
///
/// * the VAD found no speech segment in the recording, or the capture never
///   wrote a frame at all — there is nothing in the audio to keep, so it goes
///   with the row that was never written;
/// * the refusal rests on a no-speech *probability* above the user's own
///   threshold — that is a guess about audio that really was recorded, and the
///   user must not lose their words to it, so the audio is kept.
@MainActor
enum DictationFailurePolicy {

    /// The one decision, taken from the evidence about the dictation's audio.
    ///
    /// A failure is judged by what the audio itself carried, not by which class
    /// of error it surfaced as: an engine or a converter that failed over audio
    /// that was recorded is a genuine failure whatever it threw, and only the
    /// absence of audio — the VAD's verdict, or a capture that produced no
    /// frames — is silence.
    enum Outcome: Equatable {
        /// Nothing to report and nothing worth keeping: the audio goes.
        case discard
        /// Nothing to report, but the audio is kept for the user.
        case keepAudio
        /// The refusal is one the user can act on — the selected model cannot
        /// hear the dictation's language, and a different model could transcribe
        /// it — so the audio is kept and the surface that ran the dictation says
        /// what happened, what to do, and where the recording is. No alert, no
        /// history row. See `KeptRecordingNotice`.
        case keepAudioAndExplain
        /// What the app has always done: alert, failed row, audio kept.
        case report
    }

    nonisolated static func outcome(for error: Error) -> Outcome {
        // A capture that died before its first frame: no audio ever reached the
        // engine, so there is no transcript to fail at and nothing to keep.
        if let capture = error as? RecordingCaptureError, capture.audio.samples.isEmpty {
            return .discard
        }
        // Real speech the selected model cannot hear: a different model could
        // transcribe it, so the audio is kept, and the surface says which
        // recording it is and what to do about the model.
        if case TranscriptionError.speechLanguageConflict = error {
            return .keepAudioAndExplain
        }
        guard case TranscriptionError.noSpeechDetected(let refusal) = error else {
            return .report
        }
        // The VAD's verdict is evidence about the recording itself; a measured
        // probability is not, so audio it refused is kept.
        return refusal.presence == .noSpeechSegment ? .discard : .keepAudio
    }

    /// Applies the outcome to the audio the failure left behind, the same way
    /// whichever surface started the dictation.
    ///
    /// Returns where the audio was kept, when the decision was to keep it and
    /// the caller needs to know (the tests follow exactly that file); `nil` when
    /// nothing was kept.
    @discardableResult
    static func settle(
        _ audio: RecordedAudio,
        error: Error,
        store: RecordingStore
    ) async -> URL? {
        switch outcome(for: error) {
        case .discard:
            try? FileManager.default.removeItem(at: audio.url)
            return nil
        case .keepAudio, .keepAudioAndExplain:
            // Kept the way every failed dictation is kept: the audio moves into
            // the recordings directory and a row records it, so the kept
            // recording is visible in History and ages with the rest. Nothing
            // was transcribed, so the transcript column stays empty and the row
            // is a record rather than a delivery: no alert, nothing pasted.
            do {
                return try await store.saveFailedDictation(audio, error: error).url
            } catch {
                // Not kept, so it must never be called kept: the temp cleanup
                // would take it later, and the user is told where it still is.
                let stillAt = (error as? PreservedAudioError)?.url ?? audio.url
                AppErrorCenter.shared.report(
                    "The recording could not be kept",
                    message: "\(error.localizedDescription)\nThe recording is still here: \(stillAt.path)"
                )
                return nil
            }
        case .report:
            // The capture's own error is what the user is told about; the
            // wrapper only carries the audio out of the recorder.
            let reported = (error as? RecordingCaptureError)?.underlying ?? error
            await store.preserveFailedDictation(audio, error: reported)
            return nil
        }
    }
}
