import Foundation
import AppKit

extension NotesProbe {
    static func probeNoteTargetSnapshot(check: Check) {
        // --- 13. note-target core / snapshot targeting (notes-bullseye BT1) ---------------------------
        // Snapshot the {note id, anchored position} at take-START when a notes window is key and the caret is in
        // a note; deliver to that snapshot BY NOTE ID at completion even if focus moved; the anchor follows
        // edits; a selection targets a range-to-replace, a bare caret an insert point; a gone target parks the
        // take on the clipboard. The live anchor lives in CodeMirror (the real chord/dictation is the review
        // link's GUI job); here the PURE decision + mapping model is locked, plus a bundled-island shipping
        // check that the JS half actually ships.

        // 13a. snapshot capture at take-START: a key window with an active note yields a target; blank home /
        // history view / no key window (nil or empty active id) yields nil, keeping today's key-window delivery.
        check("note target: snapshot captures the key window's active note id at take-start",
              NotesWindowRegistry.dictationTarget(keyWindowActiveNoteId: "note-x") == NotesDictationTarget(noteId: "note-x"))
        check("note target: no snapshot when no note is active (blank home / history) -> today's path",
              NotesWindowRegistry.dictationTarget(keyWindowActiveNoteId: nil) == nil)
        check("note target: no snapshot for an empty active id",
              NotesWindowRegistry.dictationTarget(keyWindowActiveNoteId: "") == nil)

        // 13b. deliver-to-target AFTER focus moves: the note-id path reaches a still-open note in ANY live
        // window, even when it is not the key/active note (focus/selection moved during the take).
        check("note target: deliverable when the note is still open in some window (focus moved off it)",
              NotesWindowRegistry.targetDeliverable(noteId: "note-x", openNoteIds: ["note-x", "note-y"]))
        check("note target: deliverable regardless of which note is currently active",
              NotesWindowRegistry.targetDeliverable(noteId: "note-y", openNoteIds: ["note-x", "note-y"]))

        // 13c. anchor-follows-edits: the pure model of CodeMirror's ChangeSet.mapPos the live editor runs.
        check("note target: anchor shifts DOWN when text is inserted above it",
              NotesTargetLogic.mapPosition(10, changeFrom: 3, changeTo: 3, insertedLen: 4) == 14)
        check("note target: anchor shifts UP when text above it is deleted",
              NotesTargetLogic.mapPosition(10, changeFrom: 2, changeTo: 5, insertedLen: 0) == 7)
        check("note target: anchor unaffected by an edit entirely after it",
              NotesTargetLogic.mapPosition(10, changeFrom: 12, changeTo: 15, insertedLen: 2) == 10)
        check("note target: anchor inside a replaced range collapses to the change's new end",
              NotesTargetLogic.mapPosition(10, changeFrom: 8, changeTo: 14, insertedLen: 1) == 9)
        check("note target: anchor exactly at an insertion point stays before the inserted text",
              NotesTargetLogic.mapPosition(3, changeFrom: 3, changeTo: 3, insertedLen: 4) == 3)

        // 13d. selection-vs-caret target: a bare caret INSERTS at the anchor; a non-empty selection REPLACES the
        // range (normalized regardless of the drag direction).
        check("note target: a bare caret is an insert point",
              NotesTargetLogic.targetEdit(from: 5, to: 5) == .insert(at: 5))
        check("note target: a selection is a range-to-replace",
              NotesTargetLogic.targetEdit(from: 2, to: 7) == .replace(from: 2, to: 7))
        check("note target: a reversed selection normalizes to the same range-to-replace",
              NotesTargetLogic.targetEdit(from: 7, to: 2) == .replace(from: 2, to: 7))

        // 13e. target-gone clipboard fallback: a target whose note is no longer open in any window is not
        // deliverable, and the landing decision parks the take on the clipboard with the pill toast; a delivered
        // or queued outcome lands in the note.
        check("note target: NOT deliverable once the note is closed to history / deleted (gone)",
              !NotesWindowRegistry.targetDeliverable(noteId: "note-gone", openNoteIds: ["note-x"]))
        check("note target: a gone target parks the take on the clipboard with the pill toast",
              NotesTargetLogic.landing(for: .noWindow)
              == .clipboardParked(toast: "note target gone, copied to clipboard")
              && NotesTargetLogic.targetGoneToast == "note target gone, copied to clipboard")
        check("note target: a delivered outcome lands in the note (no clipboard park)",
              NotesTargetLogic.landing(for: .delivered) == .delivered)
        check("note target: a queued outcome (mid-take page reload) is treated as landed, not lost",
              NotesTargetLogic.landing(for: .queued) == .delivered)

        // 13f. the JS half ships. The bundled island is minified (module identifiers are mangled), so we pin the
        // two outbound wire names — string literals that survive — in the BUNDLED app.js, and pin the
        // follow-edits remap (CodeMirror ChangeSet.mapPos) in the SOURCE module, exactly as probeBridgeParity
        // checks both bundled and source. (Wire-name parity with the Swift enum is enforced in probeBridgeParity.)
        let appJS = NotesProbe.bundledAppJS
        check("note target: bundled island ships the snapshotTarget + insertAtTarget outbound handlers",
              appJS.contains("snapshotTarget") && appJS.contains("insertAtTarget"))

        let targetSrc = sourceDictationTargetJS
        check("note target: source module ships the follow-edits remap (CodeMirror ChangeSet.mapPos)",
              !targetSrc.isEmpty
              && targetSrc.contains("mapSnapshotThroughChanges")
              && targetSrc.contains("mapPos"),
              "Web/StickyNotes/src/dictation-target.js")

        // 13g (item-4): one-shot SELECTION-transform landing remembers the note target. A selection captured
        // inside a sticky note (Option+P cleanup-selection, the Option+M email selection arm, custom in-place
        // modes) is snapshotted at capture-START and the transform lands BY NOTE ID through the SAME
        // focus-independent `deliverToTarget` path a dictation take uses — so switching focus to another app
        // during the LLM round-trip no longer pastes the result into that app (THE bug). Capture-time resolution
        // reuses the BT1 `dictationTarget` routing; the pure landing-route decision is pinned against the same
        // helper `landSelectionTransform` branches on. (The live chord/cross-focus replace is the review's GUI job.)
        check("one-shot selection-transform: capture reuses the BT1 note-target routing (notes-key active note captures a target)",
              NotesWindowRegistry.dictationTarget(keyWindowActiveNoteId: "note-x") == NotesDictationTarget(noteId: "note-x")
              && NotesWindowRegistry.dictationTarget(keyWindowActiveNoteId: nil) == nil
              && NotesWindowRegistry.dictationTarget(keyWindowActiveNoteId: "") == nil)
        check("one-shot selection-transform: a snapshotted target routes by ID (deliverToTarget), NOT insertIntoKeyWindow / pasteIntoFocus",
              NotesTargetLogic.selectionTransformRoute(noteTarget: NotesDictationTarget(noteId: "note-x")) == .byNoteTarget)
        check("one-shot selection-transform: nothing snapshotted (foreign-app selection) falls back to today's key-window / paste path",
              NotesTargetLogic.selectionTransformRoute(noteTarget: nil) == .focusFallback)
        check("one-shot selection-transform: a delivered/queued by-ID landing lands in the note; a gone target falls back",
              NotesTargetLogic.landing(for: .delivered) == .delivered
              && NotesTargetLogic.landing(for: .queued) == .delivered
              && NotesTargetLogic.landing(for: .noWindow) != .delivered)

        // 13h (refine2 BUG 2): the snapshot store's write guard. Option+P over a note selection first tinted +
        // COLLAPSED the live selection, then the command chord re-read that collapsed caret and overwrote the
        // good `{from,to}` with a degenerate `{X,X}`, so delivery inserted-at-a-point instead of replacing (no
        // tint either — an empty range tints nothing). The guard: a same-gesture EMPTY (`from == to`) write never
        // clobbers a live non-empty snapshot; an OLDER gesture never wins; a NEWER gesture always wins (a fresh
        // take legitimately re-snapshots, even to a bare caret, so a genuine new bare-caret gesture is never
        // blocked by a stale range). Pure so the probe pins the exact rule dictation-target.js `setSnapshot`
        // enforces; the real-path DOM harness (Web/StickyNotes/scripts/notes-bridge-harness) asserts the JS half.
        typealias SW = NotesTargetLogic.SnapshotWrite
        check("snapshot guard: the first write for a note is accepted",
              NotesTargetLogic.acceptsSnapshotWrite(existing: nil, incoming: SW(from: 5, to: 20, generation: 3)))
        check("snapshot guard: a same-gesture EMPTY re-read never clobbers a live non-empty snapshot (THE BUG 2 fix)",
              !NotesTargetLogic.acceptsSnapshotWrite(existing: SW(from: 5, to: 20, generation: 3),
                                                     incoming: SW(from: 20, to: 20, generation: 3)))
        check("snapshot guard: an OLDER-gesture write never wins",
              !NotesTargetLogic.acceptsSnapshotWrite(existing: SW(from: 5, to: 20, generation: 3),
                                                     incoming: SW(from: 2, to: 9, generation: 2)))
        check("snapshot guard: a NEWER-gesture bare-caret write DOES win (a fresh take re-snapshots)",
              NotesTargetLogic.acceptsSnapshotWrite(existing: SW(from: 5, to: 20, generation: 3),
                                                    incoming: SW(from: 4, to: 4, generation: 4)))
        check("snapshot guard: a same-gesture non-empty update is accepted",
              NotesTargetLogic.acceptsSnapshotWrite(existing: SW(from: 5, to: 20, generation: 3),
                                                    incoming: SW(from: 6, to: 22, generation: 3)))
        check("snapshot guard: a same-gesture empty-over-empty write is accepted (both bare carets)",
              NotesTargetLogic.acceptsSnapshotWrite(existing: SW(from: 8, to: 8, generation: 3),
                                                    incoming: SW(from: 12, to: 12, generation: 3)))
        check("snapshot guard: the JS store ships the generation-tagged write (dictation-target.js setSnapshot + generation)",
              targetSrc.contains("setSnapshot") && targetSrc.contains("generation"),
              "Web/StickyNotes/src/dictation-target.js")
    }

    static func probeBullseye(freshRoot: () -> URL, check: Check) {
        // --- 13b. bullseye set/arm/toggle/persist/auto-disarm (notes-bullseye BT2) --------------------
        // The PINNED, persistent target: Option+N in a note sets/moves + arms it; Option+B pure-toggles the
        // armed state preserving location; armed precedence applies only to fresh in-place dictation; persisted
        // as {note id, anchor, armed} and restored armed iff the note still exists; auto-disarmed when its note
        // is closed/deleted. The live arm/set/toggle/deliver flow +
        // the info-pill glyph are GUI/live (covered by live GUI verification); here the PURE decision + persistence model is
        // locked, plus a bundled-island shipping check that the JS half actually ships.

        // 13b-i. Option+B toggle: no bullseye -> noneSet ("No bullseye set"); an existing bullseye flips ONLY
        // armed, preserving note id + anchor.
        check("bullseye toggle: no bullseye set -> noneSet (drives the 'No bullseye set' toast)",
              NotesBullseyeLogic.toggled(nil) == .noneSet
              && NotesBullseyeLogic.noneSetToast == "No bullseye set")
        let disarmed = NotesBullseye(noteId: "note-x", anchor: 12, armed: false)
        check("bullseye toggle: disarmed -> armed, location preserved",
              NotesBullseyeLogic.toggled(disarmed) == .toggled(NotesBullseye(noteId: "note-x", anchor: 12, armed: true)))
        let armed = NotesBullseye(noteId: "note-x", anchor: 12, armed: true)
        check("bullseye toggle: armed -> disarmed, location preserved",
              NotesBullseyeLogic.toggled(armed) == .toggled(NotesBullseye(noteId: "note-x", anchor: 12, armed: false)))

        // 13b-ii. armed gate: drives the info-pill glyph + the delivery precedence.
        check("bullseye armed: true only for a set + armed bullseye",
              NotesBullseyeLogic.isArmed(armed)
              && !NotesBullseyeLogic.isArmed(disarmed)
              && !NotesBullseyeLogic.isArmed(nil))

        // 13b-iii. restart restore: kept (with its armed flag) iff its note is still open; else dropped (the
        // safe "else disarmed" outcome — a bullseye on a gone note reads as no-bullseye).
        check("bullseye restore: kept with its armed flag when the note still exists",
              NotesBullseyeLogic.restored(armed, openNoteIds: ["note-x", "note-y"]) == armed)
        check("bullseye restore: a disarmed bullseye restores disarmed (armed flag respected)",
              NotesBullseyeLogic.restored(disarmed, openNoteIds: ["note-x"]) == disarmed)
        check("bullseye restore: dropped when the note is gone (deleted between sessions)",
              NotesBullseyeLogic.restored(armed, openNoteIds: ["note-y"]) == nil)
        check("bullseye restore: nil in, nil out",
              NotesBullseyeLogic.restored(nil, openNoteIds: ["note-x"]) == nil)

        // 13b-iv. runtime auto-disarm survival: survives while its note is open; must disarm once its note is
        // closed/deleted; no bullseye trivially survives.
        check("bullseye survival: survives while its note is open",
              NotesBullseyeLogic.survives(armed, openNoteIds: ["note-x", "note-y"]))
        check("bullseye survival: does NOT survive once its note is closed/deleted (auto-disarm)",
              !NotesBullseyeLogic.survives(armed, openNoteIds: ["note-y"]))
        check("bullseye survival: no bullseye trivially survives (nothing to disarm)",
              NotesBullseyeLogic.survives(nil, openNoteIds: []))

        // 13b-v / C1: landing-kind x input-source x armed truth table. Only fresh dictation with an in-place
        // landing honors the bullseye. Selection transforms keep their selection, and non-destructive modes keep
        // the mode-owned landing. A disarmed bullseye always yields to the requested in-place route.
        check("bullseye precedence: armed + in-place + dictation wins over a transient snapshot",
              NotesBullseyeLogic.delivery(
                bullseye: armed, snapshotNoteId: "note-snap",
                landingKind: .inPlace, inputSource: .dictation) == .bullseye(noteId: "note-x"))
        check("bullseye precedence: armed + in-place + dictation wins with no snapshot too",
              NotesBullseyeLogic.delivery(
                bullseye: armed, snapshotNoteId: nil,
                landingKind: .inPlace, inputSource: .dictation) == .bullseye(noteId: "note-x"))
        check("bullseye precedence: a DISARMED bullseye yields to the transient snapshot",
              NotesBullseyeLogic.delivery(
                bullseye: disarmed, snapshotNoteId: "note-snap",
                landingKind: .inPlace, inputSource: .dictation) == .snapshot(noteId: "note-snap"))
        check("bullseye precedence: no bullseye + a snapshot -> snapshot",
              NotesBullseyeLogic.delivery(
                bullseye: nil, snapshotNoteId: "note-snap",
                landingKind: .inPlace, inputSource: .dictation) == .snapshot(noteId: "note-snap"))
        check("bullseye precedence: nothing armed and no snapshot -> requested in-place delivery",
              NotesBullseyeLogic.delivery(
                bullseye: nil, snapshotNoteId: nil,
                landingKind: .inPlace, inputSource: .dictation) == .requested
              && NotesBullseyeLogic.delivery(
                bullseye: disarmed, snapshotNoteId: nil,
                landingKind: .inPlace, inputSource: .dictation) == .requested
              && NotesBullseyeLogic.delivery(
                bullseye: disarmed, snapshotNoteId: "",
                landingKind: .inPlace, inputSource: .dictation) == .requested)
        check("bullseye precedence: armed + in-place + selection keeps the selection snapshot",
              NotesBullseyeLogic.delivery(
                bullseye: armed, snapshotNoteId: "note-snap",
                landingKind: .inPlace, inputSource: .selection) == .snapshot(noteId: "note-snap"))
        check("bullseye precedence: armed + in-place + foreign selection keeps its requested destination",
              NotesBullseyeLogic.delivery(
                bullseye: armed, snapshotNoteId: nil,
                landingKind: .inPlace, inputSource: .selection) == .requested)
        check("bullseye precedence: armed + non-destructive keeps mode landing for either input source",
              NotesBullseyeLogic.delivery(
                bullseye: armed, snapshotNoteId: "note-snap",
                landingKind: .nonDestructive, inputSource: .dictation) == .requested
              && NotesBullseyeLogic.delivery(
                bullseye: armed, snapshotNoteId: "note-snap",
                landingKind: .nonDestructive, inputSource: .selection) == .requested)

        let c1TruthTable: [(NotesBullseyeLogic.LandingKind, NotesBullseyeLogic.InputSource,
                            NotesBullseye?, NotesBullseyeLogic.Delivery)] = [
            (.inPlace, .dictation, armed, .bullseye(noteId: "note-x")),
            (.inPlace, .selection, armed, .requested),
            (.nonDestructive, .dictation, armed, .requested),
            (.nonDestructive, .selection, armed, .requested),
            (.inPlace, .dictation, disarmed, .requested),
            (.inPlace, .selection, disarmed, .requested),
            (.nonDestructive, .dictation, disarmed, .requested),
            (.nonDestructive, .selection, disarmed, .requested),
        ]
        check("bullseye C1 truth table: all 8 landing-kind x input-source x armed rows are exact",
              c1TruthTable.allSatisfy { landingKind, inputSource, bullseye, expected in
                NotesBullseyeLogic.delivery(
                    bullseye: bullseye, snapshotNoteId: nil,
                    landingKind: landingKind, inputSource: inputSource) == expected
              })

        // C1 stateful seam: compare the raw / `?` tuple and one-shot dictation tuple through the same helper,
        // then exercise selection, non-destructive, and gone-bullseye behavior with synthetic callbacks only.
        let suiteName = "viddydictate-c1-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let noteId = "note-c1-bullseye"
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: noteId, body: "synthetic open note")
            let state = NotesBullseyeState(store: store, defaults: defaults)
            state.setAtCaret(noteId: noteId)

            var bullseyeOutcome = NoteInsertOutcome.delivered
            var bullseyeDeliveries = 0
            var snapshotDeliveries = 0
            var markerRefreshes = 0
            var clipboardParks: [String] = []
            let callbacks = NotesDeliveryCallbacks(
                onSnapshotNoteTarget: { _ in nil },
                onDeliverToNoteTarget: { _, _ in snapshotDeliveries += 1; return .delivered },
                onInsertIntoActiveNote: { _ in .noWindow },
                onSetBullseyeAtCaret: { nil },
                onDeliverToBullseye: { _ in bullseyeDeliveries += 1; return bullseyeOutcome },
                onBullseyeStateChanged: { markerRefreshes += 1 },
                onRevealBullseye: { .noneSet },
                onResolveReplaceHighlightTarget: { nil },
                onShowReplaceHighlight: { _, _, _ in },
                onClearReplaceHighlight: { _ in },
                onUndoNoteDelivery: { _ in false },
                onReplaceNoteDelivery: { _, _ in false },
                onCurrentNoteId: { nil })
            let coordinator = NotesDeliveryCoordinator(
                callbacks: callbacks, bullseyeState: state,
                copyToClipboard: { clipboardParks.append($0) })

            func route(_ landingKind: NotesBullseyeLogic.LandingKind,
                       _ inputSource: NotesBullseyeLogic.InputSource,
                       noteTarget: NotesDictationTarget? = nil) -> NotesDeliveryCoordinator.NotesLanding {
                coordinator.routeNotesDelivery(
                    delivered: "synthetic output", mode: .email,
                    landingKind: landingKind, inputSource: inputSource, noteTarget: noteTarget,
                    shouldInsertIntoNotes: false, startedInNotes: false, currentlyKey: false)
            }

            let rawReference = route(.inPlace, .dictation)
            let oneShotDictation = route(.inPlace, .dictation)
            check("bullseye C1 call parity: raw / ? and one-shot dictation tuples land identically",
                  rawReference == .landed(noteUndo: noteId)
                  && oneShotDictation == rawReference && bullseyeDeliveries == 2)

            let selectionTarget = NotesDictationTarget(noteId: "note-c1-selection")
            let selectionLanding = route(.inPlace, .selection, noteTarget: selectionTarget)
            check("bullseye C1 stateful route: selection uses its snapshot, never the armed bullseye",
                  selectionLanding == .landed(noteUndo: selectionTarget.noteId)
                  && snapshotDeliveries == 1 && bullseyeDeliveries == 2 && state.armed)

            let nonDestructive = route(.nonDestructive, .dictation, noteTarget: selectionTarget)
            check("bullseye C1 stateful route: non-destructive mode keeps its landing and bullseye arm",
                  nonDestructive == .notNotes && snapshotDeliveries == 1
                  && bullseyeDeliveries == 2 && state.armed)

            bullseyeOutcome = .noWindow
            let goneLanding = route(.inPlace, .dictation)
            let goneWasParked: Bool
            if case .parked(_, refreshBullseye: true) = goneLanding {
                goneWasParked = true
            } else {
                goneWasParked = false
            }
            check("bullseye C1 gone note: one-shot tuple auto-disarms, refreshes marker, and parks output",
                  goneWasParked && !state.armed && markerRefreshes == 1
                  && clipboardParks == ["synthetic output"])
        } else {
            check("bullseye C1 stateful route: isolated defaults suite available", false)
        }

        // Pin both production call sites, not just the pure function. The coordinator must be the only owner of
        // the bridge branch so a future caller cannot quietly grow a second precedence ladder.
        let coordinatorSrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/App/NotesDeliveryCoordinator.swift", isDirectory: false)
        let coordinatorSrc = (try? String(contentsOf: coordinatorSrcURL, encoding: .utf8)) ?? ""
        let routeBody = sourceSlice(coordinatorSrc,
                                    from: "func routeNotesDelivery(",
                                    to: "return .notNotes")
        let c1ControllerSrc = sourceDictationController
        let inPlaceBody = sourceSlice(c1ControllerSrc,
                                      from: "func landInPlaceTransform(",
                                      to: "// MARK: lifecycle")
        let finalizeBody = sourceSlice(c1ControllerSrc,
                                       from: "private func finalize(delivered:",
                                       to: "private func deliverPushToTalk(")
        let bullseyeBridgeCalls = coordinatorSrc.components(separatedBy: "callbacks.onDeliverToBullseye(delivered)").count - 1
        check("bullseye C1 call sites: raw finalize and one-shot in-place call the same coordinator helper",
              finalizeBody.contains("notesDelivery.routeNotesDelivery(")
              && finalizeBody.contains("landingKind: .inPlace")
              && finalizeBody.contains("inputSource: .dictation")
              && finalizeBody.contains("noteTarget: notesDelivery.noteTarget")
              && inPlaceBody.contains("notesDelivery.routeNotesDelivery(")
              && inPlaceBody.contains("landingKind: .inPlace, inputSource: inputSource, noteTarget: noteTarget"))
        check("bullseye C1 single owner: only routeNotesDelivery calls the bullseye delivery bridge",
              !routeBody.isEmpty && bullseyeBridgeCalls == 1,
              "onDeliverToBullseye(delivered) occurrences=\(bullseyeBridgeCalls)")

        let registrySrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/App/OneShotRegistry.swift", isDirectory: false)
        let registrySrc = (try? String(contentsOf: registrySrcURL, encoding: .utf8)) ?? ""
        check("bullseye C1 input source: one-shot source is latched from takeHasSpeech and threaded to landing",
              registrySrc.contains("let takeHasSpeech = context.takeHasSpeech")
              && registrySrc.contains("inputSource: .dictation")
              && registrySrc.contains("inputSource: .selection")
              && registrySrc.contains("inputSource: inputSource"))

        // 13b-vi. persistence round-trip: the {note id, anchor, armed} record the state writes to UserDefaults
        // survives a JSON encode/decode byte-for-byte (so a restart restores exactly what was pinned).
        do {
            let encoded = try JSONEncoder().encode(armed)
            let decoded = try JSONDecoder().decode(NotesBullseye.self, from: encoded)
            check("bullseye persist: {note id, anchor, armed} round-trips through JSON intact", decoded == armed)
        } catch {
            check("bullseye persist: JSON round-trip did not throw", false, "\(error)")
        }

        // 13b-vii. the JS half ships. The bundled island is minified (identifiers mangled), so pin the two
        // outbound wire names (string literals survive) in the BUNDLED app.js; pin the bullseye anchor store +
        // follow-edits remap in the SOURCE module. (Wire-name parity with the Swift enums is enforced in
        // probeBridgeParity, which now also covers setBullseye / insertAtBullseye / bullseyeAnchor.)
        let appJS = NotesProbe.bundledAppJS
        check("bullseye: bundled island ships the setBullseye + insertAtBullseye outbound handlers",
              appJS.contains("setBullseye") && appJS.contains("insertAtBullseye"))

        let targetSrc = sourceDictationTargetJS
        check("bullseye: source module ships the pinned anchor store + follow-edits remap",
              !targetSrc.isEmpty
              && targetSrc.contains("mapBullseyeThroughChanges")
              && targetSrc.contains("setBullseyeAnchor"),
              "Web/StickyNotes/src/dictation-target.js")

        // 13b-viii. items 5a/5b: arm/disarm NEVER cancels the take + Option+B emits no mid-take toast. The live
        // recording state machine is GUI/tap (live GUI verification), so pin the pure contract PLUS the controller
        // edit structurally: `notes()` (Option+N set/arm) and `toggleBullseye()` (Option+B) no longer call
        // `discardIncidentalAudio()` (which idles the take), and `toggleBullseye()` no longer toasts armed/disarmed
        // mid-take. Guard: the discard seam itself still exists AND is still used elsewhere (the pure-command
        // chords) — we removed the two bullseye calls, not the seam.
        check("bullseye 5a: arm/disarm is the identity on the take (never cancels / idles it)",
              !NotesBullseyeLogic.armDisarmCancelsTake())

        let controllerSrc = sourceDictationController
        let notesBody = sourceSlice(controllerSrc,
                                    from: "private func notes() {",
                                    to: "private func toggleBullseye()")
        let toggleBody = sourceSlice(controllerSrc,
                                     from: "private func toggleBullseye() {",
                                     to: "func handleBullseyeAutoDisarmed(")
        let discardOccurrences = controllerSrc.components(separatedBy: "discardIncidentalAudio()").count - 1
        check("bullseye 5a: Option+N (notes / set + arm) no longer discards the in-flight take",
              !controllerSrc.isEmpty && !notesBody.isEmpty && !notesBody.contains("discardIncidentalAudio()"),
              "Sources/App/DictationController.swift notes()")
        check("bullseye 5a: Option+B (toggleBullseye) no longer discards the in-flight take",
              !toggleBody.isEmpty && !toggleBody.contains("discardIncidentalAudio()"),
              "Sources/App/DictationController.swift toggleBullseye()")
        check("bullseye 5b: Option+B no longer emits the armed/disarmed toast mid-take",
              !toggleBody.isEmpty && !toggleBody.contains("armedToast") && !toggleBody.contains("disarmedToast"),
              "Sources/App/DictationController.swift toggleBullseye()")
        check("bullseye 5a/5b: the discard seam still exists + is still used elsewhere (2 calls removed, seam kept)",
              controllerSrc.contains("func discardIncidentalAudio()") && discardOccurrences >= 2,
              "discardIncidentalAudio() occurrences=\(discardOccurrences)")
    }

    static func probeBullseyeMarker(check: Check) {
        // --- 13c. inline bullseye marker (notes-bullseye BT3) ----------------------------------------
        // A CodeMirror widget renders a bullseye glyph inline at the armed bullseye's anchor, shown ONLY while
        // armed AND while its note is the note in the editor; it follows the pinned anchor through edits and the
        // TRANSIENT snapshot gets NO marker. The widget render + follow-edits are CodeMirror/GUI (the review
        // link's job); here the PURE present-only-when-armed gate is locked, plus a bundled-island + source +
        // CSS shipping check that the JS/CSS half actually ships.

        // 13c-i. present-only-when-armed gate: the marker shows iff armed AND the bullseye's note is the active
        // (non-history) editor note. Disarmed, a different active note, the history view, or a missing id -> no
        // marker.
        check("bullseye marker: shows when armed AND the bullseye note is the active editor note",
              NotesBullseyeLogic.markerVisible(armed: true, bullseyeNoteId: "note-x",
                                               activeNoteId: "note-x", showingHistory: false))
        check("bullseye marker: hidden when disarmed (present-only-when-armed)",
              !NotesBullseyeLogic.markerVisible(armed: false, bullseyeNoteId: "note-x",
                                                activeNoteId: "note-x", showingHistory: false))
        check("bullseye marker: hidden when the active editor note is a DIFFERENT note",
              !NotesBullseyeLogic.markerVisible(armed: true, bullseyeNoteId: "note-x",
                                                activeNoteId: "note-y", showingHistory: false))
        check("bullseye marker: hidden in the history view even when armed",
              !NotesBullseyeLogic.markerVisible(armed: true, bullseyeNoteId: "note-x",
                                                activeNoteId: "note-x", showingHistory: true))
        check("bullseye marker: hidden when there is no bullseye note (nil / empty id)",
              !NotesBullseyeLogic.markerVisible(armed: true, bullseyeNoteId: nil,
                                                activeNoteId: "note-x", showingHistory: false)
              && !NotesBullseyeLogic.markerVisible(armed: true, bullseyeNoteId: "",
                                                   activeNoteId: "note-x", showingHistory: false))
        check("bullseye marker: hidden when no note is active (blank home)",
              !NotesBullseyeLogic.markerVisible(armed: true, bullseyeNoteId: "note-x",
                                                activeNoteId: nil, showingHistory: false))

        // L6: pin the character-like mapping contract at a MID-PARAGRAPH anchor. These ASCII fixtures model
        // CodeMirror ChangeSet.mapPos(..., -1), the exact mapping used by BOTH the live JS bullseye store and
        // the marker field. Every case keeps the anchor attached to the LEFT|RIGHT boundary instead of a pixel.
        func applyEdit(_ doc: String, anchor: Int, from: Int, to: Int, insert: String) -> (doc: String, anchor: Int) {
            let start = doc.index(doc.startIndex, offsetBy: from)
            let end = doc.index(doc.startIndex, offsetBy: to)
            let edited = String(doc[..<start]) + insert + String(doc[end...])
            let mapped = NotesTargetLogic.mapPosition(
                anchor, changeFrom: from, changeTo: to, insertedLen: insert.utf16.count)
            return (edited, mapped)
        }
        func staysAtBoundary(_ fixture: (doc: String, anchor: Int), left: String, right: String) -> Bool {
            guard fixture.anchor >= 0, fixture.anchor <= fixture.doc.count else { return false }
            let split = fixture.doc.index(fixture.doc.startIndex, offsetBy: fixture.anchor)
            return String(fixture.doc[..<split]).hasSuffix(left)
                && String(fixture.doc[split...]).hasPrefix(right)
        }

        let insertAbove = applyEdit("LEFTRIGHT", anchor: 4, from: 0, to: 0, insert: "TOP ")
        check("bullseye drift L6: insert above shifts the mapped mid-paragraph anchor with LEFT|RIGHT",
              insertAbove.anchor == 8 && staysAtBoundary(insertAbove, left: "LEFT", right: "RIGHT"))

        let deleteAbove = applyEdit("xxLEFTRIGHT", anchor: 6, from: 0, to: 2, insert: "")
        check("bullseye drift L6: delete above shifts the mapped mid-paragraph anchor back with LEFT|RIGHT",
              deleteAbove.anchor == 4 && staysAtBoundary(deleteAbove, left: "LEFT", right: "RIGHT"))

        let insertAt = applyEdit("LEFTRIGHT", anchor: 4, from: 4, to: 4, insert: "NEW")
        check("bullseye drift L6: insert AT the anchor keeps it before the inserted text (assoc -1)",
              insertAt.anchor == 4 && staysAtBoundary(insertAt, left: "LEFT", right: "NEWRIGHT"))

        let deleteSpanning = applyEdit("LEFTmiddleRIGHT", anchor: 7, from: 4, to: 10, insert: "")
        check("bullseye drift L6: delete spanning the anchor collapses it to the surviving LEFT|RIGHT boundary",
              deleteSpanning.anchor == 4 && staysAtBoundary(deleteSpanning, left: "LEFT", right: "RIGHT"))

        let multiLineAbove = applyEdit("LEFTRIGHT", anchor: 4, from: 0, to: 0, insert: "one\ntwo\n")
        check("bullseye drift L6: multi-line paste above shifts the anchor by the whole paste",
              multiLineAbove.anchor == 12
              && staysAtBoundary(multiLineAbove, left: "LEFT", right: "RIGHT"))

        let insertAfter = applyEdit("LEFTRIGHT", anchor: 4, from: 9, to: 9, insert: " tail")
        let deleteAfter = applyEdit("LEFTRIGHTxx", anchor: 4, from: 9, to: 11, insert: "")
        check("bullseye drift L6: inserts and deletes AFTER the mid-paragraph anchor leave it untouched",
              insertAfter.anchor == 4 && deleteAfter.anchor == 4
              && staysAtBoundary(insertAfter, left: "LEFT", right: "RIGHT")
              && staysAtBoundary(deleteAfter, left: "LEFT", right: "RIGHT"))

        let dictationAt = applyEdit("LEFTRIGHT", anchor: 4, from: 4, to: 4, insert: " DICTATED")
        let advancedAfterDictation = NotesBullseyeLogic.advancedAnchor(
            at: dictationAt.anchor, textLength: " DICTATED".utf16.count)
        let advancedFixture = (doc: dictationAt.doc, anchor: advancedAfterDictation)
        check("bullseye drift L6: dictation lands at the MID-PARAGRAPH anchor and advances before RIGHT",
              dictationAt.doc == "LEFT DICTATEDRIGHT"
              && dictationAt.anchor == 4 && advancedAfterDictation == 13
              && staysAtBoundary(advancedFixture, left: " DICTATED", right: "RIGHT"))

        // 13c-ii. the armed-state push is a wired outbound bridge message (Swift enum ++ JS parity is enforced
        // in probeBridgeParity, which now also covers bullseyeArmed).
        check("bullseye marker: bullseyeArmed is a wired outbound bridge message (Swift enum)",
              NotesOutbound.allCases.contains(.bullseyeArmed))

        // 13c-iii. the JS + CSS half ships. The bundled island is minified (identifiers mangled), so pin the
        // surviving string literals: the bullseyeArmed handler wire name and the marker DOM class in app.js,
        // and the marker style rule in app.css; pin the armed-flag store accessors in the SOURCE module.
        let appJS = NotesProbe.bundledAppJS
        let appCSS = NotesProbe.bundledAppCSS
        check("bullseye marker: bundled island ships the bullseyeArmed handler + the inline marker DOM class",
              appJS.contains("bullseyeArmed") && appJS.contains("cm-bullseye-marker"))
        check("bullseye marker: bundled CSS ships the inline marker style rule",
              appCSS.contains(".cm-bullseye-marker"))

        let targetSrc = sourceDictationTargetJS
        check("bullseye marker: source module ships the armed-flag store (setBullseyeArmed / isBullseyeArmed)",
              !targetSrc.isEmpty
              && targetSrc.contains("setBullseyeArmed")
              && targetSrc.contains("isBullseyeArmed"),
              "Web/StickyNotes/src/dictation-target.js")

        let editorSrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Web/StickyNotes/src/editor.js", isDirectory: false)
        let editorSrc = (try? String(contentsOf: editorSrcURL, encoding: .utf8)) ?? ""
        let markerFieldBody = sourceSlice(editorSrc,
                                          from: "const bullseyeMarkerField = StateField.define({",
                                          to: "// Show the inline bullseye marker")
        check("bullseye drift L6: marker field maps its live anchor and creates a fresh widget on every document change",
              !markerFieldBody.isEmpty
              && markerFieldBody.contains("tr.docChanged")
              && markerFieldBody.contains("tr.changes.mapPos(anchor, -1)")
              && markerFieldBody.contains("makeBullseyeMarkerState(anchor, tr.state.doc.length")
              && editorSrc.contains("new BullseyeMarkerWidget(")
              && !editorSrc.contains("eq() { return true; }"),
              "Web/StickyNotes/src/editor.js bullseyeMarkerField")

        // 13c-iv. item 5c (inline glyph trails one dictation). A delivery ADVANCES the anchor past the inserted
        // text so successive takes stack in reading order; the inline marker must then re-render at that ADVANCED
        // anchor (the END of the just-delivered text), NOT at `at` (the START, where the `side: -1` widget
        // self-maps = the end of the PREVIOUS dictation). The CodeMirror re-anchor is GUI (live GUI verification),
        // so pin the PURE advance math + the marker-position contract, plus a source check that `insertAtBullseye`
        // re-pushes the marker (clear-then-sync) as the last word after render().
        let at5c = 12, len5c = 5
        check("bullseye marker 5c: a delivery advances the anchor by the actual inserted span",
              NotesBullseyeLogic.advancedAnchor(at: at5c, textLength: len5c) == at5c + len5c
              && NotesBullseyeLogic.advancedAnchor(at: 0, textLength: 3) == 3)
        check("bullseye marker 5c: the post-delivery marker sits at the ADVANCED anchor, NOT at the insert start",
              NotesBullseyeLogic.postDeliveryMarkerAnchor(at: at5c, textLength: len5c)
                  == NotesBullseyeLogic.advancedAnchor(at: at5c, textLength: len5c)
              && NotesBullseyeLogic.postDeliveryMarkerAnchor(at: at5c, textLength: len5c) != at5c)

        let dictationActionsSrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Web/StickyNotes/src/actions-dictation.js", isDirectory: false)
        let dictationActionsSrc = (try? String(contentsOf: dictationActionsSrcURL, encoding: .utf8)) ?? ""
        let insertBody: String = {
            guard let a = dictationActionsSrc.range(of: "export function insertAtBullseye(payload) {"),
                  let b = dictationActionsSrc.range(
                      of: "\nexport function ", range: a.upperBound..<dictationActionsSrc.endIndex)
            else { return "" }
            return String(dictationActionsSrc[a.upperBound..<b.lowerBound])
        }()
        check("bullseye marker 5c: insertAtBullseye re-pushes the marker (clear-then-sync) from the advanced anchor after render()",
              !insertBody.isEmpty
              && insertBody.contains("setBullseyeMarker(null)")
              && insertBody.contains("syncBullseyeMarker()"),
              "Web/StickyNotes/src/actions-dictation.js insertAtBullseye")
    }

    /// --- 13d. Option+Shift+N bullseye reveal (notes-bullseye BT6, L7) -------------------------------------
    /// "Show me where the bullseye is": front the window holding its note, select that note's tab, scroll the
    /// anchor into view, and arm it if it was disarmed. Reveal is a NAVIGATION act, not a visibility one — the
    /// marker already renders persistently, just only while its note is the active tab in a visible window.
    ///
    /// The live window/tab/scroll walk is AppKit + CodeMirror (GUI), so pin here: the pure reveal decision, the
    /// two honest-failure toasts, the shift-qualified chord grammar that makes Option+Shift+N a distinct binding
    /// from Option+N, and that the JS half actually ships.
    static func probeBullseyeReveal(freshRoot: () -> URL, check: Check) {
        let armed = NotesBullseye(noteId: "note-x", anchor: 42, armed: true)
        let disarmed = NotesBullseye(noteId: "note-x", anchor: 42, armed: false)

        // 13d-i. the reveal decision. An armed bullseye whose note is live navigates without re-arming; a
        // DISARMED one navigates AND arms (a disarmed bullseye draws no marker, so revealing it would show
        // nothing); nothing set is the Option+B "none set" case; a set bullseye whose note no live window holds
        // is the honest "closed" case — never a silent no-op, and never a reopen.
        check("bullseye reveal: an armed bullseye in a live window reveals without re-arming",
              NotesBullseyeLogic.reveal(armed, liveNoteIds: ["note-x", "note-y"])
              == .reveal(noteId: "note-x", arm: false))
        check("bullseye reveal: a DISARMED bullseye is armed by the reveal (an unarmed one shows no marker)",
              NotesBullseyeLogic.reveal(disarmed, liveNoteIds: ["note-x"])
              == .reveal(noteId: "note-x", arm: true))
        check("bullseye reveal: reveals in whatever window holds the note, not only the active one",
              NotesBullseyeLogic.reveal(armed, liveNoteIds: ["note-y", "note-x"])
              == .reveal(noteId: "note-x", arm: false))
        check("bullseye reveal: nothing set -> the Option+B none-set outcome",
              NotesBullseyeLogic.reveal(nil, liveNoteIds: ["note-x"]) == .noneSet)
        check("bullseye reveal: set but its note is in no live window -> the honest closed outcome",
              NotesBullseyeLogic.reveal(armed, liveNoteIds: ["note-y"]) == .noteClosed
              && NotesBullseyeLogic.reveal(armed, liveNoteIds: []) == .noteClosed)
        check("bullseye reveal: both failures toast (none-set reuses Option+B's copy, closed says closed)",
              NotesBullseyeLogic.noneSetToast == "No bullseye set"
              && NotesBullseyeLogic.revealNoteClosedToast == "Bullseye note is closed"
              && NotesBullseyeLogic.revealNoteClosedToast != NotesBullseyeLogic.goneToast)

        // 13d-ii. arming in place. Distinct from `toggle()` (flips) and `setAtCaret` (relocates): the reveal must
        // leave a disarmed bullseye armed at the SAME anchor, and an already-armed one untouched (so the caller
        // refreshes the info pill exactly once).
        let defaultsSuite = "viddydictate-reveal-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: defaultsSuite) {
            defer { defaults.removePersistentDomain(forName: defaultsSuite) }
            // The state confirms its persisted value against the store's OPEN notes on first use, so the note has
            // to really exist in a scratch store or the restore would drop the bullseye before arm() sees it.
            let noteId = "note-reveal-arm"
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: noteId, body: "synthetic open note")
            if let encoded = try? JSONEncoder().encode(NotesBullseye(noteId: noteId, anchor: 42, armed: false)) {
                defaults.set(encoded, forKey: "notesBullseye")
            }
            let state = NotesBullseyeState(store: store, defaults: defaults)
            let didArm = state.arm()
            check("bullseye reveal: arm() arms a disarmed bullseye in place, preserving its anchor",
                  didArm && state.current?.armed == true && state.current?.anchor == 42
                  && state.current?.noteId == noteId)
            check("bullseye reveal: arm() is idempotent — an already-armed bullseye reports no change",
                  !state.arm() && state.current?.armed == true && state.current?.anchor == 42)
        } else {
            check("bullseye reveal: probe defaults suite is creatable", false, defaultsSuite)
        }

        // 13d-iii. the chord grammar. Option+Shift+N is a SHIFT-QUALIFIED binding on the same keycode as
        // Option+N: the qualifier is part of KeySpec identity, so the two coexist without conflicting, exact
        // matching routes a shifted press to the reveal, and an unshifted press still reaches Option+N.
        let defs = HotkeyMap.defaults()
        let revealKey = defs.key(for: .bullseyeReveal)
        let notesKey = defs.key(for: .notes)
        check("bullseye reveal: the default chord is Shift-qualified N — the same keycode as Option+N",
              revealKey.code == 45 && revealKey.shift && !revealKey.isModifier
              && notesKey.code == 45 && !notesKey.shift)
        check("bullseye reveal: ⇧N and N are DISTINCT bindings (the shift qualifier is part of identity)",
              revealKey != notesKey)
        // The shift qualifier is exactly what lets both live on keycode 45: assigning ⇧N to the reveal slot is
        // conflict-free in a map that already binds N to sticky notes, while assigning plain N to that same slot
        // collides. Same key, one bit of difference, and the collision flips.
        check("bullseye reveal: ⇧N binds cleanly alongside N — the qualifier is what avoids the collision",
              defs.conflict(of: .regular(keyCode: 45, label: "⇧N", shift: true),
                            assigningTo: .command(.bullseyeReveal)) == nil
              && defs.conflict(of: .regular(keyCode: 45, label: "N"),
                               assigningTo: .command(.bullseyeReveal)) == .some(.command(.notes)))
        check("bullseye reveal: ⇧N is still guarded against a SECOND claimant (it is a real binding, not a free pass)",
              defs.conflict(of: revealKey, assigningTo: .command(.notes)) == .some(.command(.bullseyeReveal)))
        check("bullseye reveal: a shifted N resolves to the reveal, an unshifted N to sticky notes",
              defs.command(forKeyCode: 45, shift: true) == .bullseyeReveal
              && defs.command(forKeyCode: 45, shift: false) == .notes
              && defs.command(forKeyCode: 45) == .notes)
        check("bullseye reveal: no OTHER chord claims a shift qualifier, so every existing chord is unchanged",
              HotkeyCommand.allCases.filter { defs.key(for: $0).shift } == [.bullseyeReveal])
        check("bullseye reveal: an unclaimed shifted key still falls back to its plain chord (⇧P is still Cleanup selection)",
              defs.command(forKeyCode: 35, shift: true) == nil
              && defs.command(forKeyCode: 35, shift: false) == .cleanupSelection)
        check("bullseye reveal: the chord is rebindable like every other binding (default-restorable map slot)",
              defs.bindings[HotkeyCommand.bullseyeReveal.rawValue] == HotkeyCommand.bullseyeReveal.defaultKey
              && HotkeyCommand.displayOrder.contains(.bullseyeReveal))

        // A saved map written BEFORE the shift qualifier existed carries no `shift` key. Decoding must default
        // it to false rather than throwing the whole map away (which would silently reset every user rebind).
        let legacyJSON = Data(#"{"isModifier":false,"code":45,"label":"N"}"#.utf8)
        let legacy = try? JSONDecoder().decode(KeySpec.self, from: legacyJSON)
        check("bullseye reveal: a pre-shift saved KeySpec decodes as an UNSHIFTED chord, not a decode failure",
              legacy != nil && legacy?.shift == false && legacy?.code == 45)

        // 13d-iv. the wire + the JS half. Wire-name parity with the JS MSG table is enforced in probeBridgeParity.
        check("bullseye reveal: revealBullseye is a wired outbound bridge message (Swift enum)",
              NotesOutbound.allCases.contains(.revealBullseye))

        let appJS = NotesProbe.bundledAppJS
        check("bullseye reveal: bundled island ships the revealBullseye handler",
              appJS.contains("revealBullseye"))

        let editorSrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Web/StickyNotes/src/editor.js", isDirectory: false)
        let editorSrc = (try? String(contentsOf: editorSrcURL, encoding: .utf8)) ?? ""
        check("bullseye reveal: source editor ships a scroll-only primitive (no doc edit, no selection move)",
              editorSrc.contains("export function scrollPositionIntoView(pos)")
              && editorSrc.contains("EditorView.scrollIntoView(at, { y: \"center\" })"),
              "Web/StickyNotes/src/editor.js")

        let dictationActionsSrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Web/StickyNotes/src/actions-dictation.js", isDirectory: false)
        let dictationActionsSrc = (try? String(contentsOf: dictationActionsSrcURL, encoding: .utf8)) ?? ""
        let revealBody: String = {
            guard let a = dictationActionsSrc.range(of: "export function revealBullseye(payload) {"),
                  let b = dictationActionsSrc.range(
                      of: "\nexport function ", range: a.upperBound..<dictationActionsSrc.endIndex)
            else { return "" }
            return String(dictationActionsSrc[a.upperBound..<b.lowerBound])
        }()
        check("bullseye reveal: the JS handler scrolls to the LIVE anchor and never edits or re-anchors",
              !revealBody.isEmpty
              && revealBody.contains("scrollPositionIntoView(at)")
              && revealBody.contains("getBullseye()")
              && !revealBody.contains("insertAtRange(")
              && !revealBody.contains("setBullseyeAnchor(")
              && !revealBody.contains("setEditorSelection("),
              "Web/StickyNotes/src/actions-dictation.js revealBullseye")

        // 13d-iv-b. the reveal's attention cue (VDPF L7). A 12px glyph in a wall of text is easy to miss even
        // once it has been scrolled to, so the reveal plays a one-shot pulse on the marker. Three properties are
        // worth locking, because each one is a way this turns from a cue into a nuisance or into a layout bug:
        //   1. the flag is effect-gated and re-defaulted to false inside update(), never read off the previous
        //      marker — otherwise a pulse would ride along on the next unrelated rebuild (any doc edit);
        //   2. it is sent from the reveal path and from EXACTLY ONE place — a glyph that pulsed on every
        //      ordinary syncBullseyeMarker (each delivery, each tab switch) would be a tic, not an answer;
        //   3. the animation is confined to the pseudo-element and to transform/opacity, so the zero-width
        //      side:-1 widget still cannot occupy space or reflow the line (locked: the marker covers the
        //      character under it, hand-tested and kept).
        let markerFieldUpdate = sourceSlice(editorSrc,
                                            from: "const bullseyeMarkerField = StateField.define({",
                                            to: "// Show the inline bullseye marker")
        check("bullseye reveal: source editor ships an effect-gated pulse whose flag cannot leak into an unrelated rebuild",
              editorSrc.contains("export function pulseBullseyeMarker()")
              && markerFieldUpdate.contains("let pulse = false;")
              && markerFieldUpdate.contains("effect.is(pulseBullseyeMarkerEffect)")
              && markerFieldUpdate.contains("makeBullseyeMarkerState(anchor, tr.state.doc.length, pulse)")
              && !markerFieldUpdate.contains("marker.pulse")
              && editorSrc.contains("cm-bullseye-pulse"),
              "Web/StickyNotes/src/editor.js pulseBullseyeMarker")

        check("bullseye reveal: the JS handler plays the one-shot cue on the marker it just synced",
              !revealBody.isEmpty && revealBody.contains("pulseBullseyeMarker()"),
              "Web/StickyNotes/src/actions-dictation.js revealBullseye")

        // Structural: one declaration in editor.js, one call in the whole island, and it is the reveal's.
        let islandSrcDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Web/StickyNotes/src", isDirectory: true)
        let islandSrcFiles = (try? FileManager.default.contentsOfDirectory(at: islandSrcDir,
                                                                          includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "js" } ?? []
        let pulseCallSites = islandSrcFiles.reduce(0) { total, url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let hits = text.components(separatedBy: "pulseBullseyeMarker()").count - 1
            // editor.js's single hit is the declaration itself, not a call.
            return total + (url.lastPathComponent == "editor.js" ? max(0, hits - 1) : hits)
        }
        check("bullseye reveal: the pulse is played from exactly ONE place in the island, and it is the reveal",
              !islandSrcFiles.isEmpty
              && editorSrc.components(separatedBy: "export function pulseBullseyeMarker()").count - 1 == 1
              && pulseCallSites == 1,
              "Web/StickyNotes/src/ pulseBullseyeMarker() call sites = \(pulseCallSites)")

        let bundledCSS = NotesProbe.bundledAppCSS
        let pulseRule = cssBlock(bundledCSS, selector: ".cm-bullseye-pulse::after")
        let pulseFrames = cssBlock(bundledCSS, selector: "@keyframes cm-bullseye-reveal-pulse")
        // Anything that is not transform/opacity here is either layout (which the zero-width widget must never
        // take) or a residue risk (`animation-fill-mode: forwards` would strand the glyph at its last frame).
        let layoutProperties = ["width", "height", "margin", "padding", "display", "position",
                                "font-size", "line-height", "top:", "left:", "bottom:", "right:", "content:"]
        check("bullseye reveal: the pulse animates the ::after glyph in transform/opacity only — no layout, no residue",
              !pulseRule.isEmpty && !pulseFrames.isEmpty
              && pulseRule.contains("animation:") && pulseRule.contains("cm-bullseye-reveal-pulse")
              && !pulseRule.contains("animation-fill-mode") && !pulseFrames.contains("forwards")
              && pulseFrames.contains("transform: scale(") && pulseFrames.contains("opacity:")
              && layoutProperties.allSatisfy { !pulseRule.contains($0) && !pulseFrames.contains($0) },
              "StickyNotes/app.css .cm-bullseye-pulse::after")

        // 13d-v. locked scope: the reveal must NOT reopen a closed note (that is restart/reopen durability,
        // explicitly out of scope). Pin it structurally on the registry walk.
        let registrySrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/App/NotesWindowRegistry.swift", isDirectory: false)
        let registrySrc = (try? String(contentsOf: registrySrcURL, encoding: .utf8)) ?? ""
        let revealWalk = sourceSlice(registrySrc,
                                     from: "func revealBullseye() -> NotesBullseyeLogic.RevealOutcome {",
                                     to: "/// Deliver an armed take to the pinned bullseye's note BY ID")
        check("bullseye reveal: the registry walk fronts the app, selects the tab, and scrolls — and never reopens a note",
              !revealWalk.isEmpty
              && revealWalk.contains("NSApp.activate(ignoringOtherApps: true)")
              && revealWalk.contains("controller.focusTab(noteId: noteId)")
              && revealWalk.contains("controller.revealBullseye(id: noteId)")
              && !revealWalk.contains("openPrimary()")
              && !revealWalk.contains("openFileBackedNote")
              && !revealWalk.contains("store.restore"),
              "Sources/App/NotesWindowRegistry.swift revealBullseye()")
    }

    static func probeReplaceHighlight(check: Check) {
        // --- 13d. four-color replace highlight (notes-bullseye BT4) ----------------------------------
        // A CodeMirror `mark` decoration tints the note range a pending level-based operation will REPLACE,
        // four colors keyed to Raw / Cleanup / Tighten / Summarize. It covers both replace-flows (the Option+P
        // pick and a dictation take overwriting a selection), live-updates on level change, and clears on
        // cancel/commit. The mark render + live recolor are CodeMirror/GUI (live GUI verification); here the
        // PURE color mapping + present-only-over-a-selection gate are locked, plus a bundled-island + source +
        // CSS shipping check that the JS/CSS half actually ships.
        typealias RH = NotesReplaceHighlightLogic

        // 13d-i. the four-color mapping. The Option+P pick offers only the 3 CleanupLevels (never Raw); a
        // dictation take maps Raw when cleanup is off, else the active level.
        check("replace highlight: picked level maps straight across (cleanup/tighten/summarize)",
              RH.from(.cleanup) == .cleanup && RH.from(.tighten) == .tighten && RH.from(.summarize) == .summarize)
        check("replace highlight: dictation take uses the Raw color when cleanup is OFF",
              RH.level(cleanupEnabled: false, cleanupLevel: .summarize) == .raw)
        check("replace highlight: dictation take uses the active `?`-cleanup level when ON",
              RH.level(cleanupEnabled: true, cleanupLevel: .cleanup) == .cleanup
              && RH.level(cleanupEnabled: true, cleanupLevel: .tighten) == .tighten
              && RH.level(cleanupEnabled: true, cleanupLevel: .summarize) == .summarize)
        check("replace highlight: four distinct level tokens, each -> its cm-replace-<token> class",
              Set(RH.Level.allCases.map(\.rawValue)) == ["raw", "cleanup", "tighten", "summarize"]
              && RH.cssClass(.raw) == "cm-replace-raw" && RH.cssClass(.cleanup) == "cm-replace-cleanup"
              && RH.cssClass(.tighten) == "cm-replace-tighten" && RH.cssClass(.summarize) == "cm-replace-summarize")

        // 13d-ii. present-only-over-a-STORED-range gate (item-3): tints ONLY a non-empty STORED range (the
        // deterministic snapshot of the range to replace — NOT the live selection at push time), in the
        // highlighted note, when it is the active (non-history) editor note. No stored range (nothing to
        // replace), a different active note, the history view, or a missing id -> no tint.
        check("replace highlight: shows over a non-empty stored range in the active note",
              RH.highlightVisible(hasStoredRange: true, highlightNoteId: "note-x",
                                  activeNoteId: "note-x", showingHistory: false))
        check("replace highlight: hidden with no stored range (nothing to REPLACE)",
              !RH.highlightVisible(hasStoredRange: false, highlightNoteId: "note-x",
                                   activeNoteId: "note-x", showingHistory: false))
        check("replace highlight: hidden when the active editor note is a DIFFERENT note",
              !RH.highlightVisible(hasStoredRange: true, highlightNoteId: "note-x",
                                   activeNoteId: "note-y", showingHistory: false))
        check("replace highlight: hidden in the history view",
              !RH.highlightVisible(hasStoredRange: true, highlightNoteId: "note-x",
                                   activeNoteId: "note-x", showingHistory: true))
        check("replace highlight: hidden when there is no highlighted note (nil / empty id) or none active",
              !RH.highlightVisible(hasStoredRange: true, highlightNoteId: nil,
                                   activeNoteId: "note-x", showingHistory: false)
              && !RH.highlightVisible(hasStoredRange: true, highlightNoteId: "",
                                      activeNoteId: "note-x", showingHistory: false)
              && !RH.highlightVisible(hasStoredRange: true, highlightNoteId: "note-x",
                                      activeNoteId: nil, showingHistory: false))

        // 13d-ii(b). item-3 contract shift: the tint PERSISTS without a live selection — the gate is keyed on
        // the STORED range, not on a live selection at push time, so an Option+P pick stays tinted after the
        // level picker steals focus and collapses the note's live selection. (The Swift gate takes only
        // `hasStoredRange`; there is no `hasSelection` input left to depend on.)
        check("replace highlight: tint persists without a live selection (keyed on the stored range)",
              RH.highlightVisible(hasStoredRange: true, highlightNoteId: "note-x",
                                  activeNoteId: "note-x", showingHistory: false))

        // 13d-iii. only the Option+P pick tints among the one-shot modes — email / search / custom do NOT (the
        // level picker is P-only, and the tint rides the level picker). Locks "Email/custom modes are NOT
        // tinted" against the same facet the flow gates on.
        check("replace highlight: only the Option+P selection-transform pick tints (email is not a picker mode)",
              OneShotRegistry.usesLevelPicker(.cleanupSelection) && !OneShotRegistry.usesLevelPicker(.email))

        // 13d-iv. the push is a wired outbound bridge message (Swift enum ++ JS parity enforced in
        // probeBridgeParity, which now also covers replaceHighlight).
        check("replace highlight: replaceHighlight is a wired outbound bridge message (Swift enum)",
              NotesOutbound.allCases.contains(.replaceHighlight))

        // 13d-v. the JS + CSS half ships. The bundled island is minified, so pin the surviving string literals:
        // the replaceHighlight handler wire name and the cm-replace- class prefix in app.js, and the four
        // per-level style rules in app.css; pin the range store accessors in the SOURCE module.
        let appJS = NotesProbe.bundledAppJS
        let appCSS = NotesProbe.bundledAppCSS
        check("replace highlight: bundled island ships the replaceHighlight handler + the cm-replace- class prefix",
              appJS.contains("replaceHighlight") && appJS.contains("cm-replace-"))
        check("replace highlight: bundled CSS ships all four per-level tint rules",
              appCSS.contains(".cm-replace-raw") && appCSS.contains(".cm-replace-cleanup")
              && appCSS.contains(".cm-replace-tighten") && appCSS.contains(".cm-replace-summarize"))

        let targetSrc = sourceDictationTargetJS
        check("replace highlight: source module ships the range store (getReplaceHighlight / setReplaceHighlight)",
              !targetSrc.isEmpty
              && targetSrc.contains("getReplaceHighlight")
              && targetSrc.contains("setReplaceHighlight"),
              "Web/StickyNotes/src/dictation-target.js")

        // 13d-vi (item-3). the replaceHighlight handler ships the auto-unhighlight: it captures the range from
        // the deterministic snapshot (getSnapshot) and collapses the live selection (collapseEditorSelection)
        // right after tinting, so the color shows instead of hiding under the selection background. The bundle
        // is minified (these local identifiers are mangled), so pin them in the SOURCE handler module — matching
        // how the range-store accessors are pinned above.
        let actionsSrc = sourceActionsJS
        let dictationActionsSrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Web/StickyNotes/src/actions-dictation.js", isDirectory: false)
        let dictationActionsSrc = (try? String(contentsOf: dictationActionsSrcURL, encoding: .utf8)) ?? ""
        check("replace highlight: handler tints from the snapshot range + collapses the selection (collapseEditorSelection)",
              !actionsSrc.isEmpty
              && actionsSrc.contains("getSnapshot")
              && actionsSrc.contains("collapseEditorSelection"),
              "Web/StickyNotes/src/actions.js")

        // 13d-vii (refine2 BUG 2 + 3a): the Option+P-over-a-note-selection fix ships in the source. (1) the
        // snapshotTarget/replaceHighlight handlers thread a gesture `generation` so the store's guard can reject
        // the collapsed same-gesture re-read; (2) tearing the tint down WITHOUT delivering restores the original
        // selection from the still-valid snapshot (`restoreSelectionFromSnapshot` -> `setEditorSelection`) so the
        // follow-up synthetic Cmd+C copies the real text; (3) BUG 3a: `makeEditor` ships `drawSelection()` — the
        // CM6 native/custom caret desync fix — so the collapse-then-restore never leaves a stale second caret.
        // The Swift-side "reuse the ONE authoritative note target instead of re-snapshotting the collapsed
        // selection" is pinned by the by-note-id route checks in probeNoteTargetSnapshot. Local identifiers are
        // mangled in the minified bundle, so pin them in the SOURCE modules (matching the collapse pin above).
        check("replace highlight: snapshotTarget/replaceHighlight thread the gesture generation (store write guard)",
              !actionsSrc.isEmpty && actionsSrc.contains("generation")
              && !dictationActionsSrc.isEmpty && dictationActionsSrc.contains("generation"),
              "Web/StickyNotes/src/actions.js + actions-dictation.js")
        check("replace highlight: teardown restores the original selection (restoreSelectionFromSnapshot + setEditorSelection)",
              !actionsSrc.isEmpty
              && actionsSrc.contains("restoreSelectionFromSnapshot")
              && actionsSrc.contains("setEditorSelection"),
              "Web/StickyNotes/src/actions.js")
        let editorSrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Web/StickyNotes/src/editor.js", isDirectory: false)
        let editorSrc = (try? String(contentsOf: editorSrcURL, encoding: .utf8)) ?? ""
        check("replace highlight: editor ships setEditorSelection (restore primitive) + drawSelection() (BUG 3a double-caret fix)",
              !editorSrc.isEmpty
              && editorSrc.contains("setEditorSelection")
              && editorSrc.contains("drawSelection"),
              "Web/StickyNotes/src/editor.js")
    }

    static func probeTakeControls(check: Check) {
        // --- 13e. take controls: Esc-cancel + Option+Z notes cross-focus undo (notes-bullseye BT5) ---------
        // Esc ABORTS the in-progress take (record/processing) — nothing lands, the target selection is left
        // untouched, the BT4 replace highlight is cleared. Option+Z reverts the LAST ViddyDictate-delivered edit
        // IN A NOTE even when focus moved away (reach-back by note id — a controlled surface), restoring any
        // overwritten text; the existing foreign-app tier is left as-is. The chord + real reach-back are GUI/tap
        // (live GUI verification); here the PURE abort gate, undo routing, and the delivery/undo round-trip are
        // locked, plus a bundled-island + source shipping check that the JS half actually ships.
        typealias U = NotesUndoLogic

        // 13e-i. Esc aborts ONLY while a take is active (recording / locked / final processing); otherwise Esc is
        // a normal key that passes through to the focused app.
        check("take controls: Esc aborts while a take is active",
              U.escapeAborts(isTakeActive: true))
        check("take controls: Esc passes through when no take is active",
              !U.escapeAborts(isTakeActive: false))

        // 13e-ii. Option+Z routing: a note delivery (non-empty pending note id) routes to the notes reach-back;
        // a foreign / clipboard landing (nil or empty id) falls to the existing foreign-app tier.
        check("take controls: Option+Z routes to notes reach-back when the last delivery landed in a note",
              U.route(pendingNoteId: "note-x") == .note(id: "note-x"))
        check("take controls: Option+Z falls to the foreign-app tier when the last delivery was not a note",
              U.route(pendingNoteId: nil) == .foreign && U.route(pendingNoteId: "") == .foreign)

        // 13e-iii. delivery + undo round-trip: an undo restores the EXACT pre-delivery doc — removing the
        // delivered text and putting back anything it overwrote. A bare-caret insert has nothing to restore; a
        // selection overwrite restores the overwritten span.
        let doc = "Hello world"
        let inserted = U.applyDelivery(doc: doc, from: 5, to: 5, insert: " there")   // bare caret at "Hello|"
        check("take controls: a bare-caret insert lands the text",
              inserted.after == "Hello there world"
              && inserted.record.replaced == "" && inserted.record.insertedLen == 6)
        check("take controls: Option+Z removes an inserted dictation (restores the pre-delivery doc)",
              U.applyUndo(doc: inserted.after, record: inserted.record) == doc)

        let overwritten = U.applyDelivery(doc: doc, from: 6, to: 11, insert: "there")  // select "world"
        check("take controls: a selection-overwriting take replaces the range and records the overwritten text",
              overwritten.after == "Hello there"
              && overwritten.record.replaced == "world" && overwritten.record.insertedLen == 5)
        check("take controls: Option+Z on an overwrite restores the overwritten text",
              U.applyUndo(doc: overwritten.after, record: overwritten.record) == doc)

        // 13e-iv. the reach-back is a wired outbound bridge message (Swift enum ++ JS parity enforced in
        // probeBridgeParity, which now also covers undoNoteDelivery).
        check("take controls: undoNoteDelivery is a wired outbound bridge message (Swift enum)",
              NotesOutbound.allCases.contains(.undoNoteDelivery))

        // 13e-v. the JS half ships. The bundled island is minified, so pin the surviving string literal — the
        // undoNoteDelivery handler wire name in app.js — and pin the last-delivery store accessors + follow-edits
        // remap in the SOURCE module (mirroring how BT1..BT4 pin both bundled and source).
        let appJS = NotesProbe.bundledAppJS
        check("take controls: bundled island ships the undoNoteDelivery handler",
              appJS.contains("undoNoteDelivery"))

        let targetSrc = sourceDictationTargetJS
        check("take controls: source module ships the last-delivery store (recordDelivery / getLastDelivery / mapLastDeliveryThroughChanges)",
              !targetSrc.isEmpty
              && targetSrc.contains("recordDelivery")
              && targetSrc.contains("getLastDelivery")
              && targetSrc.contains("mapLastDeliveryThroughChanges"),
              "Web/StickyNotes/src/dictation-target.js")

        // Wave-1 L2: a one-shot's Esc-cancel generation must be captured before transcription and checked again
        // inside the completion before any transcript can be consumed or landed. The mismatch path must release
        // the registry's busy latch, and the controller's cancel guard must accept the split one-shot phase.
        let registrySrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/App/OneShotRegistry.swift", isDirectory: false)
        let registrySrc = (try? String(contentsOf: registrySrcURL, encoding: .utf8)) ?? ""
        let controllerSrc = sourceDictationController
        let transcribeBody = sourceSlice(registrySrc,
                                         from: "private func transcribe(_ entry: Entry) {",
                                         to: "private func gateFailed(")
        let generationOccurrences = transcribeBody.components(separatedBy: "currentTakeGeneration").count - 1
        check("take controls: one-shot transcribe pins the Esc generation and releases busy when canceled",
              !transcribeBody.isEmpty
              && generationOccurrences >= 2
              && transcribeBody.contains("self.busy = false"),
              "currentTakeGeneration occurrences=\(generationOccurrences)")

        let cancelBody = sourceSlice(controllerSrc,
                                     from: "private func cancelTake() {",
                                     to: "private func notes() {")
        let cancelGuard = cancelBody.split(separator: "\n")
            .first(where: { $0.contains("guard state ==") })
            .map(String.init) ?? ""
        check("take controls: Esc cancel guard accepts the one-shot finishing phase",
              cancelGuard.contains(".oneShotFinishing"),
              "Sources/App/DictationController.swift cancelTake() guard")

        // Wave-1 L3: a successful foreign in-place landing owns the foreign undo tier, so it must clear any
        // stale note-delivery undo id even when the mode itself does not wire a new foreign pendingUndo.
        let landInPlaceBody = sourceSlice(controllerSrc,
                                          from: "func landInPlaceTransform(",
                                          to: "// MARK: lifecycle")
        check("take controls: in-place landing clears stale note undo ownership",
              !landInPlaceBody.isEmpty
              && landInPlaceBody.contains("self.pendingUndo = self.makePendingUndo(")
              && landInPlaceBody.contains("self.notesDelivery.pendingNoteUndo = nil"),
              "Sources/App/DictationController.swift landInPlaceTransform()")
    }

    static func probeTakeTeardown(check: Check) {
        let controllerSrc = sourceDictationController

        let discardBody = sourceSlice(controllerSrc,
                                from: "func discardIncidentalAudio() {",
                                to: "private func cancelTake() {")
        let cancelBody = sourceSlice(controllerSrc,
                               from: "private func cancelTake() {",
                               to: "private func notes() {")
        let beginRecordingBody = sourceSlice(controllerSrc,
                                       from: "private func beginRecording() {",
                                       to: "private func tickPartial() {")
        let micStartErrorBody = sourceSlice(beginRecordingBody,
                                      from: "} catch {",
                                      to: "state = .recording")
        let finishBody = sourceSlice(controllerSrc,
                               from: "private func finish() {",
                               to: "private func deliver(text rawText:")
        let nothingHeardBody = sourceSlice(controllerSrc,
                                from: "private func finishNothingHeard(",
                                to: "private func finish() {")
        let deliverBody = sourceSlice(controllerSrc,
                                from: "private func deliver(text rawText:",
                                to: "private func landCleanupRetry(")
        let finalizeBody = sourceSlice(controllerSrc,
                                 from: "private func finalize(delivered:",
                                 to: "private func deliverPushToTalk(")
        let markTakeConsumedBody = sourceSlice(controllerSrc,
                                         from: "func markTakeConsumed()",
                                         to: "var targetLabel:")

        let teardownBody = sourceSlice(controllerSrc,
                                 from: "private func teardownTake(_ scope: TeardownScope) {",
                                 to: "/// Holding right-Option always starts audio capture")
        check("take teardown: only a fully-ended take clears the take-START note snapshot",
              teardownBody.contains("if case .full = scope { notesDelivery.noteTarget = nil }"),
              "Sources/App/DictationController.swift teardownTake()")
        check("take teardown: incidental-audio discard keeps the gesture's note snapshot",
              discardBody.contains("teardownTake(.gestureContinues)"),
              "Sources/App/DictationController.swift discardIncidentalAudio()")
        check("take teardown: Esc cancel uses the shared full teardown",
              cancelBody.contains("teardownTake(.full)"),
              "Sources/App/DictationController.swift cancelTake()")
        check("take teardown: mic-start failure uses the shared full teardown",
              micStartErrorBody.contains("teardownTake(.full)"),
              "Sources/App/DictationController.swift beginRecording() catch")
        check("take teardown: Nothing heard behavior owns one shared full teardown and toast",
              nothingHeardBody.contains("teardownTake(.full)")
                && nothingHeardBody.contains("hud.toast(\"Nothing heard\")"),
              "Sources/App/DictationController.swift finishNothingHeard()")
        check("take teardown: silent finish routes through shared Nothing heard behavior",
              finishBody.contains("finishNothingHeard("),
              "Sources/App/DictationController.swift finish()")
        check("take teardown: non-alphanumeric delivery routes through shared Nothing heard behavior",
              deliverBody.contains("CleanupLogic.transcriptHasLettersOrDigits(rawIn)")
                && deliverBody.contains("finishNothingHeard("),
              "Sources/App/DictationController.swift deliver()")
        check("take teardown: finalized delivery uses the shared full teardown",
              finalizeBody.contains("teardownTake(.full)"),
              "Sources/App/DictationController.swift finalize()")
        check("take teardown: one-shot consumption uses state-only teardown",
              markTakeConsumedBody.contains("teardownTake(.stateOnly)"),
              "Sources/App/DictationController.swift markTakeConsumed()")
    }

    static func probeSpaceLock(check: Check) {
        // --- 13f. spacebar lock toggle + take-end condition (item 6) ----------------------
        // Space (keyCode 49 -> HotkeyMap .lock -> toggleLock) is a PURE toggle between interface-unlocked
        // recording and hands-free locked; it NEVER ends the take. The take ends ONLY when right-Option is
        // released while UNLOCKED. `wasLocked` (the delivery-routing latch: once locked, delivery uses
        // captured-target paste) latches on lock and STAYS latched through a later unlock. The live chords are GUI/tap
        // (live GUI verification); here the pure LockTransition contract is locked — no existing selftest
        // covered this band. Regression pinned: the old .locked case called finish(), so a second spacebar
        // transcribed/delivered/idled the session.
        typealias L = LockTransition

        // 13f-i. space toggles: recording -> lock, locked -> unlock (pure toggle, NOT a finish), idle/finishing
        // -> ignore. The unlock outcome is a return to recording, never an end/transcribe/deliver/idle.
        check("space lock: from recording, space LOCKS (hands-free)",
              L.toggle(.recording) == .lock)
        check("space lock: from locked, space UNLOCKS back to recording (pure toggle, does not finish/deliver/idle)",
              L.toggle(.locked) == .unlock)
        check("space lock: in idle/finishing, space is ignored (no-op, not a toggle)",
              L.toggle(.other) == .ignore)

        // 13f-ii. re-lock: after an unlock the machine is recording again, so a second right-Option+space
        // re-locks (space maps to .lock from recording just as it did the first time).
        check("space lock: after unlock (recording), a second space RE-LOCKS",
              L.toggle(.recording) == .lock)

        // 13f-iii. wasLocked latch: set true on lock and PRESERVED (never cleared) through a later unlock, so a
        // take that was ever locked keeps captured-target paste delivery routing.
        check("space lock: wasLocked latches true on lock",
              L.wasLockedAfterToggle(current: false, phase: .recording) == true)
        check("space lock: wasLocked STAYS true through the unlock (delivery routing unaffected)",
              L.wasLockedAfterToggle(current: true, phase: .locked) == true)

        // 13f-iv. end condition: the take ends ONLY when right-Option is released while UNLOCKED (recording).
        // A release while .locked (hands-free) or in idle/finishing never ends it.
        check("space lock: right-Option release while unlocked (recording) ENDS the take",
              L.rightOptionReleaseEndsTake(.recording))
        check("space lock: right-Option release while LOCKED does NOT end the take (hands-free)",
              !L.rightOptionReleaseEndsTake(.locked))
        check("space lock: right-Option release in idle/finishing does NOT end a take",
              !L.rightOptionReleaseEndsTake(.other))

        // 13f-v. Full release-decision truth table. Arming changes what runs at the real take end,
        // never whether the wakeup release itself ends the take.
        check("space lock release table: recording without arm ENDS the take",
              L.releaseEndsTake(phase: .recording, hasArmedOneShot: false))
        check("space lock release table: recording with arm ENDS the take",
              L.releaseEndsTake(phase: .recording, hasArmedOneShot: true))
        check("space lock release table: locked without arm does NOT end the take",
              !L.releaseEndsTake(phase: .locked, hasArmedOneShot: false))
        check("space lock release table: locked with arm does NOT end the take",
              !L.releaseEndsTake(phase: .locked, hasArmedOneShot: true))
        check("space lock release table: other without arm does NOT end the take",
              !L.releaseEndsTake(phase: .other, hasArmedOneShot: false))
        check("space lock release table: other with arm does NOT end the take",
              !L.releaseEndsTake(phase: .other, hasArmedOneShot: true))

        let lockedArmState = TransformArmState()
        lockedArmState.armOneShot(ArmedOneShot(
            source: .builtIn(.email),
            id: OneShotMode.email.id,
            label: OneShotMode.email.label,
            glyph: "M"))
        let lockedReleaseEndsTake = L.releaseEndsTake(
            phase: .locked,
            hasArmedOneShot: lockedArmState.armedOneShot != nil)
        check("space lock: armed mode SURVIVES locked wakeup release for the real take end",
              !lockedReleaseEndsTake
              && lockedArmState.armedOneShot?.id == OneShotMode.email.id)
    }

}
