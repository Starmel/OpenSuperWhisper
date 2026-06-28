# Security Policy

## Reporting a vulnerability

**Please do not report security issues in public issues, discussions, or pull
requests.** A public report can put users at risk before a fix ships.

Instead, use GitHub's **private vulnerability reporting** for this repository:

1. Go to the [**Security** tab](https://github.com/my-monkeys/OpenSuperWhisper/security).
2. Click **Report a vulnerability**.
3. Describe the issue, the affected version, and steps to reproduce.

We'll acknowledge your report, work with you on a fix, and credit you (if you
want) once a patched release is out.

## What to report

OpenSuperWhisper is a macOS app that records audio, runs transcription
(locally or via a configured remote endpoint), and inserts text into other
apps. Things worth reporting include, for example:

- Ways to exfiltrate audio, transcriptions, or stored API keys.
- Issues in how API keys / credentials are stored or transmitted.
- Code execution, privilege escalation, or injection via crafted input,
  models, update feeds, or remote endpoints.
- Tampering with the Sparkle auto-update path.

## ⚠️ Beware of fake "patched builds"

We distribute OpenSuperWhisper **only** as signed, notarized macOS builds
(`.dmg`) attached to [our GitHub Releases](https://github.com/my-monkeys/OpenSuperWhisper/releases),
and via Homebrew. **Never install an OpenSuperWhisper "patch", "mod", or
"fix" posted in an issue comment or hosted on a random repository** — those are
not from us. A macOS app is never shipped as an `.apk`.

## Supported versions

Security fixes target the **latest release**. Please reproduce on the most
recent version before reporting.
