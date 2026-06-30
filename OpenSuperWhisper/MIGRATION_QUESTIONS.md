# my-monkeys Migration — Decisions Needed

Answer inline under each **Answer:** line (free-form is fine). Full detail lives in `MIGRATION_MYMONKEYS.md`; this is just the decision checklist.

**TL;DR of the audit:** `my-monkeys/OpenSuperWhisper` is a mature superset of our fork (357 commits ahead of Starmel, v0.9.2) and architecturally near-identical (same `TranscriptionEngine` protocol, `@UserDefault`/`AppPreferences`, `selectedEngine` switch, GRDB stack, SPM deps). Their `GroqEngine` is a hardcoded special-case of our generic `RemoteEngine`. So this is a **port onto a superset**, not a rewrite.

Our features to bring over: **F1** RemoteEngine (temperature/prompt → Engram) · **F2** context-aware model rules · **F3** transcript metadata + history UX · **F4** SourceCapture (app/window/URL) · **F5** recording-indicator tweaks.

---

## Q1 — Fork mechanics

Brand-new fork of `my-monkeys/OpenSuperWhisper`, or re-point your existing `EvanSchalton/OpenSuperWhisper` repo to track my-monkeys?

- **New fork:** cleanest history, easy to upstream PRs back; you'd migrate your local working copy to it.
- {{Re-point existing repo}}((Don't we have a shared history since they forked the same upstream? If not - I'd say let's rename our current repo to *-temp and fork the monkey repo then just port our changes over.))**:** keeps your repo URL/stars/issues, but messier history (their 357 commits grafted on).
- *Note:* {{I have no GitHub credentials on this VM}}((You have GITHUB_PAT in /home/evan/.config/dev-vms/local-env.sh))*, so the fork/re-point itself is a step you'll do; I drive the cherry-picks after.*

**Answer:**

## Q2 — Groq: preset vs replace  *(recommended: keep as preset)*

Keep their Groq engine as a **built-in preset** alongside an "Engram"/"Custom" preset (one generalized RemoteEngine code path, Groq just pre-fills URL + model list + Keychain key), or **fully replace** Groq with our remote engine?

- Keeping it as a preset preserves Groq users and is upstream-friendly. {{Replacing is simpler but drops Groq}}((I'm game to just replace it -- we can update the readme w/ how to configure. OR we can keep what's currently there and build an adapter so it runs on our updated code and recommend deprecation to the maintainers)).

**Answer:**

## Q3 — Engine identity / settings shape

Related to Q2: keep `selectedEngine == "remote"` as a **sibling** of `"groq"`, or **collapse** Groq into `remote` + a preset selector? Collapsing is cleaner long-term but migrates existing Groq users' stored settings ({{needs a small defaults migration}}((If we can easily do the defaults migration I say let's drop Groq (update Q2 answer) so collapse groq into remote))).

**Answer:**

## Q4 — Upstreamable back to my-monkeys?

Should the generalized remote engine be built clean enough to {{PR back to my-monkeys}}((Yes, their maintainers are excited for the change)) ({{Engram-specific bits}}((Aren't all of the engram-specific bits already hidden? I _assume_ returning a model list is fairly standard? What's engram specific?)) hidden behind a "Custom" preset)? If yes, I'll keep Engram assumptions out of the shared path; if no, I can be more direct/Engram-specific.

**Answer:**

## Q5 — Drop our {{indicator changes}}((What are you referring to here? The recording bubble? If so, yes - no problem. Though the click to stop is genuinely a nice feature for when the toggle transcription is selected)) (F5)?

my-monkeys ships a newer Notch-style indicator. Our F5 indicator tweaks are the highest-conflict / lowest-value to port. OK to **drop F5** and adopt theirs?

**Answer:**

## {{Q6 — Engram translate semantics}}((I don't want things to be engram specific -- I modeled engram after the openai spec- it's servered through litellm as an openai model))

For translation, should our engine send OpenAI's separate `/audio/translations` endpoint (how Groq's full model does it), or a `translate=true`-style field to Engram's `/audio/transcriptions`? (i.e., what does the Engram server expect for translate?)

**Answer:**

---

### Anything else / constraints?

**Answer:**