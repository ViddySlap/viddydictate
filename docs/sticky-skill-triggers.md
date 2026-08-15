# The two Sticky Skill triggers, and how to prove they still work

> Audience: project maintainers. This is an internal manual-QA runbook, not setup or user
> documentation.

A sticky skill can be reached two ways, and neither replaces the other. Both must keep working; this
file records what each one actually traverses, why the verification rail cannot prove either of them,
and the exact procedure that does.

## Trigger 1 - the whole-note tab-menu action

Right-click a note's tab, pick a skill from the `STICKY SKILLS` section at the bottom of the menu.

```
web island tab menu (Web/StickyNotes/src)
  -> bridge `noteToHandoff` + `skillId`     NotesBridgeMessages.swift
  -> handleNoteToHandoffBridgeMessage       NotesWindowController.swift:338
  -> runStickySkill(_:payload:)             NotesWindowController.swift:347
  -> StickySkillCoordinator.run(skillID:)   StickySkillCoordinator.swift:284
  -> the skill's own prompt / route / timeout / output handler
```

The catalog is native and only `id` + `displayName` cross the bridge. An island that predates the
dynamic menu, or one that is mid-reload, sends no `skillId` and falls back to the built-in.

## Trigger 2 - the right-Option+period selection hotkey

Select text anywhere, hold right-Option, tap `.`. This does NOT go through the sticky-skill runner at
all. It is a custom-mode chord, and it shares only its backing `CustomMode` row with the built-in skill:

```
CGEventTap                                  HotkeyMonitor.swift:230
  -> customChords match (keycode 47)        HotkeyMonitor.swift:307
  -> DictationController.handleCustom(id:)  DictationController.swift:300
  -> OneShotRegistry.runCustom(_:)          OneShotRegistry.swift:114
  -> copy-capture the selection, transform, paste back in place
```

The snapshot the tap matches against is `CustomModeStore.chordSnapshot()`, which is filtered by
`StickySkillRegistry.hotkeyVisibleModes`. That filter is the one place a Sticky Skills change can
silently unbind this hotkey, so it is where the structural guard lives.

Both triggers resolve through the SAME adopted custom-mode row,
`3A41E54C-1E85-4E4F-8684-9CD1D82949B4`, which owns the ratified route bundle. The adoption invariant is
documented beside the built-in definition in `Sources/App/StickySkill.swift`.

## Why the rail cannot prove either one

`./scripts/verify.sh` covers the seams but not the gestures. Trigger 1 needs a real WKWebView context
menu and a live model; trigger 2 needs a global event tap, Accessibility and Input Monitoring grants, a
foreign app holding a real selection, and a live model. Both are absent from every tier by design, so a
fully green rail is compatible with either trigger being dead.

## The by-hand proof

Run from the repository root. This displaces the LaunchAgent-owned app, because the second instance of
a bundle id exits (`AppDelegate.swift:645`), so the two cannot coexist.

1. Back up `custom-modes.json` and `models-power.json` from
   `~/Library/Application Support/ViddyDictate/`, and record their SHA-256.
2. `launchctl bootout gui/501/com.viddydictate.app`
3. `./build.sh` (real `HOME`, so it signs with the stable identity and the TCC grants survive; the rail's
   deterministic build is ad-hoc signed and would NOT carry them), then `open build/ViddyDictate.app`.
4. Confirm `perms ax=true im=true` and `monitoring started - tap live` in `~/Library/Logs/ViddyDictate.log`.
5. Re-hash the two files. They must be byte-identical: this is the live check that `syncCustomRoutes`
   did not prune the ratified route bundle on launch.
6. Create a SCRATCH note over the loopback control server
   (`POST 127.0.0.1:8766/create_sticky_note`). Never test against a note you did not create.
7. Trigger 1: open Sticky Notes, right-click the scratch tab, click the skill. Expect a toast, then a new
   note titled `<source> - <suffix>` whose first line is the `> **Ran on**:` provenance quote, and the
   source note byte-unchanged.
8. Trigger 2: put a selection in another app, hold right-Option, tap `.`. Expect
   `chord (key 47) -> custom 3A41E54C-...` in the log, then `copy-capture: selection N chars`, then
   `paste-back classification=landed`, then `paste clipboard restored`. The selection is replaced in
   place and the clipboard comes back unchanged.
9. Close only the notes you created, quit, restore `windows.json`, and
   `launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.viddydictate.app.plist`.

A negative result for step 8 that is worth ruling out first: a bare test harness with no main menu has no
Cmd+C key equivalent, so the copy-capture reads an empty selection and the flow no-ops. That is the
harness, not the app; `AppDelegate.setupEditMenu()` exists for the same reason.

## The failure this file exists to prevent

Trigger 2 dies silently. There is no error, no toast, and no log line: the chord simply stops matching,
and because nothing matches it any more the bare `.` is no longer swallowed, so it types a stray
character over the user's selection. Driving a `sticky-skills.json` whose non-built-in row pointed at the
adopted mode id reproduced exactly that. `StickySkillSettingsOperations.add` cannot write such a row, but
a hand-edited or half-written file can, so `hotkeyVisibleModes` now removes the adopted id from the
implementation-only set unconditionally rather than trusting the file to be well formed.
