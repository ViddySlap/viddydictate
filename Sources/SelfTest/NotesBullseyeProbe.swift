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
        // --- 13b. the take-start snapshot rule (VDLAND2: the note pin is gone) ------------------------
        // Before VDLAND2 this band pinned the PINNED, persistent note target (set/arm/toggle/persist/
        // auto-disarm). All of that is deleted: there is no pinned target, no arm state and no persisted pin.
        // What remains is the snapshot precedence the coordinator still owns — an in-place landing with a
        // take-start snapshot lands in that note, a non-destructive mode keeps its own landing, and a missing or
        // empty id keeps the requested destination. The rows here also pin the one remaining controller
        // call-site shape, the kept OneShot input-source seam, and the bundled/source Web island wire names
        // (the island's pin code is dead but inert; residual R1). The pure delivery rows live in
        // `probeLandingRoute`.
        let coordinatorSrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/App/NotesDeliveryCoordinator.swift", isDirectory: false)
        let coordinatorSrc = (try? String(contentsOf: coordinatorSrcURL, encoding: .utf8)) ?? ""
        let c1ControllerSrc = sourceDictationController
        let inPlaceBody = sourceSlice(c1ControllerSrc,
                                      from: "func landInPlaceTransform(",
                                      to: "// MARK: lifecycle")
        let finalizeBody = sourceSlice(c1ControllerSrc,
                                       from: "func finalize(delivered:",
                                       to: "private func deliverPushToTalk(")
        // Pin both production call sites, not just the pure function. The coordinator must be the only owner of
        // the notes landing ladder so a future caller cannot quietly grow a second precedence ladder. VDLAND2:
        // the raw finalize call hands the pure rule the same take-start snapshot the one-shot call does, with
        // D14's B-off gate in front of it.
        check("bullseye C1 call sites: raw finalize and one-shot in-place call the same coordinator helper",
              finalizeBody.contains("notesDelivery.routeNotesDelivery(")
              && finalizeBody.contains("landingKind: .inPlace")
              && finalizeBody.contains("inputSource: .dictation")
              && finalizeBody.contains("noteTarget: (takeLandAtStart || lateRecovery) ? notesDelivery.noteTarget : nil")
              && inPlaceBody.contains("notesDelivery.routeNotesDelivery(")
              && inPlaceBody.contains("landingKind: .inPlace, inputSource: inputSource, noteTarget: noteTarget"))
        check("bullseye C1 helper owner: routeNotesDelivery takes no per-take note view and feeds the pure rule the snapshot",
              !coordinatorSrc.isEmpty
              && !coordinatorSrc.contains("bullseyeView:")
              && sourceSlice(coordinatorSrc, from: "func routeNotesDelivery(", to: "switch route {")
                  .contains("snapshotNoteId: noteTarget?.noteId"),
              "Sources/App/NotesDeliveryCoordinator.swift routeNotesDelivery()")

        let registrySrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/App/OneShotRegistry.swift", isDirectory: false)
        let registrySrc = (try? String(contentsOf: registrySrcURL, encoding: .utf8)) ?? ""
        check("bullseye C1 input source: one-shot source is latched from takeHasSpeech and threaded to landing",
              registrySrc.contains("let takeHasSpeech = context.takeHasSpeech")
              && registrySrc.contains("inputSource: .dictation")
              && registrySrc.contains("inputSource: .selection")
              && registrySrc.contains("inputSource: inputSource"))

        // The JS half still ships (and is still inert from Swift's side — R1). The bundled island is minified
        // (identifiers mangled), so pin the outbound wire names (string literals survive) in the BUNDLED app.js
        // and the anchor store in the SOURCE module.
        let appJS = NotesProbe.bundledAppJS
        check("bullseye: bundled island ships the setBullseye + insertAtBullseye outbound handlers",
              appJS.contains("setBullseye") && appJS.contains("insertAtBullseye"))

        let targetSrc = sourceDictationTargetJS
        check("bullseye: source module ships the pinned anchor store + follow-edits remap",
              !targetSrc.isEmpty
              && targetSrc.contains("mapBullseyeThroughChanges")
              && targetSrc.contains("setBullseyeAnchor"),
              "Web/StickyNotes/src/dictation-target.js")

        // items 5a/5b (kept): the discard seam itself still exists and is still used elsewhere — VDLAND2
        // removed nothing from the controller's incidental-audio handling, and Option+N / Option+B never
        // discarded the in-flight take.
        let controllerSrc = sourceDictationController
        let discardOccurrences = controllerSrc.components(separatedBy: "discardIncidentalAudio()").count - 1
        check("bullseye 5a/5b: the discard seam still exists + is still used elsewhere (2 calls removed, seam kept)",
              controllerSrc.contains("func discardIncidentalAudio()") && discardOccurrences >= 2,
              "discardIncidentalAudio() occurrences=\(discardOccurrences)")
    }

    static func probeBullseyeMarker(check: Check) {
        // --- 13c. the inline marker contract that still ships in the Web island (VDLAND2 leaves it inert) ----
        // VDLAND2 deleted the Swift arm state and the marker gate (`NotesBullseyeLogic.markerVisible`). The web
        // island still ships its inline marker, its `bullseyeArmed` handler and its CSS; nothing sends to them
        // from Swift any more (residual R1 — deleting the web half is a follow-up). What the probe keeps here is
        // (a) the surviving bundled/source SHIPPING checks for that dead-but-inert island code and (b) the pure
        // CodeMirror position-mapping fixtures the take-start snapshot still relies on. The former pin-only
        // decision rows are deleted with the pin state.

        // L6: pin the character-like mapping contract at a MID-PARAGRAPH anchor. These ASCII fixtures model
        // CodeMirror ChangeSet.mapPos(..., -1), the exact mapping the take-start snapshot store uses. Every case
        // keeps the anchor attached to the LEFT|RIGHT boundary instead of a pixel.
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
        check("note target mapping L6: insert above shifts the mapped mid-paragraph anchor with LEFT|RIGHT",
              insertAbove.anchor == 8 && staysAtBoundary(insertAbove, left: "LEFT", right: "RIGHT"))

        let deleteAbove = applyEdit("xxLEFTRIGHT", anchor: 6, from: 0, to: 2, insert: "")
        check("note target mapping L6: delete above shifts the mapped mid-paragraph anchor back with LEFT|RIGHT",
              deleteAbove.anchor == 4 && staysAtBoundary(deleteAbove, left: "LEFT", right: "RIGHT"))

        let insertAt = applyEdit("LEFTRIGHT", anchor: 4, from: 4, to: 4, insert: "NEW")
        check("note target mapping L6: insert AT the anchor keeps it before the inserted text (assoc -1)",
              insertAt.anchor == 4 && staysAtBoundary(insertAt, left: "LEFT", right: "NEWRIGHT"))

        let deleteSpanning = applyEdit("LEFTmiddleRIGHT", anchor: 7, from: 4, to: 10, insert: "")
        check("note target mapping L6: delete spanning the anchor collapses it to the surviving LEFT|RIGHT boundary",
              deleteSpanning.anchor == 4 && staysAtBoundary(deleteSpanning, left: "LEFT", right: "RIGHT"))

        let multiLineAbove = applyEdit("LEFTRIGHT", anchor: 4, from: 0, to: 0, insert: "one\ntwo\n")
        check("note target mapping L6: multi-line paste above shifts the anchor by the whole paste",
              multiLineAbove.anchor == 12
              && staysAtBoundary(multiLineAbove, left: "LEFT", right: "RIGHT"))

        let insertAfter = applyEdit("LEFTRIGHT", anchor: 4, from: 9, to: 9, insert: " tail")
        let deleteAfter = applyEdit("LEFTRIGHTxx", anchor: 4, from: 9, to: 11, insert: "")
        check("note target mapping L6: inserts and deletes AFTER the mid-paragraph anchor leave it untouched",
              insertAfter.anchor == 4 && deleteAfter.anchor == 4
              && staysAtBoundary(insertAfter, left: "LEFT", right: "RIGHT")
              && staysAtBoundary(deleteAfter, left: "LEFT", right: "RIGHT"))

        // The armed-state push is still a wired outbound bridge message (Swift enum ++ JS parity is enforced in
        // probeBridgeParity). Nothing in Swift sends it after VDLAND2; the case stays for the fenced bridge.
        check("bullseye marker: bullseyeArmed is a wired outbound bridge message (Swift enum)",
              NotesOutbound.allCases.contains(.bullseyeArmed))

        // The JS + CSS half still ships. The bundled island is minified (identifiers mangled), so pin the
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

        // item 5c (inline glyph trails one dictation), kept as a Web-shipping check: the island's
        // insertAtBullseye handler still re-pushes the marker (clear-then-sync) as the last word after render().
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

    /// --- 13d. the removed reveal chord (VDLAND2 D7) ------------------------------------------------
    /// The `bullseyeReveal` command (Option+Shift+N) is gone from `HotkeyCommand`. Because no chord claims
    /// Shift+N any more, the monitor's existing shift fallback makes right-Option+Shift+N fire plain
    /// right-Option+N (open/focus the sticky notes). The live window/tab/scroll walk was deleted with the chord;
    /// what remains here is the web island's (now unreachable) reveal code — kept by D11/R1 as a shipping check —
    /// and the pre-shift KeySpec decode that a saved map still relies on.
    static func probeBullseyeReveal(freshRoot: () -> URL, check: Check) {
        _ = freshRoot

        // A saved map written BEFORE the shift qualifier existed carries no `shift` key. Decoding must default
        // it to false rather than throwing the whole map away (which would silently reset every user rebind).
        let legacyJSON = Data(#"{"isModifier":false,"code":45,"label":"N"}"#.utf8)
        let legacy = try? JSONDecoder().decode(KeySpec.self, from: legacyJSON)
        check("bullseye reveal: a pre-shift saved KeySpec decodes as an UNSHIFTED chord, not a decode failure",
              legacy != nil && legacy?.shift == false && legacy?.code == 45)

        // The wire + the JS half still ship (R1: nothing sends the message after VDLAND2).
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

        // 13d-iv-b. the reveal's attention cue (VDPF L7), kept as a Web-shipping check.
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
        // --- 13e. take controls: Option+Esc-cancel + Option+Z notes cross-focus undo (notes-bullseye BT5) ---------
        // Option+Esc ABORTS the in-progress take (record/processing) — nothing lands, the target selection is left
        // untouched, the BT4 replace highlight is cleared. Option+Z reverts the LAST ViddyDictate-delivered edit
        // IN A NOTE even when focus moved away (reach-back by note id — a controlled surface), restoring any
        // overwritten text; the existing foreign-app tier is left as-is. The chord + real reach-back are GUI/tap
        // (live GUI verification); here the PURE abort gate, undo routing, and the delivery/undo round-trip are
        // locked, plus a bundled-island + source shipping check that the JS half actually ships.
        typealias U = NotesUndoLogic

        // 13e-i. Option+Esc aborts ONLY while a take is active (recording / locked / final processing) AND Option
        // is held AND the key is Esc; otherwise Esc is a normal key that passes through to the focused app.
        check("take controls: plain Esc no longer aborts a take",
              !U.escapeAborts(keyCode: 53, optionHeld: false, isTakeActive: true))
        check("take controls: Option+Esc aborts while a take is active",
              U.escapeAborts(keyCode: 53, optionHeld: true, isTakeActive: true))
        check("take controls: Option+Esc passes through when no take is active",
              !U.escapeAborts(keyCode: 53, optionHeld: true, isTakeActive: false))

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
                                       to: "private func finishNothingHeard(")
        let micStartErrorBody = sourceSlice(beginRecordingBody,
                                      from: "} catch {",
                                      to: "state = .recording")
        let finishBody = sourceSlice(controllerSrc,
                               from: "private func finish() {",
                               to: "func deliver(text rawText:")
        let nothingHeardBody = sourceSlice(controllerSrc,
                                from: "private func finishNothingHeard(",
                                to: "private func finish() {")
        let deliverBody = sourceSlice(controllerSrc,
                                from: "func deliver(text rawText:",
                                to: "private func landCleanupRetry(")
        let finalizeBody = sourceSlice(controllerSrc,
                                 from: "func finalize(delivered:",
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

        probeLandingRoute(check: check)
    }

    /// --- 13g. VDLAND1 + VDLAND2: the landing rule -----------------------------------------------
    /// ONE setting decides where a take lands: `Settings.bullseyeLandAtStart`, copied at take START into
    /// `takeLandAtStart`. ON lands in the field focused at take start (or in the sticky note the take started
    /// in, through its take-start snapshot); OFF lands at live focus when the take ends. The spacebar lock
    /// decides nothing. VDLAND2 removed the pinned note: `LandingRoute` carries only the route, the marker
    /// direction and the toast, and the CONTROLLER decides whether a take-start snapshot exists for this take
    /// (B ON, or a late-recovery retry, which keeps its base inputs). Every row below either exercises the pure
    /// model or reads a real function body out of the tree.
    static func probeLandingRoute(check: Check) {
        let dictSource = landStripped(landSource("Sources/App/DictationController.swift"))
        let lockStripped = landStripped(landSource("Sources/App/LockTransition.swift"))
        let coordinatorSource = landStripped(landSource("Sources/App/NotesDeliveryCoordinator.swift"))
        let registrySource = landStripped(landSource("Sources/App/NotesWindowRegistry.swift"))
        let appSource = landStripped(landSource("Sources/App/AppDelegate.swift"))
        let bullseyeSource = landStripped(landSource("Sources/App/NotesWindowController+Bullseye.swift"))
        let windowSource = landStripped(landSource("Sources/App/NotesWindowController.swift"))
        let queueSource = landStripped(landSource("Sources/App/NotesOutboundQueue.swift"))
        let notesBullseyeSource = landStripped(landSource("Sources/App/NotesBullseye.swift"))
        let hotkeyMapSource = landStripped(landSource("Sources/App/HotkeyMap.swift"))
        let hotkeysSettingsSource = landStripped(landSource("Sources/App/HotkeysSettingsView.swift"))
        let featureTourSource = landStripped(landSource("Sources/App/FeatureTour.swift"))

        let finalizeBody = landBody(dictSource, "func finalize(")
        let beginBody = landBody(dictSource, "private func beginRecording()")
        let toggleBody = landBody(dictSource, "private func toggleBullseye()")
        let notesBody = landBody(dictSource, "private func notes()")
        let refreshBody = landBody(dictSource, "private func refreshBullseyeIndicator()")

        // 13g-i. the route table: OFF always lands live, ON lands pinned (with a captured field) or pinned with
        // no target to land in.
        check("land-route-off-is-live: with the setting OFF a take lands at live focus, with a target or without",
              LandingRoute.route(bullseyeOn: false, hasTarget: true) == .live
              && LandingRoute.route(bullseyeOn: false, hasTarget: false) == .live)
        check("land-route-on-target-pinned: with the setting ON and a captured start field the take lands pinned there",
              LandingRoute.route(bullseyeOn: true, hasTarget: true) == .pinned)
        check("land-route-on-no-target: with the setting ON and no captured start field the take lands pinned-no-target",
              LandingRoute.route(bullseyeOn: true, hasTarget: false) == .pinnedNoTarget)

        // 13g-ii. the lock is not an input: the pure route takes exactly the setting and a target, and the real
        // `finalize` body never mentions the lock latch.
        let routeParams = NotesProbe.sourceSlice(lockStripped, from: "static func route(",
                                                 to: ") -> Route")
        check("land-lock-not-an-input: LandingRoute.route takes only (bullseyeOn, hasTarget) and finalize never reads wasLocked",
              lockStripped.contains("static func route(bullseyeOn: Bool, hasTarget: Bool) -> Route")
              && routeParams.components(separatedBy: ":").count - 1 == 2
              && !finalizeBody.isEmpty
              && !finalizeBody.contains("wasLocked"))

        // 13g-iii. the paste-target marker: live focus when the setting is OFF, the captured field when it is ON.
        check("land-marker-follows-live-off: with the setting OFF the marker follows live focus",
              LandingRoute.markerFollowsLive(bullseyeOn: false) == true)
        check("land-marker-pinned-on: with the setting ON the marker does NOT follow live focus",
              LandingRoute.markerFollowsLive(bullseyeOn: true) == false)

        // 13g-vi. the info-pill glyph shows exactly when the setting is ON.
        check("land-glyph-follows-setting: the info-pill bullseye glyph reads Settings.bullseyeLandAtStart",
              refreshBody.contains("hud.setBullseyeArmed(Settings.bullseyeLandAtStart)"))

        // 13g-x. the toggle toast: bare copy outside a take, plus the next-dictation suffix inside one.
        check("land-toggle-toast-next-dictation: the B toast is bare outside a take and says \"for the next dictation\" inside one",
              LandingRoute.toggleToast(on: true, takeInFlight: false) == NotesBullseyeLogic.armedToast
              && LandingRoute.toggleToast(on: false, takeInFlight: false) == NotesBullseyeLogic.disarmedToast
              && LandingRoute.toggleToast(on: true, takeInFlight: true)
                  == NotesBullseyeLogic.armedToast + " for the next dictation"
              && LandingRoute.toggleToast(on: false, takeInFlight: true)
                  == NotesBullseyeLogic.disarmedToast + " for the next dictation"
              && toggleBody.contains("LandingRoute.toggleToast(on: Settings.bullseyeLandAtStart, takeInFlight: state != .idle)")
              && !toggleBody.contains("noneSetToast"))

        // 13g-xxv (kept: the snapshot wins; the armed-note half is gone with the pin).
        check("land-note-routes-before-landing: finalize asks the notes router before it consults the landing route",
              NotesProbe.orderedBefore("notesDelivery.routeNotesDelivery(", "LandingRoute.route(",
                                       in: finalizeBody))

        // VDLAND2 row 1: the take-start snapshot wins for an in-place landing, dictation or selection.
        check("land2-delivery-snapshot-wins",
              NotesBullseyeLogic.delivery(snapshotNoteId: "n1", landingKind: .inPlace, inputSource: .dictation)
                  == .snapshot(noteId: "n1")
              && NotesBullseyeLogic.delivery(snapshotNoteId: "n1", landingKind: .inPlace, inputSource: .selection)
                  == .snapshot(noteId: "n1"))

        // VDLAND2 row 2: a non-destructive landing always keeps its requested destination.
        check("land2-delivery-nondestructive-requested",
              NotesBullseyeLogic.delivery(snapshotNoteId: "n1", landingKind: .nonDestructive, inputSource: .dictation)
                  == .requested
              && NotesBullseyeLogic.delivery(snapshotNoteId: "n1", landingKind: .nonDestructive, inputSource: .selection)
                  == .requested)

        // VDLAND2 row 3: nil and empty snapshot ids keep the requested destination.
        check("land2-delivery-empty-id-requested",
              NotesBullseyeLogic.delivery(snapshotNoteId: nil, landingKind: .inPlace, inputSource: .dictation)
                  == .requested
              && NotesBullseyeLogic.delivery(snapshotNoteId: "", landingKind: .inPlace, inputSource: .dictation)
                  == .requested)

        // VDLAND2 row 4: the pin type and its persisted state class are gone from NotesBullseye.swift.
        check("land2-pin-state-gone",
              !notesBullseyeSource.contains("struct NotesBullseye")
              && !notesBullseyeSource.contains("class NotesBullseyeState")
              && !notesBullseyeSource.contains("case bullseye("))

        // VDLAND2 row 5: finalize routes only through the notes router and then LandingRoute.route, with the
        // two D14 expressions and no pin/lock state.
        check("land2-finalize-setting-only",
              finalizeBody.contains("LandingRoute.route(bullseyeOn: takeLandAtStart, hasTarget: target != nil)")
              && finalizeBody.contains("noteTarget: (takeLandAtStart || lateRecovery) ? notesDelivery.noteTarget : nil")
              && finalizeBody.contains("lateRecovery ? false : (takeLandAtStart ? (targetWasNotesWindow || (notesWindowCurrentlyKey && (target?.pid == getpid()))) : notesWindowCurrentlyKey)")
              && !finalizeBody.contains("takeAnchor")
              && !finalizeBody.contains("bullseyeView")
              && !finalizeBody.contains("wasLocked")
              && NotesProbe.orderedBefore("notesDelivery.routeNotesDelivery(", "if lateRecovery {", in: finalizeBody))

        // VDLAND2 row 6: beginRecording freezes only the setting; no anchor, no migration, no marker gate.
        check("land2-begin-recording-no-pin",
              NotesProbe.countOccurrences(of: "takeLandAtStart = Settings.bullseyeLandAtStart", in: beginBody) == 1
              && !beginBody.contains("takeAnchor")
              && !beginBody.contains("migrateBullseyeOnce")
              && !beginBody.contains("NotesBullseye")
              && !beginBody.contains("markerShown"))

        // VDLAND2 row 7: Option+B flips the setting and toasts; it touches no note state.
        check("land2-b-flips-setting-only",
              toggleBody.contains("Settings.bullseyeLandAtStart = !Settings.bullseyeLandAtStart")
              && toggleBody.contains("LandingRoute.toggleToast(on: Settings.bullseyeLandAtStart, takeInFlight: state != .idle)")
              && !toggleBody.contains("notesDelivery")
              && !toggleBody.contains("NotesBullseye")
              && !toggleBody.contains("broadcast"))

        // VDLAND2 row 8: Option+N only opens/focuses the sticky notes.
        check("land2-notes-chord-opens-only",
              notesBody.contains("callbacks.onOpenNotes()")
              && !notesBody.contains("Bullseye")
              && !notesBody.contains("Settings."))

        // VDLAND2 row 9: the reveal chord is gone from every place D7 named, and the enum shrank to 14.
        check("land2-reveal-chord-removed",
              HotkeyCommand.allCases.count == 14
              && HotkeyCommand(rawValue: "bullseyeReveal") == nil
              && !hotkeyMapSource.contains("bullseyeReveal")
              && !hotkeysSettingsSource.contains("bullseyeReveal")
              && !featureTourSource.contains("bullseyeReveal")
              && !dictSource.contains("bullseyeReveal"))

        // VDLAND2 row 10 (M3): a saved map that still holds the stale reveal key loads with every other
        // binding intact. There is no zero-argument HotkeyMap initializer, so build the map from defaults and
        // write it through an isolated suite; `hSwapDoneKey` keeps the one-time H swap out of the way.
        let row10Suite = "vd-land2-row10-" + UUID().uuidString
        let row10Defaults = UserDefaults(suiteName: row10Suite)!
        row10Defaults.removePersistentDomain(forName: row10Suite)
        defer { row10Defaults.removePersistentDomain(forName: row10Suite) }
        var saved = HotkeyMap.defaults()
        saved.bindings["bullseyeReveal"] = KeySpec.regular(keyCode: 45, label: "\u{21E7}N", shift: true)
        saved.save(row10Defaults)
        row10Defaults.set(true, forKey: HotkeyMap.hSwapDoneKey)
        let loaded = HotkeyMap.load(row10Defaults)
        check("land2-stale-reveal-key-decodes",
              HotkeyCommand.allCases.allSatisfy { loaded.key(for: $0) == saved.key(for: $0) }
              && loaded.wakeup == saved.wakeup)

        // VDLAND2 row 11: with no chord claiming Shift+N, a Shift-held N resolves to plain Notes through the
        // monitor's real `resolveChord` (driven exactly like the VDLAND1 H-chord rows), and History's H is the
        // only other default chord carrying a shift qualifier.
        func land2ChordFires(keyCode: Int64, shift: Bool) -> HotkeyCommand? {
            var fired: HotkeyCommand?
            let monitor = HotkeyMonitor()
            monitor.onCommand = { fired = $0 }
            let latch = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            latch.flags = CGEventFlags(rawValue: 0x40)
            _ = monitor.selfTestHandle(type: .flagsChanged, event: latch)
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)!
            if shift { ev.flags = .maskShift }
            _ = monitor.selfTestHandle(type: .keyDown, event: ev)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return fired
        }
        check("land2-shift-n-falls-back-to-notes",
              land2ChordFires(keyCode: 45, shift: true) == .notes
              && land2ChordFires(keyCode: 45, shift: false) == .notes
              && HotkeyCommand.allCases.filter { HotkeyMap.defaults().key(for: $0).shift } == [.history])

        // VDLAND2 row 12: launch clears exactly the two obsolete upgrade keys and never the landing setting.
        let appBody = landBody(appSource, "func applicationDidFinishLaunching(")
        check("land2-upgrade-clears-pin-keys",
              appBody.contains("UserDefaults.standard.removeObject(forKey: \"notesBullseye\")")
              && appBody.contains("UserDefaults.standard.removeObject(forKey: \"bullseyeLandMigrated\")")
              && !appBody.contains("removeObject(forKey: \"bullseyeLandAtStart\")"))

        // VDLAND2 row 13: the replace tint is gated on the landing setting, not on a pin.
        let armReplaceBody = landBody(coordinatorSource, "func armReplaceHighlightForTake()")
        let beginArmGate = beginBody.range(
            of: #"if Settings\.bullseyeLandAtStart \{\s*notesDelivery\.armReplaceHighlightForTake\(\)"#,
            options: .regularExpression) != nil
        check("land2-replace-highlight-ungated",
              !armReplaceBody.isEmpty
              && !armReplaceBody.contains("armed")
              && beginArmGate)

        // VDLAND2 row 14: Swift never sends any of the four pin bridge messages.
        let islandSources = [registrySource, bullseyeSource, windowSource, queueSource, appSource]
        let islandPushes = ["call(.setBullseye", "call(.insertAtBullseye",
                            "call(.revealBullseye", "call(.bullseyeArmed"]
        check("land2-no-island-push",
              islandSources.allSatisfy { source in
                  islandPushes.allSatisfy { !source.contains($0) }
              })

        // VDLAND2 row 17: the two D14 expressions are exact, and the late-recovery branch keeps its base body.
        let recoverySlice = NotesProbe.sourceSlice(finalizeBody, from: "if lateRecovery {",
                                                   to: "switch LandingRoute.route(")
        check("land2-off-follows-end-focus",
              NotesProbe.countOccurrences(
                  of: "noteTarget: (takeLandAtStart || lateRecovery) ? notesDelivery.noteTarget : nil",
                  in: finalizeBody) == 1
              && NotesProbe.countOccurrences(
                  of: "lateRecovery ? false : (takeLandAtStart ? (targetWasNotesWindow || (notesWindowCurrentlyKey && (target?.pid == getpid()))) : notesWindowCurrentlyKey)",
                  in: finalizeBody) == 1
              && !recoverySlice.isEmpty
              && recoverySlice.contains("pasteIntoCapturedTargetWithoutActivation")
              && recoverySlice.contains("return nil")
              && NotesProbe.orderedBefore("notesDelivery.routeNotesDelivery(", "if lateRecovery {", in: finalizeBody))

        // 13g-xxvii. the one-time H swap: the old pair is swapped once, and a deliberate re-save is respected.
        let plainHKey = KeySpec.regular(keyCode: 4, label: "H")
        let shiftHKey = KeySpec.regular(keyCode: 4, label: "⇧H", shift: true)
        let swapSuiteName = "test.viddydictate.selftest.land-swap-once"
        if let swapDefaults = UserDefaults(suiteName: swapSuiteName) {
            swapDefaults.removePersistentDomain(forName: swapSuiteName)
            defer { swapDefaults.removePersistentDomain(forName: swapSuiteName) }
            var oldPair = HotkeyMap.defaults()
            oldPair.bindings[HotkeyCommand.history.rawValue] = plainHKey
            oldPair.bindings[HotkeyCommand.recentDictations.rawValue] = shiftHKey
            oldPair.save(swapDefaults)
            let firstLoad = HotkeyMap.load(swapDefaults)
            // The swap already ran; the user now re-saves the old pair ON PURPOSE and must keep it.
            var keptPair = HotkeyMap.defaults()
            keptPair.bindings[HotkeyCommand.history.rawValue] = plainHKey
            keptPair.bindings[HotkeyCommand.recentDictations.rawValue] = shiftHKey
            keptPair.save(swapDefaults)
            let secondLoad = HotkeyMap.load(swapDefaults)
            check("land-swap-once-old-defaults: a saved old pair is swapped once, then a deliberate re-save survives the next load",
                  firstLoad.key(for: .history) == shiftHKey
                  && firstLoad.key(for: .recentDictations) == plainHKey
                  && secondLoad.key(for: .history) == plainHKey
                  && secondLoad.key(for: .recentDictations) == shiftHKey)
        } else {
            check("land swap: probe defaults suite is creatable", false)
        }

        // 13g-xxviii. a custom H binding is a real choice and is never swapped.
        let customSuiteName = "test.viddydictate.selftest.land-swap-custom"
        if let customDefaults = UserDefaults(suiteName: customSuiteName) {
            customDefaults.removePersistentDomain(forName: customSuiteName)
            defer { customDefaults.removePersistentDomain(forName: customSuiteName) }
            var customHistory = HotkeyMap.defaults()
            customHistory.bindings[HotkeyCommand.history.rawValue] = KeySpec.regular(keyCode: 100, label: "F8")
            customHistory.bindings[HotkeyCommand.recentDictations.rawValue] = plainHKey
            customHistory.save(customDefaults)
            let loadedCustomHistory = HotkeyMap.load(customDefaults)
            var customRecent = HotkeyMap.defaults()
            customRecent.bindings[HotkeyCommand.recentDictations.rawValue] = KeySpec.regular(keyCode: 20, label: "T")
            customRecent.save(customDefaults)
            let loadedCustomRecent = HotkeyMap.load(customDefaults)
            check("land-swap-leaves-custom: a saved map with a custom History or Recent binding is returned unchanged",
                  loadedCustomHistory.key(for: .history) == KeySpec.regular(keyCode: 100, label: "F8")
                  && loadedCustomHistory.key(for: .recentDictations) == plainHKey
                  && loadedCustomRecent.key(for: .history) == shiftHKey
                  && loadedCustomRecent.key(for: .recentDictations) == KeySpec.regular(keyCode: 20, label: "T"))
        } else {
            check("land swap: probe custom defaults suite is creatable", false)
        }

        // 13g-xxix. a legacy saved map with no Recent entry at all is treated as the old default pair.
        let legacySuiteName = "test.viddydictate.selftest.land-swap-legacy"
        if let legacyDefaults = UserDefaults(suiteName: legacySuiteName) {
            legacyDefaults.removePersistentDomain(forName: legacySuiteName)
            defer { legacyDefaults.removePersistentDomain(forName: legacySuiteName) }
            var legacyMap = HotkeyMap.defaults()
            legacyMap.bindings[HotkeyCommand.history.rawValue] = plainHKey
            legacyMap.bindings.removeValue(forKey: HotkeyCommand.recentDictations.rawValue)
            legacyMap.save(legacyDefaults)
            let loadedLegacy = HotkeyMap.load(legacyDefaults)
            let code4Commands = HotkeyCommand.allCases.filter {
                let key = loadedLegacy.key(for: $0)
                return !key.isModifier && key.code == 4
            }
            check("land-swap-legacy-missing-recent: a legacy map with plain H and no Recent loads swapped, with exactly two commands on code 4",
                  loadedLegacy.key(for: .history) == shiftHKey
                  && loadedLegacy.key(for: .recentDictations) == plainHKey
                  && code4Commands.count == 2)
        } else {
            check("land swap: probe legacy defaults suite is creatable", false)
        }

        // 13g-xxx. the back-fill never puts two commands on one chord: an older map that moved Dictionary onto
        // plain H gets Recent on Shift+H, not on plain H.
        let collisionSuiteName = "test.viddydictate.selftest.land-backfill-collision"
        if let collisionDefaults = UserDefaults(suiteName: collisionSuiteName) {
            collisionDefaults.removePersistentDomain(forName: collisionSuiteName)
            defer { collisionDefaults.removePersistentDomain(forName: collisionSuiteName) }
            var collisionMap = HotkeyMap.defaults()
            collisionMap.bindings[HotkeyCommand.history.rawValue] = KeySpec.regular(keyCode: 100, label: "F8")
            collisionMap.bindings[HotkeyCommand.dictionary.rawValue] = plainHKey
            collisionMap.bindings.removeValue(forKey: HotkeyCommand.recentDictations.rawValue)
            collisionMap.save(collisionDefaults)
            let loadedCollision = HotkeyMap.load(collisionDefaults)
            let plainHCommands = HotkeyCommand.allCases.filter { loadedCollision.key(for: $0) == plainHKey }
            check("land-swap-no-backfill-collision: a back-filled Recent avoids plain H when another command already holds it",
                  loadedCollision.key(for: .recentDictations) == shiftHKey
                  && loadedCollision.key(for: .history) == KeySpec.regular(keyCode: 100, label: "F8")
                  && plainHCommands == [.dictionary])
        } else {
            check("land swap: probe collision defaults suite is creatable", false)
        }
    }

    /// Read a source file from the tree root (the self-test must run with the repository as its CWD).
    private static func landSource(_ path: String) -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return (try? String(contentsOf: root.appendingPathComponent(path, isDirectory: false),
                            encoding: .utf8)) ?? ""
    }

    /// Strip `//` and `/* */` comments, leaving string literals intact, so a body check cannot be satisfied by
    /// or defeated by prose (the `//` inside a URL in a string literal survives).
    private static func landStripped(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        var inBlock = false
        var inLine = false
        var inString = false
        while index < text.endIndex {
            let ch = text[index]
            let next = text.index(after: index)
            if inLine {
                if ch == "\n" { inLine = false; out.append(ch) }
                index = next
                continue
            }
            if inBlock {
                if ch == "*" && next < text.endIndex && text[next] == "/" {
                    inBlock = false
                    index = text.index(after: next)
                    continue
                }
                if ch == "\n" { out.append(ch) }
                index = next
                continue
            }
            if inString {
                out.append(ch)
                if ch == "\\", next < text.endIndex {
                    out.append(text[next])
                    index = text.index(after: next)
                    continue
                }
                if ch == "\"" { inString = false }
                index = next
                continue
            }
            if ch == "/", next < text.endIndex, text[next] == "/" {
                inLine = true
                index = text.index(after: next)
                continue
            }
            if ch == "/", next < text.endIndex, text[next] == "*" {
                inBlock = true
                index = text.index(after: next)
                continue
            }
            if ch == "\"" { inString = true }
            out.append(ch)
            index = next
        }
        return out
    }

    /// The text of the declaration starting at `signature` through its closing brace at the type-member
    /// indentation (4 spaces), which is how every function these rows inspect is laid out.
    private static func landBody(_ source: String, _ signature: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        guard let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
            return String(source[start.lowerBound...])
        }
        return String(source[start.lowerBound..<end.upperBound])
    }

}
