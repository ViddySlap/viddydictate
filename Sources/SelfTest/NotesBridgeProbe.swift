import Foundation
import AppKit

extension NotesProbe {
    static func probeDictationSeparator(check: Check) {
        typealias Logic = NotesDictationSeparatorLogic

        // The five locked acceptance rows, plus the explicitly named delimiter/newline/leading-space edges.
        check("dictation separator: position 0 gets no leading space",
              Logic.preparedBareCaretInsert(precedingChar: nil, insertedText: "Thank you") == "Thank you")
        check("dictation separator: whitespace-preceded insert gets no extra space",
              Logic.preparedBareCaretInsert(precedingChar: " ", insertedText: "Thank you") == "Thank you"
              && Logic.preparedBareCaretInsert(precedingChar: "\n", insertedText: "Thank you") == "Thank you")
        check("dictation separator: opening delimiters attach the inserted text",
              ["(", "[", "{", "\u{201C}", "\u{2018}"].allSatisfy {
                  Logic.preparedBareCaretInsert(precedingChar: Character($0), insertedText: "Thank you") == "Thank you"
              })
        check("dictation separator: closing or attaching punctuation gets no leading space",
              [",", ".", ";", ":", "!", "?", ")", "]", "}", "\u{201D}", "\u{2019}"].allSatisfy {
                  Logic.preparedBareCaretInsert(precedingChar: "e", insertedText: $0 + " next") == $0 + " next"
              })
        check("dictation separator: alphanumeric-preceded text gets one ASCII space",
              Logic.preparedBareCaretInsert(precedingChar: "e", insertedText: "Thank you") == " Thank you")
        check("dictation separator: a leading newline is preserved and never prefixed",
              Logic.preparedBareCaretInsert(precedingChar: "e", insertedText: "\nThank you") == "\nThank you")
        check("dictation separator: provider-leading whitespace is stripped before one canonical space",
              Logic.preparedBareCaretInsert(precedingChar: "e", insertedText: " \t Thank you") == " Thank you")

        let editor = sourceEditorJS
        let separator = sourceDictationSeparatorJS
        let insertIntoBody = sourceSlice(editor,
                                         from: "export function insertIntoEditor(insert) {",
                                         to: "// The live editor's current main selection")
        let insertAtRangeStart = editor.range(of: "export function insertAtRange(from, to, insert) {")
        let insertAtRangeBody = insertAtRangeStart.map { String(editor[$0.lowerBound...]) } ?? ""
        check("dictation separator: the shipping editor imports the one pure predicate",
              separator.contains("export function needsLeadingSeparator(precedingChar, insertedText)")
              && editor.contains("import { needsLeadingSeparator, stripLeadingInlineWhitespace } from \"./dictation-separator.js\"")
              && countOccurrences(of: "needsLeadingSeparator(", in: separator) == 1)
        check("dictation separator: both editor insertion primitives share insertAtRange",
              insertIntoBody.contains("return insertAtRange(cursor.from, cursor.to, insert)")
              && !insertIntoBody.contains("editor.dispatch"))
        check("dictation separator: only the bare-caret branch normalizes and applies the predicate",
              insertAtRangeBody.contains("if (f === t) {")
              && insertAtRangeBody.contains("insert = stripLeadingInlineWhitespace(insert)")
              && insertAtRangeBody.contains("needsLeadingSeparator(precedingChar, insert)")
              && insertAtRangeBody.contains("changes: { from: f, to: t, insert }")
              && countOccurrences(of: "needsLeadingSeparator(", in: editor) == 1)
    }

    static func probeBridgeParity(check: Check) {
        // --- 9. bridge-contract parity: Swift enums == bundled app.js wire names -------------
        do {
            let appJS = NotesProbe.bundledAppJS
            let appCSS = NotesProbe.bundledAppCSS
            check("bridge parity: bundled web island app.js is readable",
                  !appJS.isEmpty, "Resources/StickyNotes/app.js")

            // Inbound/outbound wire names live in the frozen MSG table.
            let inboundJS = objectKeys(afterAnyMarker: ["inbound:Object.freeze(", "inbound: Object.freeze("], in: appJS)
            check("bridge parity: Swift NotesInbound == bundled JS MSG.inbound wire names",
                  inboundJS != nil && Set(NotesInbound.allCases.map(\.rawValue)) == inboundJS!,
                  driftDetail(swift: NotesInbound.allCases.map(\.rawValue), js: inboundJS))

            let outboundJS = objectKeys(afterAnyMarker: ["outbound:Object.freeze(", "outbound: Object.freeze("], in: appJS)
            check("bridge parity: Swift NotesOutbound == bundled JS MSG.outbound wire names",
                  outboundJS != nil && Set(NotesOutbound.allCases.map(\.rawValue)) == outboundJS!,
                  driftDetail(swift: NotesOutbound.allCases.map(\.rawValue), js: outboundJS))

            let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(bridgeSourcePath, isDirectory: false)
            let sourceJS = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
            let sourceForParse = stripLineComments(sourceJS)
            let sourceInbound = objectKeys(afterAnyMarker: ["inbound: Object.freeze(", "inbound:Object.freeze("],
                                               in: sourceForParse)
            let sourceOutbound = objectKeys(afterAnyMarker: ["outbound: Object.freeze(", "outbound:Object.freeze("],
                                                in: sourceForParse)
            let sourceInboundOK = sourceInbound != nil && Set(NotesInbound.allCases.map(\.rawValue)) == sourceInbound!
            let sourceOutboundOK = sourceOutbound != nil && Set(NotesOutbound.allCases.map(\.rawValue)) == sourceOutbound!
            let sourceDetail = [
                sourceJS.isEmpty ? "\(bridgeSourcePath) unreadable" : "",
                sourceInboundOK ? "" : "inbound \(driftDetail(swift: NotesInbound.allCases.map(\.rawValue), js: sourceInbound))",
                sourceOutboundOK ? "" : "outbound \(driftDetail(swift: NotesOutbound.allCases.map(\.rawValue), js: sourceOutbound))",
            ].filter { !$0.isEmpty }.joined(separator: " ")
            check("bridge source parity: Swift enums == JS MSG tables",
                  !sourceJS.isEmpty && sourceInboundOK && sourceOutboundOK,
                  sourceDetail)

            check("Finder reveal: tab menu ships the action and disables notes with no backing file",
                  sourceIndexHTML.contains("data-action=\"openInFinder\">Open in Finder")
                  && sourceRenderJS.contains("openInFinder.disabled = !canReveal")
                  && sourceActionsJS.contains("post(MSG.inbound.revealInFinder, { id: tab.id })")
                  && appJS.contains("revealInFinder"))

            let closeRange = sourceIndexHTML.range(of: "data-action=\"close\">Close")
            let skillSeparatorRange = sourceIndexHTML.range(of: "id=\"sticky-skills-menu-separator\"")
            let skillHeadingRange = sourceIndexHTML.range(of: ">Sticky Skills</div>")
            check("Sticky Skills menu: one JS-owned section sits after ordinary actions with one separator",
                  closeRange != nil && skillSeparatorRange != nil && skillHeadingRange != nil
                  && closeRange!.lowerBound < skillSeparatorRange!.lowerBound
                  && skillSeparatorRange!.lowerBound < skillHeadingRange!.lowerBound
                  && !sourceIndexHTML.contains("data-action=\"noteToHandoff\"")
                  && sourceIndexHTML.components(separatedBy: "context-menu-separator").count - 1 == 1)

            check("Sticky Skills menu: catalog rendering is dynamic and the empty catalog hides its chrome",
                  sourceStickySkillMenuJS.contains("export function renderStickySkillMenu")
                  && sourceStickySkillMenuJS.contains("section.hidden = !visible")
                  && sourceStickySkillMenuJS.contains("separator.hidden = !visible")
                  && sourceStickySkillMenuJS.contains("button.textContent = skill.displayName")
                  && sourceStickySkillMenuJS.contains("button.dataset.skillId = skill.id"))

            check("Sticky Skills menu: selected skill id rides the existing whole-note bridge action",
                  sourceActionsJS.contains("export function noteToHandoff(id, skillId = null)")
                  && sourceActionsJS.contains("payload.skillId = skillId")
                  && sourceRenderJS.contains("handler.noteToHandoff(id, skillId)")
                  && sourceEventsJS.contains("const skillId = button.dataset.skillId || null")
                  && appJS.contains("noteToHandoff"))

            check("Sticky Skills menu: initial state and store changes push the standalone projection",
                  sourceNotesWindowController.contains("forName: StickySkillStore.didChange")
                  && sourceNotesWindowController.contains("self?.sendStickySkillsToWeb()")
                  && sourceNotesWindowController.contains("let items = StickySkillMenuProjection.items")
                  && sourceNotesWindowController.contains("call(.stickySkills, payload: [BridgeKey.items: items])")
                  && countOccurrences(of: "sendStickySkillsToWeb()", in: sourceNotesWindowController) >= 3)

            check("tab drag guard: bundled JS clears native + editor selections during tab drag",
                  appJS.contains("tab-drag-selection-guard")
                  && appJS.contains("selectstart")
                  && appJS.contains("selectionchange")
                  && appJS.contains("removeAllRanges")
                  && appJS.contains("selection:{anchor:"))
            check("tab drag guard: bundled CSS scopes user-select suppression to the drag guard class",
                  appCSS.contains("body.tab-drag-selection-guard")
                  && appCSS.contains("-webkit-user-select: none !important")
                  && appCSS.contains("user-select: none !important"))
        }
    }

    static func probePasteRouting(check: Check) {
        // --- 9b. clipboard paste routing (A1) -------------------------------------------------------
        // Cmd+V inside a notes window must route image/video content to the attachment tray (via the SAME
        // drop/attachment path) and leave plain text to CodeMirror. The interception + real NSPasteboard read
        // are GUI-only (covered by real-app verification); the DECISION is a pure function over a synthetic
        // pasteboard descriptor and is asserted here across every routing shape.
        func route(_ exts: [String], rawImage: Bool) -> NotesPasteRoute {
            NotesPasteRouter.decide(NotesPasteDescriptor(fileURLExtensions: exts, hasRawImage: rawImage))
        }

        // Raw image bytes (a copied screenshot), no file URL -> tray.
        check("paste route: raw image bytes -> tray",
              route([], rawImage: true) == .tray)
        // A mixed image+text paste carries raw image bytes; the image wins, text is ignored.
        check("paste route: image wins on a mixed image+text paste -> tray",
              route([], rawImage: true) == .tray)
        // Plain text (no file URL, no image) -> editor, exactly as today.
        check("paste route: plain text (no image, no file URL) -> editor",
              route([], rawImage: false) == .editor)

        // Image file URLs -> tray, one per accepted image extension.
        for ext in ["png", "jpg", "jpeg", "gif", "webp"] {
            check("paste route: image file URL .\(ext) -> tray",
                  route([ext], rawImage: false) == .tray)
        }
        // Video file URLs -> tray, one per accepted video extension.
        for ext in ["mov", "mp4", "m4v", "webm"] {
            check("paste route: video file URL .\(ext) -> tray",
                  route([ext], rawImage: false) == .tray)
        }
        // Extension casing must not matter (mediaKind lowercases).
        check("paste route: uppercase image extension .PNG -> tray",
              route(["PNG"], rawImage: false) == .tray)

        // A non-media file URL (no raw image) -> editor: paste is not intercepted, today's behavior stands.
        check("paste route: non-media file URL .pdf -> editor",
              route(["pdf"], rawImage: false) == .editor)
        check("paste route: non-media file URL .txt -> editor",
              route(["txt"], rawImage: false) == .editor)

        // A file URL set with at least one media sibling -> tray (the coordinator rejects the non-media ones,
        // matching drop); file URLs are considered ahead of raw image bytes.
        check("paste route: mixed file URLs with a media member -> tray",
              route(["txt", "mp4"], rawImage: false) == .tray)
        check("paste route: file URLs take precedence — non-media file URL beats stray image bytes -> editor",
              route(["txt"], rawImage: true) == .editor)

        // isPasteShortcut: bare Cmd+V is the trigger; Cmd+Shift+V and a plain 'v' are not.
        check("paste shortcut: bare Cmd+V is recognized",
              NotesPasteRouter.isPasteShortcut(makeKeyEvent(chars: "v", flags: .command)))
        check("paste shortcut: Cmd+Shift+V is NOT the bare paste shortcut",
              !NotesPasteRouter.isPasteShortcut(makeKeyEvent(chars: "v", flags: [.command, .shift])))
        check("paste shortcut: a plain 'v' with no command is not the paste shortcut",
              !NotesPasteRouter.isPasteShortcut(makeKeyEvent(chars: "v", flags: [])))
    }

    /// Build a synthetic key-down event for the paste-shortcut checks (no window/UI needed).
    static func makeKeyEvent(chars: String, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 9)!
    }

}
