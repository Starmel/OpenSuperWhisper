# OpenAI Whisper Integration Plan

## Goals
- Add a user-selectable transcription backend (local whisper.cpp or OpenAI Whisper API).
- Support OpenAI file-upload transcription first; evaluate streaming as a follow-up.
- Preserve existing on-device functionality and settings.

## Milestones
1. **Backend Toggle (completed)**
   - Add an app preference for transcription backend (`local` vs `openai`).
   - Surface the choice in Settings with clear copy and prerequisites (API key).
   - Adjust transcription flow to read the new preference (no network logic yet).
2. **OpenAI Upload Flow (in progress)**
   - Capture recordings, upload via multipart/form-data, handle responses & errors.
   - Manage API key storage and validation (keychain or user defaults with warnings).
   - Update UI to show remote transcription progress.
3. **Polish & Streaming Investigation**
   - Add telemetry/logging hooks, refine UX, and consider streaming feasibility.

## Open Questions
- Where to store the OpenAI API key securely? (Keychain recommended.)
- How to handle rate limits and retries gracefully?
- Do we need a hybrid mode (local fallback when offline)?

## Notes
- Implement a small Security.framework-backed helper (service: "OpenSuperWhisper") to manage the OpenAI API key.
- Keep code paths loosely coupled so additional providers can plug in later.
- Maintain feature parity in tests/UX for both backends.
