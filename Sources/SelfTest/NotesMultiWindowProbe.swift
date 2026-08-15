import Foundation
import AppKit

extension NotesProbe {
    static func probeMultiWindowMembership(freshRoot: () -> URL, check: Check) {
        // --- 11. multi-window membership + cross-window aggregate (L6) --------------------------
        // The registry is UI-bearing, but its store contract + pure decision logic are probe-tested here:
        // windows.json round-trip, window-then-tab aggregate ordering with exactly one global (active)
        // marker on the most-recently-key window's active tab, active-window resolution, title-bar-close
        // migration, secondary pruning, and single-window equivalence (the live single-primary path must
        // produce byte-identical _open-notes.md to the pre-L6 code).

        // 11a. windows.json round-trip: order, frames, activeId preserved; sanitized on load
        do {
            let store = StickyNotesStore(root: freshRoot())
            let saved = [
                WindowMembership(id: "window-primary", noteIds: ["note-a", "note-b"], activeId: "note-b", frame: nil),
                WindowMembership(id: "window-2", noteIds: ["note-c"], activeId: "note-c", frame: "{{40, 60}, {900, 640}}"),
            ]
            store.saveWindows(saved)
            let loaded = store.loadWindows()
            check("windows round-trip: order + noteIds + activeId + frame preserved",
                  loaded == saved)
            // Sanitize: an activeId that no longer belongs to its window is dropped; a note claimed by two
            // windows is deduped to the first; invalid ids are stripped.
            store.saveWindows([
                WindowMembership(id: "window-primary", noteIds: ["note-x", "bogus"], activeId: "note-gone", frame: nil),
                WindowMembership(id: "window-2", noteIds: ["note-x", "note-y"], activeId: "note-y", frame: nil),
            ])
            let sane = store.loadWindows()
            check("windows load sanitize: invalid id stripped, activeId dropped when not a member",
                  sane.first?.noteIds == ["note-x"] && sane.first?.activeId == nil)
            check("windows load sanitize: a note is claimed by only the first window (cross-window dedup)",
                  sane.count == 2 && sane[1].noteIds == ["note-y"] && sane[1].activeId == "note-y")
        }

        // 11b. cross-window aggregate: window-then-tab order, exactly one (active) marker on the active
        // window's active tab (NOT the other window's activeId)
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-a", body: "# Alpha\nfirst window")
            store.saveOpenNote(id: "note-b", body: "# Bravo\nsecond window")
            store.saveOpenNote(id: "note-c", body: "# Charlie\nsecond window too")
            let windows = [
                WindowMembership(id: "window-primary", noteIds: ["note-a"], activeId: "note-a", frame: nil),
                WindowMembership(id: "window-2", noteIds: ["note-b", "note-c"], activeId: "note-c", frame: nil),
            ]
            store.rewriteAggregate(windows: windows, activeWindowId: "window-2")
            let agg = (try? String(contentsOf: store.root.appendingPathComponent("_open-notes.md"), encoding: .utf8)) ?? ""
            check("windows aggregate: window-then-tab order (Alpha, then Bravo, then Charlie)",
                  orderedBefore("## Alpha", "## Bravo", in: agg)
                  && orderedBefore("## Bravo", "## Charlie", in: agg))
            check("windows aggregate: exactly ONE global (active) marker",
                  countOccurrences(of: " (active)", in: agg) == 1)
            check("windows aggregate: the marker is on the active window's active tab (Charlie), not window-1's activeId",
                  agg.contains("## Charlie (active)") && !agg.contains("## Alpha (active)"))
        }

        // 11c. active-window resolution: switching the active window moves the single marker; the pure
        // resolveActiveWindowId picks the most-recently-key existing window
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-a", body: "# Alpha\none")
            store.saveOpenNote(id: "note-b", body: "# Bravo\ntwo")
            let windows = [
                WindowMembership(id: "window-primary", noteIds: ["note-a"], activeId: "note-a", frame: nil),
                WindowMembership(id: "window-2", noteIds: ["note-b"], activeId: "note-b", frame: nil),
            ]
            store.rewriteAggregate(windows: windows, activeWindowId: "window-primary")
            let agg = (try? String(contentsOf: store.root.appendingPathComponent("_open-notes.md"), encoding: .utf8)) ?? ""
            check("windows aggregate: marker follows the active window (now window-1 -> Alpha)",
                  agg.contains("## Alpha (active)") && !agg.contains("## Bravo (active)")
                  && countOccurrences(of: " (active)", in: agg) == 1)
            check("resolveActiveWindowId: most-recently-key existing window wins",
                  NotesWindowRegistry.resolveActiveWindowId(mru: ["window-2", "window-primary"],
                                                            existing: ["window-primary", "window-2"]) == "window-2")
            check("resolveActiveWindowId: skips a stale MRU id no longer present",
                  NotesWindowRegistry.resolveActiveWindowId(mru: ["window-dead", "window-primary"],
                                                            existing: ["window-primary", "window-2"]) == "window-primary")
            check("resolveActiveWindowId: falls back to the first window when MRU is empty",
                  NotesWindowRegistry.resolveActiveWindowId(mru: [], existing: ["window-primary", "window-2"]) == "window-primary")
            check("resolveActiveWindowId: nil when no windows exist",
                  NotesWindowRegistry.resolveActiveWindowId(mru: ["window-primary"], existing: []) == nil)
        }

        // 11d. title-bar-close decision: notes migrate to primary/oldest survivor; a last window hides; only
        // an empty secondary with another window available is destroyed.
        do {
            let primary = WindowMembership(id: "window-primary", noteIds: ["note-p"],
                                           activeId: "note-p", frame: nil)
            let older = WindowMembership(id: "window-older", noteIds: ["note-o"],
                                         activeId: "note-o", frame: nil)
            let closing = WindowMembership(id: "window-closing", noteIds: ["note-a", "note-b"],
                                           activeId: "note-b", frame: nil)
            check("window close: a secondary with tabs migrates to the primary",
                  NotesWindowRegistry.windowCloseAction(
                    closing: closing, windows: [older, closing, primary], primaryId: "window-primary")
                  == .migrate(to: "window-primary"))
            check("window close: without a primary, tabs migrate to the oldest surviving window",
                  NotesWindowRegistry.windowCloseAction(
                    closing: closing, windows: [older, closing], primaryId: "window-primary")
                  == .migrate(to: "window-older"))
            check("window close: the last window hides and keeps its tabs open",
                  NotesWindowRegistry.windowCloseAction(
                    closing: closing, windows: [closing], primaryId: "window-primary") == .hide)
            check("window close: the primary hides instead of moving or closing its tabs",
                  NotesWindowRegistry.windowCloseAction(
                    closing: primary, windows: [primary, older], primaryId: "window-primary") == .hide)
            let empty = WindowMembership(id: "window-empty", noteIds: [], activeId: nil, frame: nil)
            check("window close: an empty secondary is destroyed when another window survives",
                  NotesWindowRegistry.windowCloseAction(
                    closing: empty, windows: [primary, empty], primaryId: "window-primary") == .destroy)
        }

        // 11e. controller migration keeps every tab open, including a lazy empty tab, without writing History.
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-primary", body: "# Primary\nbody")
            store.saveOpenNote(id: "note-moved", body: "# Moved\nbody")
            let target = NotesWindowController(store: store, windowId: "window-primary", isPrimary: true,
                                               initialNoteIds: ["note-primary"], initialActiveId: "note-primary")
            let lazy = StickyNoteWire(id: "note-lazy", body: "", title: "")
            let source = NotesWindowController(store: store, windowId: "window-secondary", isPrimary: false,
                                               initialNoteIds: ["note-moved", "note-lazy"], initialNotes: [lazy],
                                               initialActiveId: "note-lazy")
            let moving = source.tabsForWindowMigration()
            target.adoptMigratedTabs(moving, preferredActiveId: source.membership.activeId)
            check("window close migrate: materialized + lazy tabs keep source order in the target",
                  moving.map(\.id) == ["note-moved", "note-lazy"]
                  && target.membership.noteIds == ["note-primary", "note-moved", "note-lazy"])
            check("window close migrate: a target's existing active tab remains active",
                  target.membership.activeId == "note-primary")
            check("window close migrate: open note files stay open and History remains untouched",
                  Set(store.openNotes().map(\.id)) == Set(["note-primary", "note-moved"])
                  && store.history(retention: .forever).isEmpty)
            store.saveWindows([target.membership])
            check("window close migrate: windows.json persists the migrated materialized + lazy tabs",
                  store.loadWindows().first?.noteIds == ["note-primary", "note-moved", "note-lazy"])
        }

        // 11f. secondary pruning: an empty SECONDARY is destroyed; the PRIMARY is always kept
        do {
            let windows = [
                WindowMembership(id: "window-primary", noteIds: [], activeId: nil, frame: nil),
                WindowMembership(id: "window-2", noteIds: [], activeId: nil, frame: nil),
                WindowMembership(id: "window-3", noteIds: ["note-a"], activeId: "note-a", frame: nil),
            ]
            let pruned = NotesWindowRegistry.prunedWindows(windows, primaryId: "window-primary")
            check("prunedWindows: empty secondary dropped, primary kept even when empty, non-empty secondary kept",
                  pruned.map(\.id) == ["window-primary", "window-3"])
        }

        // 11g. single-window equivalence: for a lone primary window, the multi-window aggregate is
        // byte-identical to the pre-L6 single-window rewrite (the live single-primary path is unchanged)
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-a", body: "# Alpha\nbody a")
            store.saveOpenNote(id: "note-b", body: "# Bravo\nbody b")
            _ = store.addAttachment(noteId: "note-a", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                                    suggestedName: "pic.png")
            let aggURL = store.root.appendingPathComponent("_open-notes.md")
            store.rewriteAggregate(tabOrder: ["note-b", "note-a"], activeId: "note-a")
            let single = (try? String(contentsOf: aggURL, encoding: .utf8)) ?? ""
            store.rewriteAggregate(windows: [WindowMembership(id: "window-primary", noteIds: ["note-b", "note-a"],
                                                              activeId: "note-a", frame: nil)],
                                   activeWindowId: "window-primary")
            let multi = (try? String(contentsOf: aggURL, encoding: .utf8)) ?? ""
            check("windows aggregate: single-primary output is byte-identical to the pre-L6 single-window rewrite",
                  !single.isEmpty && single == multi)
        }
    }

    static func probeMiniViewState(freshRoot: () -> URL, check: Check) {
        // --- 12. mini-view core (notes-miniview A2) --------------------------------------------------
        // One per-window boolean drives everything: effective mini = manual OR contentWidth < 560. The chrome
        // hide + edge-to-edge editor render is GUI/WKWebView-side (covered by real-app verification); the pure
        // DECISION, the lowered minSize floor, and the per-window persistence are asserted here headlessly.

        // 12a. effective-mini truth table: `manual OR width < 560`, with the threshold strictly less-than.
        func mini(_ manual: Bool, _ width: CGFloat) -> Bool {
            NotesMiniState.effectiveMini(manual: manual, contentWidth: width)
        }
        check("mini truth: manual off + width 600 (>=560) -> full",  mini(false, 600) == false)
        check("mini truth: manual off + width 561 -> full",          mini(false, 561) == false)
        check("mini truth: manual off + width exactly 560 -> full (threshold is strict <)", mini(false, 560) == false)
        check("mini truth: manual off + width 559 -> mini",          mini(false, 559) == true)
        check("mini truth: manual off + width 280 (the floor) -> mini", mini(false, 280) == true)
        check("mini truth: manual ON + width 900 -> mini (manual wins over a wide window)", mini(true, 900) == true)
        check("mini truth: manual ON + width 100 -> mini",           mini(true, 100) == true)

        // 12b. the mini floor: minSize lowered to 280x190, and the floor width is always below the 560 auto-flip
        // threshold so a window shrunk to the floor is always mini.
        check("mini floor: minSize is 280x190",
              NotesMiniState.minWidth == 280 && NotesMiniState.minHeight == 190)
        check("mini floor: the floor width is below the 560 auto-flip threshold (floor is always mini)",
              NotesMiniState.minWidth < NotesMiniState.autoFlipWidth
              && mini(false, NotesMiniState.minWidth) == true)
        check("mini floor: the auto-flip threshold is 560", NotesMiniState.autoFlipWidth == 560)

        // 12c. per-window independence: only the MANUAL flag is persisted (the size half recomputes), and each
        // window round-trips its own manualMini through windows.json independently.
        do {
            let store = StickyNotesStore(root: freshRoot())
            let saved = [
                WindowMembership(id: "window-primary", noteIds: ["note-a"], activeId: "note-a", frame: nil,
                                 manualMini: true),
                WindowMembership(id: "window-2", noteIds: ["note-b"], activeId: "note-b",
                                 frame: "{{40, 60}, {900, 640}}", manualMini: false),
            ]
            store.saveWindows(saved)
            let loaded = store.loadWindows()
            check("mini persist: manualMini round-trips per window (one mini, one full)",
                  loaded.count == 2
                  && loaded[0].id == "window-primary" && loaded[0].manualMini == true
                  && loaded[1].id == "window-2" && loaded[1].manualMini == false)
            check("mini persist: full membership equality survives the round-trip (manual flag included)",
                  loaded == saved)
            check("mini persist: a window built without the flag defaults to full",
                  WindowMembership(id: "w", noteIds: [], activeId: nil, frame: nil).manualMini == false)
        }

        // 12d. lenient decode: a pre-mini windows.json with no manualMini key still loads (flag defaults false),
        // so upgrading never drops the saved arrangement.
        do {
            let store = StickyNotesStore(root: freshRoot())
            let legacy = "[{\"id\":\"window-primary\",\"noteIds\":[\"note-a\"],\"activeId\":\"note-a\"}]"
            store.saveOpenNote(id: "note-a", body: "# Legacy\nbody")
            try? legacy.write(to: store.root.appendingPathComponent("windows.json"), atomically: true, encoding: .utf8)
            let loaded = store.loadWindows()
            check("mini persist: legacy windows.json without manualMini decodes (defaults to full)",
                  loaded.count == 1 && loaded[0].id == "window-primary" && loaded[0].manualMini == false)
        }
    }

    static func probeMiniControls(freshRoot: () -> URL, check: Check) {
        // --- 12b. mini-view toggle + hover overlay (notes-miniview A3) --------------------------------
        // Full view gains a collapse-to-mini button in the tab-bar button row; mini view floats a hover overlay
        // carrying the per-note copy buttons, the "i" cheat-sheet button (only when the cheat-sheet setting is
        // enabled), and the mini-toggle back to full. The overlay is the ONLY chrome in mini and only on hover.
        // The chrome render + hover behavior are WKWebView/CSS-side (covered by real-app GUI verification);
        // the SHIPPING contract asserted here is: the toggle-flips-the-manual-state round-trip (pure Swift), the
        // overlay's contents in the bundled markup, and the visibility gates in the bundled CSS.

        // 12b-i. toggle round-trip: the JS toggle posts setManualMini; Swift routes it to setManualMini(_:), which
        // flips (and persists) the window's MANUAL flag. Drive that flip on a real headless controller and assert
        // the manual state round-trips both directions (the membership the registry persists carries the flag).
        do {
            let store = StickyNotesStore(root: freshRoot())
            let controller = NotesWindowController(store: store, windowId: "window-mini-probe",
                                                   isPrimary: false, initialManualMini: false)
            check("mini toggle: a fresh window starts full (manualMini false)",
                  controller.membership.manualMini == false)
            controller.setManualMini(true)
            check("mini toggle: setManualMini(true) flips the window into manual mini",
                  controller.membership.manualMini == true && controller.isEffectiveMini == true)
            controller.setManualMini(false)
            check("mini toggle: setManualMini(false) flips the manual flag back to full",
                  controller.membership.manualMini == false)
            check("mini toggle: setManualMini is a wired inbound bridge message (Swift enum)",
                  NotesInbound.allCases.contains(.setManualMini))
        }

        // 12b-ii. bundled markup: the full-view collapse button + the hover overlay with copy / copy-assets /
        // cheat-sheet / mini-toggle buttons all ship in the bundled index.html.
        let indexHTML: String
        let appCSS = NotesProbe.bundledAppCSS
        let sourceAppCSS = NotesProbe.sourceAppCSS
        let appJS = NotesProbe.bundledAppJS
        if let resURL = Bundle.main.resourceURL {
            indexHTML = (try? String(contentsOf: resURL.appendingPathComponent("StickyNotes/index.html"), encoding: .utf8)) ?? ""
        } else {
            indexHTML = ""
        }
        check("mini overlay: bundled index.html is readable", !indexHTML.isEmpty, "Resources/StickyNotes/index.html")
        // 1b: the top-right floating glyph buttons (copy / copy-assets ▦ / info "i" italic) flex-center their glyph
        // so the box no longer slants the mark left. The pixel confirm is the review PNG; pin the CSS contract here.
        do {
            let block = cssBlock(appCSS, selector: ".floating-button")
            check("floating buttons: glyph is flex-centered (1b)",
                  block.contains("inline-flex") && block.contains("align-items: center")
                  && block.contains("justify-content: center"),
                  ".floating-button flex centering in app.css")
        }
        check("mini overlay: full-view collapse-to-mini button is in the tab-bar button row",
              indexHTML.contains("id=\"mini-enter\""))
        check("mini overlay: the hover overlay container ships",
              indexHTML.contains("id=\"mini-overlay\""))
        check("mini overlay: carries the per-note copy buttons (text + assets)",
              indexHTML.contains("id=\"mini-copy\"") && indexHTML.contains("id=\"mini-copy-assets\""))
        check("mini overlay: carries the \"i\" cheat-sheet button",
              indexHTML.contains("id=\"mini-info\""))
        check("mini overlay: carries the mini-toggle back to full",
              indexHTML.contains("id=\"mini-toggle\""))

        // L6 (toolbar icons): three marks in this chrome rhymed — every glyph in the app is "a small mark inside
        // a square" at 28-32px, so ⊟ collided with ☰ in the tab-bar row and ▦ collided with ⊞ in the mini
        // overlay. The fix is deliberately asymmetric and each half is pinned here, because each half has a
        // failure mode that a green suite would otherwise not see.
        do {
            // Bind each assertion to the button it is about. A global `contains("Mini")` would stay green if the
            // two words were swapped onto each other's control, which is precisely the mistake worth catching:
            // both labels would still be present and every other check in this block would pass.
            func buttonBody(_ id: String) -> String {
                guard let idHit = indexHTML.range(of: "id=\"\(id)\"") else { return "" }
                let tail = indexHTML[idHit.upperBound...]
                guard let close = tail.range(of: "</button>") else { return "" }
                return String(tail[..<close.lowerBound])
            }

            // i. The mini/full toggle is the ONE control that carries a word, and the word is the DESTINATION,
            // not the direction: "Mini" is offered from full view, "Full" from mini.
            check("toolbar icons (L6): the full-view collapse control names its destination (\"Mini\"), not a mark",
                  buttonBody("mini-enter").hasSuffix(">Mini") && !indexHTML.contains("⊟"),
                  "#mini-enter labelled Mini, U+229F retired")
            check("toolbar icons (L6): the mini overlay's back-to-full control names its destination (\"Full\"), not a mark",
                  buttonBody("mini-toggle").hasSuffix(">Full") && !indexHTML.contains("⊞"),
                  "#mini-toggle labelled Full, U+229E retired")

            // ii. The copy-assets control has TWO DOM instances (full-view floating + mini overlay) that must
            // change together — changing one is the shape of this bug, not a fix for it. Assert BOTH ids carry a
            // mark AND that exactly two exist, so neither a missed instance nor a stray third passes.
            let svgInstances = indexHTML.components(separatedBy: "class=\"glyph-svg\"").count - 1
            check("toolbar icons (L6): BOTH copy-assets instances carry the SVG mark, and neither kept ▦",
                  buttonBody("copy-assets-button").contains("class=\"glyph-svg\"")
                  && buttonBody("mini-copy-assets").contains("class=\"glyph-svg\"")
                  && svgInstances == 2 && !indexHTML.contains("▦"),
                  "expected 2 glyph-svg instances, found \(svgInstances)")

            // iii. The one that actually matters. This was the app's first SVG (the later design added the second, the
            // + mark), and the palette is hue-derived from the user's accent at runtime (theme.css is GENERATED by
            // --emit-theme-css, not authored), so a hardcoded fill would make a mark on screen ignore his theme.
            // The scan is whole-markup, so it covers every SVG the island ships, not just this one.
            // Assert the property rather than a spelling: every fill/stroke value in the bundled markup must be
            // currentColor or none. ("stroke-width"/"stroke-linejoin" do not match `stroke="`.)
            var hardcoded: [String] = []
            for attr in ["fill=\"", "stroke=\""] {
                var rest = indexHTML[...]
                while let hit = rest.range(of: attr) {
                    let tail = rest[hit.upperBound...]
                    let value = String(tail.prefix(while: { $0 != "\"" }))
                    if value != "currentColor" && value != "none" { hardcoded.append(attr + value + "\"") }
                    rest = tail
                }
            }
            check("toolbar icons (L6): the copy-assets SVG is monochrome — every fill/stroke is currentColor or none",
                  hardcoded.isEmpty,
                  hardcoded.isEmpty ? "no hardcoded colour in bundled markup"
                                    : "hardcoded colour(s): \(hardcoded.joined(separator: ", "))")
            check("toolbar icons (L6): the SVG is sized in em so one rule tracks both hosts' font-size (15px floating / 14px mini)",
                  cssBlock(appCSS, selector: ".glyph-svg").contains("width: 1.15em"),
                  ".glyph-svg em sizing in app.css")

            // iv. The word is four characters in boxes built for one glyph, so it needed a width. That width is
            // on the two IDs and must STAY there: widening the shared .icon-button / .mini-button would also
            // resize #history-button, #copy-button, #mini-copy, #mini-copy-assets and #mini-info, which are all
            // still marks. This is the check with teeth against the lazy version of the fix. (#new-tab now
            // carries its own square width for the same reason, off its own id — see the rule below.)
            check("toolbar icons (L6): the worded toggle is widened on its own ids, leaving the shared single-glyph boxes fixed",
                  cssBlock(appCSS, selector: "#mini-enter").contains("width: auto")
                  && cssBlock(appCSS, selector: "#mini-toggle").contains("width: auto")
                  && cssBlock(appCSS, selector: ".icon-button").contains("width: 32px")
                  && cssBlock(appCSS, selector: ".mini-button").contains("width: 28px"),
                  "#mini-enter/#mini-toggle width:auto with .icon-button 32px + .mini-button 28px intact")

            // v. Locked decision: the hamburger is untouched. Its collision retires for free once ⊟ became a
            // word, so any edit to it is a scope breach, not a fix.
            check("toolbar icons (L6): the hamburger is untouched (☰ on #history-button)",
                  indexHTML.contains("id=\"history-button\" class=\"icon-button\" title=\"Notes history\">☰</button>"),
                  "#history-button still carries U+2630")

            // The + is the second control to take the SVG-mark-on-a-square-target treatment the
            // camera got here. A text glyph is placed by its baseline, not by its box, so "+" (ascent 9.09,
            // descent 0 — all ink above the baseline) rode low in a box whose midline the baseline sits below:
            // measured 0.75px low in full view, 1.25px low in the smaller mini box, which is why it looked
            // worst in mini. Assert the mechanism, not the pixels: no text node left in the button, a mark
            // sized in px rather than the 1.15em text-relative rule (this button has no text to size against),
            // and a genuinely SQUARE box in BOTH views. The monochrome check above already covers the new
            // path's fill/stroke, since it scans every fill=/stroke= in the bundled markup.
            check("toolbar icons (L2): the + is an inline SVG mark, not a typographic character in a box",
                  buttonBody("new-tab").contains("<svg")
                  && !buttonBody("new-tab").hasSuffix(">+")
                  && buttonBody("new-tab").hasSuffix("</svg>"),
                  "#new-tab carries an SVG mark with no leftover text node")
            check("toolbar icons (L2): the + mark is centered by the box (inline-flex, both axes, no padding)",
                  cssBlock(appCSS, selector: "#new-tab").contains("inline-flex")
                  && cssBlock(appCSS, selector: "#new-tab").contains("align-items: center")
                  && cssBlock(appCSS, selector: "#new-tab").contains("justify-content: center")
                  && cssBlock(appCSS, selector: "#new-tab").contains("padding: 0"),
                  "#new-tab flex centering in app.css")
            // Its own class, not .glyph-svg: that class means "the copy-assets camera" and the count above is
            // what proves its two instances never drift apart, so a second mark borrowing it reads as a third
            // camera. Sized in px because this button has no text left for an em to track.
            check("toolbar icons (L2): the + mark has its own class, sized in px, not the camera's 1.15em rule",
                  buttonBody("new-tab").contains("class=\"plus-svg\"")
                  && cssBlock(appCSS, selector: ".plus-svg").contains("width: 12px")
                  && cssBlock(appCSS, selector: ".plus-svg").contains("height: 12px"),
                  ".plus-svg 12px in app.css")
            check("toolbar icons (L2): the + hit target is SQUARE in both views (30x30 full, 26x26 mini)",
                  cssBlock(appCSS, selector: "#new-tab").contains("width: 30px")
                  && cssBlock(appCSS, selector: "#new-tab").contains("height: 30px")
                  && cssBlock(appCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #new-tab").contains("width: 26px")
                  && cssBlock(appCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #new-tab").contains("height: 26px"),
                  "#new-tab square in app.css")
            // The 5px bottom margin on .icon-button lifts the control off the FULL strip's 42px bottom border.
            // The mini band is 30px tall with 4px top padding and a 1px bottom border — 25px usable — so a 26px
            // button plus that margin overflowed the band by 2px and the button's top edge sat at y=-2, off the
            // top of the window. That IS the user's "the + looks cut off" in mini. The margin must stay zeroed there.
            check("toolbar icons (L2): the mini + drops the full-strip 5px lift, so the 30px band cannot clip it",
                  cssBlock(appCSS, selector: ".icon-button").contains("margin-bottom: 5px")
                  && cssBlock(appCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #new-tab").contains("margin-bottom: 0")
                  && cssBlock(sourceAppCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #new-tab").contains("margin-bottom: 0"),
                  "mini #new-tab margin-bottom:0 in source + bundled app.css")

            // The clip edge. The overflow state ends the scroller in mid-tab against bare strip
            // background, which reads as broken rendering rather than as a tab that scrolled under something.
            // The acceptance is by eye and belongs to the user; these pin the three things that make the treatment
            // WORK, each of which fails silently and invisibly rather than loudly.
            //
            // a. The stacking context. The lane paints from a negative-z pseudo-element so it lands above
            // #tabbar's background and below every control in the row. Drop `isolation: isolate` and that
            // negative-z box escapes to the root context and disappears UNDER the bar's own background; raise
            // it to 0 or above instead and it covers the hamburger/Mini cluster, which is not positioned and
            // therefore paints earlier. Both failure modes are "the lane is just gone" or "the controls are
            // gone", so the two properties are asserted together with the context that makes them legal.
            check("tab strip clip (L12): the pinned lane paints above the bar's background and below its controls",
                  cssBlock(appCSS, selector: "#tabbar").contains("isolation: isolate")
                  && cssBlock(sourceAppCSS, selector: "#tabbar").contains("isolation: isolate")
                  && cssBlock(appCSS, selector: "body.tabs-overflow #new-tab::before").contains("z-index: -1"),
                  "#tabbar isolation:isolate + lane z-index:-1 in source + bundled app.css")
            // b. D4 SURVIVES. The lane is paint, never a target: #tabs remains a sibling flex item that ENDS
            // before the controls, and the lane cannot take a click meant for a tab. pointer-events:none is
            // the whole of that guarantee on the decoration's side, so it is asserted rather than assumed.
            check("tab strip clip (L12): the lane is decoration only - D4's real lane, never an overlay target",
                  cssBlock(appCSS, selector: "body.tabs-overflow #new-tab::before").contains("pointer-events: none")
                  && cssBlock(appCSS, selector: "#tabs").contains("flex: 0 1 auto")
                  && cssBlock(appCSS, selector: "#tab-controls").contains("flex: 0 0 auto"),
                  "lane pointer-events:none with L2's flex lane intact in app.css")
            // c. The state is LIVE, not inferred. Whether the tabs fit is a pixel question, and both classes
            // come from the scroller itself; `tabs-clipped` additionally tracks scroll position so the fade
            // lifts once the strip is scrolled to its end and the last tab sits whole against the lane. If the
            // JS half is dropped the CSS is orphaned and every state renders as under-full - green CSS, no
            // treatment - so pin that the bundled bundle actually writes both class names.
            check("tab strip clip (L12): the bundled JS publishes both strip-clip classes off the live scroller",
                  appJS.contains("tabs-overflow") && appJS.contains("tabs-clipped")
                  && appJS.contains("scrollLeft"),
                  "tabs-overflow + tabs-clipped + scrollLeft in bundled app.js")
            // d. Under-full has no clip to solve and must be left exactly as L2 shipped it. Both halves are
            // gated on a class, so the guarantee is that neither is ever written unconditionally.
            check("tab strip clip (L12): neither half of the treatment can reach the under-full strip",
                  !cssBlock(appCSS, selector: "#new-tab").contains("box-shadow")
                  && !cssBlock(appCSS, selector: "#tabs").contains("mask-image")
                  && appCSS.contains("body.tabs-clipped #tabs"),
                  "lane + fade live only under their classes in app.css")
        }

        // 7b (round-5 R2): the mini drag-OUT grab handle. In mini the tab strip is display:none, so there is no
        // `.tab` to grab — a hover-revealed top-edge grab handle IS the drag-out: grabbing it starts a
        // Swift-mediated drag of the active note through the drop coordinator. Pin the bundled markup, the
        // visibility gate (mini + hover only, like the overlay), and that the bundled JS wires the handle
        // element. The live drag itself is GUI-side (covered by real-app verification); the decide outcomes are pinned in
        // probeDropCoordinator (14h/14i/14j).
        check("mini drag-out (7b): the grab handle ships in the bundled markup",
              indexHTML.contains("id=\"mini-grab\""))
        check("mini drag-out (7b): the grab handle is default-hidden, revealed ONLY in mini + hover",
              cssBlock(appCSS, selector: "#mini-grab").contains("display: none")
              && appCSS.contains("body.mini-mode.mini-hover #mini-grab"))
        check("mini drag-out (7b): the bundled JS wires the grab handle element (#mini-grab)",
              appJS.contains("mini-grab"))

        // 12b-iii. bundled CSS visibility gates: overlay only in mini+hover; copy-assets only with attachments;
        // "i" only when the cheat-sheet setting is enabled.
        check("mini overlay: default-hidden, revealed ONLY in mini + hover (overlay-only-in-mini)",
              appCSS.contains("#mini-overlay") && cssBlock(appCSS, selector: "#mini-overlay").contains("display: none")
              && appCSS.contains("body.mini-mode.mini-hover #mini-overlay"))
        check("mini overlay: copy-assets button gated on the active note having attachments (body.tray-mode)",
              appCSS.contains("body.tray-mode #mini-overlay #mini-copy-assets"))
        check("mini overlay: \"i\" cheat-sheet button gated on the cheat-sheet setting (body.cheatsheet-enabled)",
              appCSS.contains("body.cheatsheet-enabled #mini-overlay #mini-info"))

        // 7a: the attachment tray is chrome-hidden in mini and revealed ONLY on hover, as a floating band pinned to
        // the editor's bottom edge (absolute) so the reveal overlays rather than reflows the editor. Pin both gates.
        check("mini tray (7a): attachment tray hidden by default in mini view",
              cssBlock(appCSS, selector: "body.mini-mode #attachment-tray").contains("display: none"),
              "body.mini-mode #attachment-tray display:none in app.css")
        check("mini tray (7a): revealed on hover as an absolute floating band (overlays, no reflow)",
              appCSS.contains("body.mini-mode.mini-hover #attachment-tray")
              && cssBlock(appCSS, selector: "body.mini-mode.mini-hover #attachment-tray").contains("display: flex")
              && cssBlock(appCSS, selector: "body.mini-mode.mini-hover #attachment-tray").contains("position: absolute"),
              "body.mini-mode.mini-hover #attachment-tray flex/absolute overlay band in app.css")
        check("mini tray (L5): attached notes reserve the measured 88px tray band independent of hover",
              cssBlock(appCSS, selector: "*").contains("box-sizing: border-box")
              && cssBlock(appCSS, selector: "#attachment-tray").contains("height: 88px")
              && cssBlock(appCSS, selector: "body.mini-mode.tray-mode .cm-scroller").contains("padding-bottom: 88px"),
              "88px border-box #attachment-tray matched by body.mini-mode.tray-mode .cm-scroller padding-bottom")

        // L8 (UX consolidation): in mini a multi-tab note showed NO tabs, so the window's other notes were
        // unreachable without expanding it. The strip now returns on HOVER as a floating band on the editor's TOP
        // edge, riding the SAME body.mini-mode.mini-hover latch as the overlay / grab handle / tray rather than a
        // competing lifecycle — no new element, no new state, no new bridge message: it is the real #tabbar
        // rendered by the same renderTabs(). Pin the whole contract in the bundled CSS + JS; the geometry is
        // covered by the selector and box-model assertions below.
        check("mini tab strip (L8): the strip is still chrome-hidden in mini by default",
              appCSS.contains("body.mini-mode #tabbar,")
              && cssBlock(appCSS, selector: "body.mini-mode #md-cheatsheet").contains("display: none"),
              "body.mini-mode #tabbar in the display:none chrome group in app.css")
        check("mini tab strip (L8): revealed on the SAME mini+hover latch as the overlay, as an absolute floating band (overlays, no reflow)",
              appCSS.contains("body.mini-mode.mini-hover:not(.blank-mode) #tabbar")
              && cssBlock(appCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #tabbar").contains("display: flex")
              && cssBlock(appCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #tabbar").contains("position: absolute"),
              "body.mini-mode.mini-hover:not(.blank-mode) #tabbar flex/absolute band in app.css")
        check("mini tab strip (L8): the band sits below the mini overlay so the overlay buttons win an overlap",
              cssBlock(appCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #tabbar").contains("z-index: 5")
              && cssBlock(appCSS, selector: "#mini-overlay").contains("z-index: 6"),
              "#tabbar band z-index 5 under #mini-overlay z-index 6")
        check("mini tab strip (L8): tabs scroll horizontally rather than overflowing a 280pt mini window",
              cssBlock(appCSS, selector: "#tabs").contains("overflow-x: auto")
              && cssBlock(appCSS, selector: "#tabs").contains("min-width: 0"),
              "#tabs stays the sole horizontal scroller in the mini band")
        check("mini tab strip (L8): compact tab metrics for the band (the 116px full-view floor fits ~2 tabs at the mini floor)",
              cssBlock(appCSS, selector: "body.mini-mode.mini-hover .tab").contains("min-width: 78px"),
              "body.mini-mode.mini-hover .tab compact metrics in app.css")
        let tabControlsMarkup = sourceSlice(indexHTML, from: "<div id=\"tab-controls\">", to: "</div>")
        let miniOverlayMarkup = sourceSlice(indexHTML, from: "<div id=\"mini-overlay\"", to: "<div id=\"mini-grab\"")
        let tabbarMarkup = sourceSlice(indexHTML, from: "<div id=\"tabbar\">", to: "<div id=\"main\">")
        // The layout keeps ONLY the + after the tabs. It leaves #tab-controls and
        // became the middle flex item of #tabbar — scroller, then +, then the pinned cluster — which is what
        // lets the + travel while the hamburger and Mini hold one fixed spot. Pin the ORDER, because the whole
        // behaviour is positional: a + that drifted back inside the cluster, or behind it, would still render
        // three buttons in a row and would still look right at the one tab count that fills the strip.
        check("mini new note (S9/L2): the real #new-tab is the strip's own item, never the fixed mini overlay",
              tabbarMarkup.contains("id=\"new-tab\"")
              && !tabControlsMarkup.contains("id=\"new-tab\"")
              && !miniOverlayMarkup.contains("id=\"new-tab\""),
              "#new-tab a direct #tabbar child, out of #tab-controls and absent from #mini-overlay")
        check("tab layout (L2): the strip reads scroller -> + -> pinned cluster, in that order",
              orderedBefore("id=\"tabs\"", "id=\"new-tab\"", in: tabbarMarkup)
              && orderedBefore("id=\"new-tab\"", "id=\"tab-controls\"", in: tabbarMarkup),
              "#tabs then #new-tab then #tab-controls in bundled index.html")
        check("mini new note (S9): the pinned cluster stays hidden in mini; the + rides the strip's own visibility",
              cssBlock(sourceAppCSS, selector: "body.mini-mode #tab-controls").contains("display: none")
              && cssBlock(appCSS, selector: "body.mini-mode #tab-controls").contains("display: none")
              && cssBlock(sourceAppCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #tabbar").contains("display: flex")
              && cssBlock(appCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #tabbar").contains("display: flex"),
              "source + bundled app.css hide #tab-controls in mini; the + returns with #tabbar itself")
        check("mini new note (S9): history and the redundant Full toggle stay hidden while only + returns",
              cssBlock(sourceAppCSS, selector: "body.mini-mode #history-button").contains("display: none")
              && cssBlock(sourceAppCSS, selector: "body.mini-mode #mini-enter").contains("display: none")
              && cssBlock(appCSS, selector: "body.mini-mode #history-button").contains("display: none")
              && cssBlock(appCSS, selector: "body.mini-mode #mini-enter").contains("display: none"),
              "mini history/full controls remain hidden in source + bundled app.css")
        check("mini new note (S9/L2): + is fixed beside the sole tab scroller and compact enough for the 30px strip",
              cssBlock(sourceAppCSS, selector: "#new-tab").contains("flex: 0 0 auto")
              && cssBlock(sourceAppCSS, selector: "#tabs").contains("overflow-x: auto")
              && cssBlock(sourceAppCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #new-tab").contains("height: 26px")
              && cssBlock(appCSS, selector: "#new-tab").contains("flex: 0 0 auto")
              && cssBlock(appCSS, selector: "#tabs").contains("overflow-x: auto")
              && cssBlock(appCSS, selector: "body.mini-mode.mini-hover:not(.blank-mode) #new-tab").contains("height: 26px"),
              "#tabs scrolls; the flex:0 26px + stays pinned in the 30px band")
        // The cluster is pinned to the RIGHT EDGE by an auto margin, not by the scroller growing into it. That
        // distinction IS the item: growth pinned everything, so the + could never sit beside the last tab.
        check("tab layout (L2): the hamburger/Mini cluster holds the right edge on its own auto margin",
              cssBlock(sourceAppCSS, selector: "#tab-controls").contains("flex: 0 0 auto")
              && cssBlock(sourceAppCSS, selector: "#tab-controls").contains("margin-left: auto")
              && cssBlock(appCSS, selector: "#tab-controls").contains("flex: 0 0 auto")
              && cssBlock(appCSS, selector: "#tab-controls").contains("margin-left: auto"),
              "#tab-controls flex:0 0 auto + margin-left:auto in source + bundled app.css")
        check("mini tab strip (L8): the grab handle and overlay move below the band, guarded so a note-less mini window leaves them put",
              appCSS.contains("body.mini-mode.mini-hover:not(.blank-mode) #mini-grab")
              && appCSS.contains("body.mini-mode.mini-hover:not(.blank-mode) #mini-overlay"),
              "top-edge chrome shifted by --mini-strip-h in app.css")
        check("mini tab strip (L8): the hover latch re-scrolls the active tab into the band (a scroll while display:none is a no-op)",
              appJS.contains(".tab.active")
              && NotesProbe.sourceRenderJS.contains("if (on && !miniHoverLatched && document.body.classList.contains(\"mini-mode\")) scrollActiveTabIntoView();"),
              "setMiniHover rising-edge scrollActiveTabIntoView in render.js + bundled app.js")

        // 12b-iv. the bundled JS actually posts the toggle inbound and latches the hover class.
        check("mini overlay: bundled JS posts the setManualMini toggle + drives the mini-hover latch",
              appJS.contains("setManualMini") && appJS.contains("mini-hover"))

        // 9-layout: the bundled tab render keeps the active tab on-screen when the strip overflows.
        check("tab layout (9): bundled JS scrolls the active tab into view on render",
              appJS.contains("scrollIntoView"),
              "renderTabs active-tab scrollIntoView in app.js")
    }

    static func probeMiniHoverFocus(check: Check) {
        // --- 12c. mini hover must not require window focus (S8) ---------------------------------------
        // Reported with a screen recording: "the hover only works whenever the sticky notes is the
        // currently foregrounded window... it should just always work when in mini mode."
        //
        // Root cause: every mini reveal hangs off `body.mini-hover`, and that class was set ONLY by the web
        // island's own mousemove/mouseleave on document.body. AppKit does not route mouse-moved events to a
        // window that is not key, so the WKWebView never saw them: the latch tracked WINDOW FOCUS, not the
        // pointer. The fix drives the same latch from Swift with an `.activeAlways` tracking area.
        //
        // The real pointer-over-an-inactive-app gesture is GUI/WindowServer-side (the user's hand-test + the review
        // link). What is asserted headlessly is the part that decides whether that gesture can work at all:
        // the tracking-area OPTION SET, the dedupe latch, the wiring from view callback to bridge push, and the
        // no-focus-steal invariant. Each of these is a way the fix silently degrades back into the bug.

        let webViewSrc = NotesProbe.sourceNotesWebView
        let controllerSrc = NotesProbe.sourceNotesWindowController
        let appJS = NotesProbe.bundledAppJS
        let appCSS = NotesProbe.bundledAppCSS

        // 12c-i. THE load-bearing assertion. `.activeInKeyWindow` reproduces the reported bug verbatim, and
        // `.activeInActiveApp` is the plausible-looking non-fix: it passes any same-app test and still fails
        // the user's actual case (hovering a mini note while working in a DIFFERENT application). Assert the option
        // that survives an inactive app, and assert the two near-misses are absent rather than merely unlisted.
        let options = NotesHoverTracking.options
        check("mini hover (S8): the tracking area is .activeAlways — live while ViddyDictate is NOT the active app",
              options.contains(.activeAlways),
              "NotesHoverTracking.options = \(options.rawValue)")
        check("mini hover (S8): neither near-miss option is used (.activeInKeyWindow IS the bug, .activeInActiveApp still fails the user's case)",
              !options.contains(.activeInKeyWindow) && !options.contains(.activeInActiveApp))
        check("mini hover (S8): enter AND exit are both tracked (an enter-only area latches the chrome on forever)",
              options.contains(.mouseEnteredAndExited))
        check("mini hover (S8): the tracked rect follows the view, so a resize cannot strand a stale rect",
              options.contains(.inVisibleRect))

        // 12c-ii. the constructed area really carries those options (the factory is the one construction site,
        // so a hand-rolled NSTrackingArea elsewhere would not inherit this guarantee — see 12c-iv).
        do {
            let owner = NSObject()
            let area = NotesHoverTracking.makeTrackingArea(bounds: NSRect(x: 0, y: 0, width: 280, height: 190),
                                                           owner: owner)
            check("mini hover (S8): a constructed tracking area reports .activeAlways + .mouseEnteredAndExited back",
                  area.options.contains(.activeAlways) && area.options.contains(.mouseEnteredAndExited))
            check("mini hover (S8): the factory owns the area (owner identity survives construction)",
                  area.owner as? NSObject === owner)
        }

        // 12c-iii. the dedupe latch. Enter/exit are not the only input: every tracking rebuild re-reads the
        // pointer directly, because a rebuild under a stationary pointer gets no enter event. That re-read
        // repeats the last state on nearly every live-resize tick, so the latch must collapse repeats to
        // nothing (a bridge call per resize tick) while still passing every real transition through.
        do {
            var latch = NotesHoverLatch()
            check("mini hover (S8): a fresh latch has pushed nothing", latch.current == nil)
            check("mini hover (S8): the first enter pushes true", latch.update(inside: true) == true)
            check("mini hover (S8): a repeated enter (resize re-read under a still pointer) pushes nothing",
                  latch.update(inside: true) == nil && latch.update(inside: true) == nil)
            check("mini hover (S8): the exit transition pushes false", latch.update(inside: false) == false)
            check("mini hover (S8): a repeated exit pushes nothing", latch.update(inside: false) == nil)
            check("mini hover (S8): re-entering after an exit pushes true again",
                  latch.update(inside: true) == true && latch.current == true)
            latch.reset()
            check("mini hover (S8): reset forgets the last push, so a reloaded island is re-seeded",
                  latch.current == nil && latch.update(inside: true) == true)
        }

        // 12c-iv. the view side: ONE construction site (the factory), the previous area removed before the new
        // one is added, and both enter and exit reported. A second hand-rolled NSTrackingArea in this file is
        // exactly how the .activeAlways guarantee above stops being true of the shipping view.
        let hoverSection = NotesProbe.sourceSlice(webViewSrc,
                                                  from: "var onPointerHoverChanged",
                                                  to: "/// Intercept Cmd+V ahead of the web content")
        check("mini hover (S8): the notes content view builds its area through the one factory, and nowhere else",
              hoverSection.contains("NotesHoverTracking.makeTrackingArea(bounds: bounds, owner: self)")
              && NotesProbe.countOccurrences(of: "NSTrackingArea(", in: webViewSrc) == 0,
              "no hand-rolled NSTrackingArea in NotesDropWebView.swift")
        check("mini hover (S8): the rebuild removes the previous area before adding the new one",
              NotesProbe.orderedBefore("removeTrackingArea(existing)", "addTrackingArea(area)", in: hoverSection))
        check("mini hover (S8): both enter and exit report through onPointerHoverChanged",
              hoverSection.contains("override func mouseEntered(with event: NSEvent) {")
              && hoverSection.contains("override func mouseExited(with event: NSEvent) {")
              && NotesProbe.countOccurrences(of: "onPointerHoverChanged?(true)", in: hoverSection) == 1
              && NotesProbe.countOccurrences(of: "onPointerHoverChanged?(false)", in: hoverSection) == 1)
        check("mini hover (S8): a rebuild re-reads the pointer, so an area installed UNDER the pointer still latches",
              hoverSection.contains("syncPointerHover()")
              && hoverSection.contains("bounds.contains(inView)"))

        // 12c-v. THE constraint a user would feel as a worse bug than the one being fixed: a hover that raises,
        // activates or keys the window would steal focus from whatever app is frontmost. Assert the whole push
        // path is inert. `mouseLocationOutsideOfEventStream` is a cached read and posts no events.
        let pushPath = NotesProbe.sourceSlice(controllerSrc,
                                              from: "private func pushPointerHover(",
                                              to: "private func handlePersistenceBridgeMessage")
        let focusStealers = ["makeKey", "orderFront", "activate", "makeFirstResponder", "focus()"]
        let stolen = focusStealers.filter { pushPath.contains($0) || hoverSection.contains($0) }
        check("mini hover (S8): the hover path never raises, activates, or keys the window",
              !pushPath.isEmpty && stolen.isEmpty,
              stolen.isEmpty ? "" : "focus-stealing call(s) on the hover path: \(stolen.joined(separator: ", "))")

        // 12c-vi. the wiring: the view callback reaches the bridge, the flip and a page reload re-seed it, and
        // the message is a real wire name. Bridge PARITY (Swift enum == JS MSG tables, source and bundled) is
        // already covered by probeBridgeParity, which now has miniHover in scope for free.
        check("mini hover (S8): miniHover is a wired outbound bridge message",
              NotesOutbound.allCases.contains(.miniHover))
        check("mini hover (S8): the window wires the view callback to the miniHover push",
              controllerSrc.contains("web.onPointerHoverChanged = { [weak self] inside in self?.pushPointerHover(inside) }")
              && pushPath.contains("call(.miniHover, payload: [BridgeKey.enabled: push])"))
        check("mini hover (S8): the mini/full flip rebuilds tracking (a state change AppKit cannot see)",
              controllerSrc.contains("(webView as? FirstMouseWebView)?.refreshHoverTracking()"))
        check("mini hover (S8): a page (re)load resets the latch and re-seeds from the live pointer",
              NotesProbe.orderedBefore("hoverLatch.reset()",
                                       "(webView as? FirstMouseWebView)?.syncPointerHover()",
                                       in: controllerSrc))

        // 12c-vii. the island end: the push lands on the SAME setter the fallback uses, so there is one latch
        // rather than two competing ones, and the JS fallback is still bound (removing it would make a
        // WebContent reload that races the Swift seed leave the chrome unreachable).
        check("mini hover (S8): the bundled island handles miniHover and routes it to the mini-hover latch",
              appJS.contains("miniHover") && appJS.contains("mini-hover"),
              "miniHover handler + body.mini-hover class in the bundled app.js")
        check("mini hover (S8): the source island maps miniHover onto the same setMiniHover the fallback calls",
              NotesProbe.sourceMainJS.contains("[MSG.outbound.miniHover]: (payload) => setMiniHover(payload && payload.enabled),"))
        check("mini hover (S8): the JS mousemove/mouseleave fallback is still bound",
              NotesProbe.sourceEventsJS.contains("document.body.addEventListener(\"mousemove\", () => setMiniHover(true));")
              && NotesProbe.sourceEventsJS.contains("document.body.addEventListener(\"mouseleave\", () => setMiniHover(false));"))

        // 12c-viii. the reveals this is FOR. If the CSS stopped hanging off body.mini-hover, everything above
        // could be green while nothing appeared on screen.
        check("mini hover (S8): the mini reveals still hang off body.mini-hover (overlay, grab handle, tray, tab strip)",
              appCSS.contains("body.mini-mode.mini-hover #mini-overlay")
              && appCSS.contains("body.mini-mode.mini-hover #mini-grab")
              && appCSS.contains("body.mini-mode.mini-hover #attachment-tray")
              && appCSS.contains("body.mini-mode.mini-hover:not(.blank-mode) #tabbar"))
    }

    /// Return the declaration block (text between the first `{` and its matching `}`) of the first CSS rule whose
    /// selector list contains `selector` as a standalone token — so `#mini-overlay {` is found but
    /// `body.mini-mode.mini-hover #mini-overlay {` (a different rule) is skipped. Brace-depth aware; empty on miss.
    static func cssBlock(_ css: String, selector: String) -> String {
        var searchStart = css.startIndex
        while let sel = css.range(of: selector, range: searchStart..<css.endIndex) {
            // Find the next brace and the next selector-terminating chars; a bare rule has `selector {` with only
            // whitespace between. Reject when a combinator/comma sits between this token and the `{`.
            guard let open = css[sel.upperBound...].firstIndex(of: "{") else { return "" }
            let between = css[sel.upperBound..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            if between.isEmpty {
                var depth = 0
                var i = open
                var body = ""
                while i < css.endIndex {
                    let c = css[i]
                    if c == "{" { depth += 1; if depth > 1 { body.append(c) } }
                    else if c == "}" { depth -= 1; if depth == 0 { return body }; body.append(c) }
                    else { body.append(c) }
                    i = css.index(after: i)
                }
                return body
            }
            searchStart = sel.upperBound
        }
        return ""
    }

}
