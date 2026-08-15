import AppKit

/// THE TYPED OUTPUT SLOT for Sticky Skills (locked decision 4).
///
/// Shape, and why it is this shape
/// -------------------------------
/// This mirrors the `CustomLanding -> OneShotLanding` idiom already in the codebase: a persisted, UI-facing
/// enum (`StickySkillOutputMode`, declared beside the descriptor in `StickySkill.swift`) paired with ONE
/// switch that resolves it to the imperative half. `OneShotRegistry.entry(for:)` is the same move for
/// one-shot modes - the descriptor is data, the engine is one, and adding a mode is a row in the table
/// rather than a new method on the run path.
///
/// So adding a FOURTH destination later (the user's "file it where it belongs", explicitly v2) is exactly:
///   1. one `StickySkillOutputMode` case,
///   2. one type conforming to `StickySkillOutputHandler`,
///   3. one arm in `StickySkillOutputRegistry.handler(for:)`.
/// Nothing on the run path changes, because the run path only ever asks the registry for a handler and
/// hands it a `StickySkillOutputRequest`. The three v1 landings below are the proof that the seam is wide
/// enough: they create a note, mutate an existing one, and touch no note at all, and none of them needed a
/// special case anywhere else.

// MARK: - What a landing is given

/// The finished result of a skill run, ready to place. `output` is FINAL text: the vision notice and the
/// provider provenance line have already been applied by the caller, so a handler never re-derives them.
struct StickySkillOutputRequest: Equatable {
    /// The note the skill ran OVER. Read-only for every v1 handler except `.appendToSource`.
    let sourceNoteId: String
    /// The title a note-creating landing should use (already paired to the source and truncated).
    let outputTitle: String
    /// The text to land.
    let output: String
}

/// What a landing actually did. The run itself has already succeeded by the time a handler is called, so
/// `.failed` here means the LANDING failed (a missing or read-only source note, a refused clipboard write).
enum StickySkillOutputLanding: Equatable {
    /// A new sticky note was created and persisted. The caller renders it into the live island.
    case createdNote(id: String, title: String, body: String)
    /// The source note was appended to. `renderedLive` is false when no live island took the append and the
    /// store write is what stands, so the caller can refresh membership exactly as the created-render miss
    /// path already does. `chars` counts the appended text itself, never a derived body: on the live path
    /// only the island knows the resulting document, and reporting a Swift-side guess at it would be the
    /// same stale read this handler exists to avoid.
    case appendedToSource(id: String, chars: Int, renderedLive: Bool)
    /// The result went to the clipboard and no note changed.
    case copiedToClipboard(chars: Int)
    case failed(userMessage: String, detail: String)
}

/// The ONLY surfaces a handler is allowed to touch. Injected rather than reached for, so the headless
/// selftest drives every handler through spies and can never write into the user's real notes directory, their
/// live web island, or his clipboard.
struct StickySkillOutputSeam {
    /// Note persistence. In production the shared store; in tests a scratch-rooted one.
    var store: StickyNotesStore

    /// Append `text` onto the END of note `id`'s LIVE CodeMirror document, returning whether a live island
    /// took it (`.delivered`) or there was none (`.persistedOnly`).
    ///
    /// THIS IS THE WHOLE SAFETY PROPERTY OF `.appendToSource`. See `AppendToSourceOutputHandler`. The
    /// default is a no-op that reports `.persistedOnly`, matching `NotesControlServer`'s own render-sink
    /// default; `NotesWindowController` wires the real one (pinned structurally in the selftest, because an
    /// unwired seam beside a LIVE island is precisely the lost-update this design exists to prevent).
    var appendToLiveNote: (_ noteId: String, _ text: String) -> NotesRenderOutcome = { _, _ in .persistedOnly }

    /// Put `text` on the general pasteboard. Returns whether the write was accepted. Injected so no test
    /// ever clobbers the user's real clipboard.
    var copyToClipboard: (String) -> Bool = { text in
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    init(store: StickyNotesStore) { self.store = store }
}

// MARK: - The protocol

protocol StickySkillOutputHandler {
    /// The mode this handler serves. Declared on the handler as well as in the registry switch so the two
    /// can never drift apart silently - the selftest asserts the round trip for every case, which is what
    /// catches a mis-copied switch arm (the single most likely bug when destination #4 lands).
    var mode: StickySkillOutputMode { get }

    func land(_ request: StickySkillOutputRequest,
              through seam: StickySkillOutputSeam) -> StickySkillOutputLanding
}

// MARK: - The one switch

enum StickySkillOutputRegistry {
    /// THE table. One arm per destination; the run path never branches on the mode itself.
    static func handler(for mode: StickySkillOutputMode) -> StickySkillOutputHandler {
        switch mode {
        case .newNote:         return NewNoteOutputHandler()
        case .appendToSource:  return AppendToSourceOutputHandler()
        case .copyToClipboard: return CopyToClipboardOutputHandler()
        }
    }
}

// MARK: - New note

/// The default landing, and the one Note to Handoff has always used. This is the exact sequence that used
/// to be inline in the run path (now `StickySkillCoordinator.run`) - mint id, save body, apply the title,
/// then VERIFY the note actually materialized before copying every source attachment and reporting success.
/// The read-back guard is load-bearing: a failed disk write is otherwise indistinguishable from a successful
/// one, and the user would be told a note exists that does not. The attachment copy deliberately follows it,
/// because the sidecar destination must never precede the note it belongs to.
struct NewNoteOutputHandler: StickySkillOutputHandler {
    let mode = StickySkillOutputMode.newNote

    func land(_ request: StickySkillOutputRequest,
              through seam: StickySkillOutputSeam) -> StickySkillOutputLanding {
        let id = StickyNotesStore.newNoteId()
        seam.store.saveOpenNote(id: id, body: request.output)
        let title = seam.store.renameNote(id: id, title: request.outputTitle) ?? request.outputTitle
        guard seam.store.openNotes().contains(where: { $0.id == id && $0.body == request.output }) else {
            return .failed(userMessage: "Could not save the handoff note",
                           detail: "store did not materialize \(id)")
        }
        seam.store.copyAttachments(fromNoteId: request.sourceNoteId, toNoteId: id)
        return .createdNote(id: id, title: title, body: request.output)
    }
}

// MARK: - Append to the source note (THE DANGEROUS ONE)

/// Append the result to the note the skill ran over.
///
/// WHY THIS IS THE DANGEROUS ONE, AND WHAT MAKES IT SAFE
/// ----------------------------------------------------
/// The target note is very often OPEN in CodeMirror at the moment a skill finishes - the user invoked the
/// skill from that note's own tab menu, and the run can take a minute or more. Two ways to get this wrong,
/// both of which look like they work:
///
///  1. Write the `.md` behind the editor's back (`store.saveOpenNote(id:body: diskBody + output)`). The
///     `.md` files are a one-way, app-owned mirror: the live island holds the authoritative buffer and
///     re-persists it on its next save, so the append is silently clobbered - or, worse, the user's typing
///     since the last 180 ms debounce is clobbered by ours. `NotesControlServer`'s own header says this in
///     as many words, and the reason the loopback endpoint exists at all.
///  2. Compute the whole new body in Swift and push it through `externalSetBody`. That is the existing
///     update-`append` render path, and for a SKILL landing it is wrong twice over. It replaces the live
///     document wholesale from a body read off DISK, so anything typed between the read and the push is
///     gone; and `externalSetBody` -> `replaceEditorForTab` -> `replaceEditorDoc` replaces the whole
///     `EditorState`, which by construction mints a fresh `history()` and DESTROYS the note's undo stack.
///     That undo stack is what chain 1 just finished making per-note; an append must not spend it.
///
/// So the append goes through the seam the app already uses to mutate an open note: a real CodeMirror
/// transaction inserted at the END of the LIVE document (`appendToEditorEnd` in `Web/StickyNotes/src/
/// editor.js`), after which JS re-persists the exact resulting body via the ordinary save round-trip - JS
/// as authoritative last writer, identical to how dictation lands. A lost update is then structurally
/// impossible rather than merely unlikely: Swift never computes or writes the body at all while an island
/// is live.
///
/// The store write happens ONLY when no live island took the render, which is the one case where disk
/// genuinely is the truth. Both paths produce byte-identical text because both use the same join rule
/// (`StickySkillAppendLogic` / its JS mirror `appendRange`).
///
/// A note that cannot be edited (a read-only or fail-closed file-backed tab) is refused up front rather
/// than half-attempted: the JS side would refuse it too (`requireEditable`), and the store's file-backed
/// engine would refuse the write, but neither refusal is visible to the caller - it would report success
/// on a note that never changed.
struct AppendToSourceOutputHandler: StickySkillOutputHandler {
    let mode = StickySkillOutputMode.appendToSource

    func land(_ request: StickySkillOutputRequest,
              through seam: StickySkillOutputSeam) -> StickySkillOutputLanding {
        guard let note = seam.store.openNotes().first(where: { $0.id == request.sourceNoteId }) else {
            return .failed(userMessage: "The source note is no longer open, so there was nothing to append to",
                           detail: "source note \(request.sourceNoteId) is not open")
        }
        guard note.canEdit else {
            return .failed(userMessage: "The source note is read-only, so nothing was appended",
                           detail: "note \(request.sourceNoteId) is not editable")
        }

        // Hand the island the ADDITION, never a whole body: it applies the same join rule against its own
        // live document (which is the only correct input) and re-persists the exact result itself.
        switch seam.appendToLiveNote(request.sourceNoteId, request.output) {
        case .delivered:
            return .appendedToSource(id: request.sourceNoteId,
                                     chars: request.output.count, renderedLive: true)
        case .persistedOnly:
            // No live island holds this note, so no editor can be holding a newer buffer and disk IS the
            // truth. Only here does Swift write the body.
            let joined = StickySkillAppendLogic.joined(existing: note.body, addition: request.output)
            seam.store.saveOpenNote(id: request.sourceNoteId, body: joined)
            guard seam.store.openNotes().contains(where: {
                $0.id == request.sourceNoteId && $0.body == joined
            }) else {
                return .failed(userMessage: "Could not append to the source note",
                               detail: "store did not persist the append to \(request.sourceNoteId)")
            }
            return .appendedToSource(id: request.sourceNoteId,
                                     chars: request.output.count, renderedLive: false)
        }
    }
}

/// The pure join rule for an append, and the Swift half of a two-language pair.
///
/// The live path (JS, a CodeMirror transaction) and the no-live-window fallback (Swift, a store write) must
/// produce byte-identical text, otherwise "where the appended block starts" depends on whether a window
/// happened to be open. The JS mirror is `appendRange` in `Web/StickyNotes/src/sticky-skill-append.js`, kept
/// DOM-free for exactly the reason `dictation-separator.js` is: so this headless surface can pin the whole
/// truth table against the production predicate rather than a test-only reimplementation.
///
/// The rule: the appended block starts after the note's last non-whitespace character, separated by exactly
/// one blank line; an empty (or all-whitespace) note simply becomes the addition. Trailing whitespace
/// already in the note is absorbed, so repeated appends cannot accumulate blank lines.
///
/// Whitespace here is the four ASCII characters only - space, tab, CR, LF - deliberately NOT
/// `.whitespacesAndNewlines` and deliberately NOT JavaScript's `\s`, because those two sets disagree on
/// unicode (U+00A0, U+FEFF and friends) and this rule is only correct if both languages agree exactly.
enum StickySkillAppendLogic {
    private static let asciiWhitespace: Set<Character> = [" ", "\t", "\r", "\n"]

    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var out = text
        while let last = out.last, asciiWhitespace.contains(last) { out.removeLast() }
        return out
    }

    /// Just the text an append ADDS, separator included. What the user is told landed.
    static func appendedSuffix(afterExisting existing: String, addition: String) -> String {
        trimmingTrailingWhitespace(existing).isEmpty ? addition : "\n\n" + addition
    }

    /// The FULL body an append produces. Used only by the no-live-window fallback; the live path inserts
    /// `appendedSuffix` over the note's trailing whitespace, which yields exactly this string.
    static func joined(existing: String, addition: String) -> String {
        let trimmed = trimmingTrailingWhitespace(existing)
        return trimmed.isEmpty ? addition : trimmed + "\n\n" + addition
    }
}

// MARK: - Copy to clipboard

/// The landing that touches no note at all. It exists in v1 partly for its own sake and partly because it
/// is the proof that the slot is not secretly note-shaped: it takes the same request, returns the same
/// landing type, and needed no accommodation on the run path.
struct CopyToClipboardOutputHandler: StickySkillOutputHandler {
    let mode = StickySkillOutputMode.copyToClipboard

    func land(_ request: StickySkillOutputRequest,
              through seam: StickySkillOutputSeam) -> StickySkillOutputLanding {
        guard seam.copyToClipboard(request.output) else {
            return .failed(userMessage: "Could not copy the result to the clipboard",
                           detail: "pasteboard refused the write")
        }
        return .copiedToClipboard(chars: request.output.count)
    }
}
