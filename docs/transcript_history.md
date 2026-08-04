# Transcript history

By default OpenSuperWhisper keeps every dictation: the transcript is written to a
local SQLite database and the audio is saved as a `.wav` file, so you can search,
replay and re-transcribe past recordings.

If you dictate confidential material — or you simply don't want a searchable log of
everything you've said — you can turn that off.

## Turning history off

**Settings → Transcription → History Storage → Save transcription history**

The toggle is on by default, so existing installs keep behaving exactly as before.
Turning it off changes nothing about how transcription works: your speech is still
transcribed locally and still lands in the app you were typing in. Only the
record-keeping goes away.

## What happens when it's off

| | History on | History off |
|---|---|---|
| Transcript written to the database | yes | no |
| Audio kept in the recordings folder | yes | no — the temporary file is deleted |
| Hotkey dictation pasted / copied | yes | yes |
| Entry in the history list | yes | no (one exception, below) |

Nothing is written and then deleted: with history off the transcript never reaches
the database in the first place, so it can't linger in the SQLite file.

The setting is read at the moment a dictation finishes, so it takes effect
immediately — no restart needed.

### The record button in the main window

A dictation started with the hotkey (or mouse button) is inserted into whatever app
you were using, so the history entry isn't the only copy of the text. The record
button in OpenSuperWhisper's own window is different: it can't paste into itself, so
its result would otherwise vanish.

With history off, transcripts made with that button therefore stay in the list **for
the current session only**, so you can still read and copy them. They are never
written to disk and are gone the next time the app starts.

### Dictations that land in the queue

If you dictate while the engine is still busy with another transcription, your audio
is queued instead of being transcribed straight away. Queued dictations are not
pasted anywhere — with history on, the result shows up in the list when the queue
gets to it; with history off, it is discarded once transcribed. Wait for the current
transcription to finish if you need to keep the text.

### Audio files you drag in

Files you drag into the window are **not** affected by this setting. Their history
entry is the only place their transcription is ever shown, so suppressing it would
make drag & drop do nothing at all. Delete those entries by hand (or with
auto-delete) when you're done with them.

## Existing history

Turning the setting off stops new dictations from being recorded; it does not delete
what's already there. To clear existing history:

- **Delete all** — the trash button in the bottom bar of the main window.
- **Delete one** — the trash button on an individual entry.
- **Auto-delete** — Settings → Transcription → History Storage lets you drop
  recordings older than 1, 7, 14, 30 or 90 days. Once enabled it runs at launch and
  again every 24 hours while the app is open.

## Where the data lives

Both the database and the audio live under
`~/Library/Application Support/ru.starmel.OpenSuperWhisper/`:

- `recordings.sqlite` — transcripts and metadata
- `recordings/` — the `.wav` files (Settings → Transcription → Transcriptions
  Directory → **Open Folder**)

None of it is ever uploaded anywhere — transcription runs entirely on your Mac.
