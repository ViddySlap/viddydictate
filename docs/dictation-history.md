# Dictation history store

The optional, infinite, append-only log of every delivered dictation. Behind the Settings toggle
**"Keep full dictation history"** (Audio tab, **OFF by default**). Part of ViddyDictate's
external-consumer runtime seam (ADR 0004): ViddyDictate owns the on-disk store; consumers have read-only access.

## Where the data lives

```
~/Library/Application Support/ViddyDictate/history/YYYY-MM-DD.md
```

One Markdown file per **local** day, append-only, **no retention cap** (infinite is the point).

- The `history/` **directory** sits beside — and never collides with — the rolling window's
  `history.json` **file** in the same `ViddyDictate/` folder. They are separate stores.
- The location is **outside Obsidian vaults** on purpose: no Obsidian Sync and no accidental
  workspace indexing. It is app-local plaintext.
- External consumers may read it through the documented file seam. ViddyDictate is the **only
  writer**.

## What gets written

When the toggle is ON, every delivered transcript is appended — **all modes** (raw, cleanup,
prompt-prep, email, search, search-gemini), labeled with its mode + a full local timestamp. The feed
point is the single delivery chokepoint `TranscriptionHistory.record(...)`, so any current or future
mode that records a delivery is captured automatically. Blank deliveries write nothing.

File format (a new day file is seeded with a dated H1; each entry is a timestamp+mode H2 then the
verbatim delivered text). ASCII only - suitable for human reading and downstream embeddings:

```
# Dictation history 2026-07-06

## 2026-07-06 09:05:01  (raw)

first raw transcript

## 2026-07-06 14:23:47  (cleanup)

second, cleaned up
```

## Relationship to the rolling History window

The existing rolling, capped `history.json` recovery window (the "Past Transcriptions…" window,
default 25 entries per tab) is **untouched**. The infinite store is a strictly additive second sink on
the same delivery chokepoint; toggling it changes nothing about the rolling window.

## Design (`DictationHistoryStore`)

- Singleton `DictationHistoryStore.shared` writes to `defaultDirectory()` and gates on the live
  `Settings.keepFullHistory`, so a toggle flip applies to the next dictation without a relaunch.
- Writes are non-blocking (a private serial queue) so delivery is never stalled on file I/O; appends
  use `FileHandle` seek-to-end, seeding a new day file with an atomic first write.
- Both the target `directory` and the `enabled` gate are injectable (mirroring `StickyNotesStore(root:)`),
  so the selftest drives a scratch directory and flips the toggle without touching real prefs or data.

## Verification

`--history-selftest` (headless; no LM Studio, audio, or UI). Runs against a fresh scratch temp
directory per run and never touches the user's real prefs or the real app-local store. It proves the two
locked contracts and the format:

- **toggle OFF = zero writes** — no directory, no file, no filesystem side effects.
- **toggle ON = correct behavior** — per-day file name, dated header, `## <timestamp>  (<mode>)` entry
  heading, mode + timestamp labels, append order preserved, accumulation across entries / days /
  reopened store instances, exactly one header per day file, blank text is a no-op.
- the production default directory resolves outside any Obsidian vault.

Regression: `./build.sh` clean + `--selftest` (unit + clipboard layer + golden bar) green.
