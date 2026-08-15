import Foundation
import AppKit

extension NotesProbe {
    static func probeTabDragRail(freshRoot: () -> URL, check: Check) {
        // --- 12. tab drag rail (L7): drop-index helper + reorder round-trip ---------------------
        // The drag is UI-bearing (NSEvent monitor + ghost + cross-window hit-test), but its two
        // deterministic pieces ARE probe-tested: the pure insertion-index formula that Swift commits with
        // (and the JS indicator mirrors), and the store-visible effect of a reorder — the reordered tabOrder
        // flips _open-notes.md while keeping exactly one active marker on the unchanged active tab.

        // 12a. insertionIndex = count of tab midpoints strictly left of the cursor x, SCROLL-AWARE (round-5 R3,
        // item-9): `#tabs` is a horizontal scroller, so the fixture carries content-frame mids + a live
        // `scrollOffset` the formula folds in. Swift and JS both verify against
        // Web/StickyNotes/fixtures/insertion-index.json so indicator/commit drift — and scroll parity — go red.
        // (scrollOffset absent/0 exercises the plain unscrolled path, unchanged from pre-R3.)
        do {
            let fixtures = try loadInsertionIndexFixtures()
            for fixture in fixtures {
                let actual = NotesWindowRegistry.insertionIndex(mids: fixture.midpoints, x: fixture.x,
                                                                scrollOffset: fixture.scrollOffset ?? 0)
                check("drop index fixture: \(fixture.name)",
                      actual == fixture.expected,
                      actual == fixture.expected ? "" : "expected \(fixture.expected), got \(actual)")
            }
        } catch {
            check("drop index fixtures: shared fixture table loads", false, "\(error)")
        }

        // 12b. reorder round-trip: a reordered tabOrder flips the aggregate; the active tab (unchanged by a
        // reorder) keeps the single (active) marker
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-a", body: "# Alpha\na")
            store.saveOpenNote(id: "note-b", body: "# Bravo\nb")
            store.saveOpenNote(id: "note-c", body: "# Charlie\nc")
            let aggURL = store.root.appendingPathComponent("_open-notes.md")
            store.rewriteAggregate(tabOrder: ["note-a", "note-b", "note-c"], activeId: "note-b")
            let before = (try? String(contentsOf: aggURL, encoding: .utf8)) ?? ""
            check("reorder: initial order (Alpha, Bravo, Charlie)",
                  orderedBefore("## Alpha", "## Bravo", in: before)
                  && orderedBefore("## Bravo", "## Charlie", in: before))
            // Simulate the JS reorder posting the new tabOrder (Charlie dragged to front), same active tab.
            store.rewriteAggregate(tabOrder: ["note-c", "note-a", "note-b"], activeId: "note-b")
            let after = (try? String(contentsOf: aggURL, encoding: .utf8)) ?? ""
            check("reorder: new order persists (Charlie, Alpha, Bravo)",
                  orderedBefore("## Charlie", "## Alpha", in: after)
                  && orderedBefore("## Alpha", "## Bravo", in: after))
            check("reorder: still exactly one active marker, on the unchanged active tab (Bravo)",
                  after.contains("## Bravo (active)")
                  && countOccurrences(of: " (active)", in: after) == 1)
        }

        // --- 9-layout (notes-9-layout): tab overflow scroll + pinned control cluster -----------------
        // The +/history/collapse-to-mini controls are wrapped in a flex:0 0 auto #tab-controls so they stay
        // always-visible, while #tabs becomes the SOLE overflow-x scroller (no fragile max-width:calc that
        // drifted whenever the control count/width changed). The pixel/interaction confirm is GUI-side
        // (covered by real-app verification); pin the shipping markup + CSS contract here.
        //
        // The layout narrowed the scroller from `flex: 1 1 auto` to `flex: 0 1 auto`. A scroller that GROWS eats
        // every leftover pixel, which parked the + at the window edge whether or not the tabs overflowed —
        // the user's defect. Shrink-only makes the width min(max-content, available), so the + sits beside the last
        // tab when the tabs fit and detaches to its own always-visible lane when they do not. The grow half is
        // asserted ABSENT here, not just the new value present, because restoring it silently restores the bug.
        let layoutHTML: String
        let layoutCSS = NotesProbe.bundledAppCSS
        if let resURL = Bundle.main.resourceURL {
            layoutHTML = (try? String(contentsOf: resURL.appendingPathComponent("StickyNotes/index.html"), encoding: .utf8)) ?? ""
        } else {
            layoutHTML = ""
        }
        check("tab layout (9): bundled index.html wraps the controls in id=\"tab-controls\"",
              layoutHTML.contains("id=\"tab-controls\""),
              "Resources/StickyNotes/index.html")
        check("tab layout (9): #tab-controls is pinned flex:0 0 auto (always visible, never pushed off-strip)",
              cssBlock(layoutCSS, selector: "#tab-controls").contains("flex: 0 0 auto"),
              "#tab-controls flex:0 0 auto in app.css")
        check("tab layout (9): #tabs is the sole scroller (overflow-x:auto), no fragile calc",
              cssBlock(layoutCSS, selector: "#tabs").contains("overflow-x: auto")
              && !cssBlock(layoutCSS, selector: "#tabs").contains("calc("),
              "#tabs overflow-x:auto without max-width:calc in app.css")
        check("tab layout (L2): #tabs shrinks but never GROWS, so the + follows the last tab instead of the window edge",
              cssBlock(layoutCSS, selector: "#tabs").contains("flex: 0 1 auto")
              && !cssBlock(layoutCSS, selector: "#tabs").contains("flex: 1 1 auto")
              && cssBlock(layoutCSS, selector: "#tabs").contains("min-width: 0"),
              "#tabs flex:0 1 auto + min-width:0 in app.css")
    }

    static func probeCrossWindowMoves(fm: FileManager, freshRoot: () -> URL, check: Check) {
        // --- 13. cross-window tab moves (L8): dock + drag-out membership moves --------------------
        // Dock and drag-out are UI-bearing (the target/new window computes its own insertion index from the
        // strip-local x, mirroring the indicator; the drop-index formula itself is already probe-tested in
        // 12a). What IS store-visible — and asserted here as the L6 cases were — is the RESULT of a move: the
        // note ends up in the other window's membership, the aggregate re-orders window-then-tab with the
        // single (active) marker following the note, and an emptied secondary source is pruned. Each case
        // constructs the post-move memberships the live controllers would report, then drives the real store
        // writer + pure pruning helper.

        // 13a. DOCK: a note moves from a secondary source into the (primary) target at a computed index; the
        // target becomes the active window, so the single marker follows the docked note; the emptied
        // secondary source is pruned.
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-a", body: "# Alpha\na")
            store.saveOpenNote(id: "note-b", body: "# Bravo\nb")
            store.saveOpenNote(id: "note-c", body: "# Charlie\nc")
            // Post-move: note-a docked into the primary between Bravo and Charlie; the secondary is now empty.
            let moved = [
                WindowMembership(id: "window-primary", noteIds: ["note-b", "note-a", "note-c"],
                                 activeId: "note-a", frame: nil),
                WindowMembership(id: "window-2", noteIds: [], activeId: nil, frame: nil),
            ]
            store.rewriteAggregate(windows: moved, activeWindowId: "window-primary")
            let agg = (try? String(contentsOf: store.root.appendingPathComponent("_open-notes.md"), encoding: .utf8)) ?? ""
            check("dock: docked note lands at the computed index (Bravo, Alpha, Charlie)",
                  orderedBefore("## Bravo", "## Alpha", in: agg)
                  && orderedBefore("## Alpha", "## Charlie", in: agg))
            check("dock: the single (active) marker follows the docked note into the target (Alpha)",
                  agg.contains("## Alpha (active)")
                  && countOccurrences(of: " (active)", in: agg) == 1)
            check("dock: the emptied secondary source is pruned; the primary is kept",
                  NotesWindowRegistry.prunedWindows(moved, primaryId: "window-primary").map(\.id) == ["window-primary"])
        }

        // 13b. DRAG-OUT: a note moves out of the primary into a brand-new secondary window holding just that
        // note; the new window is the active window, so the single marker is on it; the source keeps the rest.
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-a", body: "# Alpha\na")
            store.saveOpenNote(id: "note-b", body: "# Bravo\nb")
            let moved = [
                WindowMembership(id: "window-primary", noteIds: ["note-b"], activeId: "note-b", frame: nil),
                WindowMembership(id: "window-new", noteIds: ["note-a"], activeId: "note-a", frame: "{{0, 0}, {900, 640}}"),
            ]
            check("drag-out: the new window holds exactly the dragged note; the source keeps the rest",
                  moved[1].noteIds == ["note-a"] && moved[0].noteIds == ["note-b"])
            store.rewriteAggregate(windows: moved, activeWindowId: "window-new")
            let agg = (try? String(contentsOf: store.root.appendingPathComponent("_open-notes.md"), encoding: .utf8)) ?? ""
            check("drag-out: aggregate keeps window-then-tab order (source Bravo before the new window's Alpha)",
                  orderedBefore("## Bravo", "## Alpha", in: agg))
            check("drag-out: the single (active) marker is on the new window's note (Alpha)",
                  agg.contains("## Alpha (active)")
                  && countOccurrences(of: " (active)", in: agg) == 1)
        }

        // 13c. DRAG-OUT emptying a SECONDARY source prunes it (dragging a secondary's only tab out to a new
        // window leaves the secondary with no tabs); the primary and the non-empty new window survive.
        do {
            let afterMove = [
                WindowMembership(id: "window-primary", noteIds: ["note-x"], activeId: "note-x", frame: nil),
                WindowMembership(id: "window-2", noteIds: [], activeId: nil, frame: nil),
                WindowMembership(id: "window-new", noteIds: ["note-a"], activeId: "note-a", frame: nil),
            ]
            check("drag-out: an emptied secondary source is pruned, primary + non-empty new window kept",
                  NotesWindowRegistry.prunedWindows(afterMove, primaryId: "window-primary").map(\.id)
                  == ["window-primary", "window-new"])
        }

        // 13d. DRAG-OUT of an empty JS-only tab: the target window can be seeded from the drag payload even
        // though the note is absent from openNotes(), and that does not materialize a .md until text arrives.
        do {
            let store = StickyNotesStore(root: freshRoot())
            let emptyURL = store.root.appendingPathComponent("note-empty.md")
            let transient = StickyNoteWire(id: "note-empty", body: "", title: "")
            let missing = NotesTransientTabs.resolveInitialNotes(allOpen: store.openNotes(),
                                                                 desired: ["note-empty"],
                                                                 transient: [:])
            check("drag-out empty: a non-materialized desired id alone still resolves to no tab",
                  missing.ids.isEmpty && missing.notes.isEmpty)

            let resolved = NotesTransientTabs.resolveInitialNotes(allOpen: store.openNotes(),
                                                                  desired: ["note-empty"],
                                                                  transient: ["note-empty": transient])
            check("drag-out empty: transient drag payload seeds the new window's empty tab",
                  resolved.ids == ["note-empty"]
                  && resolved.notes.count == 1
                  && resolved.notes.first?.id == "note-empty"
                  && resolved.notes.first?.body == ""
                  && resolved.notes.first?.title == "")
            check("drag-out empty: the transient tab can be the active tab",
                  NotesTransientTabs.resolveActiveId(lastActive: "note-empty", noteIds: resolved.ids)
                  == "note-empty")
            check("drag-out empty: transient seeding does not materialize a markdown file",
                  store.openNotes().isEmpty && !fm.fileExists(atPath: emptyURL.path))

            store.saveOpenNote(id: "note-empty", body: "# Materialized\nbody")
            let materialized = NotesTransientTabs.resolveInitialNotes(allOpen: store.openNotes(),
                                                                     desired: ["note-empty"],
                                                                     transient: ["note-empty": transient])
            check("drag-out empty: once text materializes, the store-backed body wins over stale transient state",
                  materialized.notes.first?.body == "# Materialized\nbody")
        }
    }

    static func probeDropCoordinator(freshRoot: () -> URL, check: Check) {
        // --- 14. drop coordinator: the pure committed-drop outcome truth table (round-5 R1; ADR 0011) -------
        // `NotesDropCoordinator.decide` is the single owner of the committed-drop outcome, consolidated out of
        // the pre-round-5 three-file spread (NotesTabDrag.finish + windowStrip + the content path). R1 is a
        // ZERO-behavior refactor; these pins are the proof. Escape / gesture cancel never reaches decide (the
        // gesture shell handles it), so there is no cancel case here.
        typealias Geo = NotesDropCoordinator.WindowGeo
        func geo(_ id: String, _ rect: NSRect, mids: [CGFloat] = [], zIndex: Int,
                 active: String? = nil, mini: Bool = false, scroll: CGFloat = 0) -> Geo {
            Geo(id: id, stripRect: rect, isMini: mini, tabMids: mids, scrollOffset: scroll, zIndex: zIndex,
                activeNoteId: active)
        }
        func decideTab(source: String, at p: NSPoint, mids: [CGFloat],
                       _ windows: [Geo]) -> NotesDropCoordinator.DropOutcome {
            NotesDropCoordinator.decide(NotesDropCoordinator.DropQuery(
                endpoint: p, sourceWindowId: source,
                kind: .tab(noteId: "note-x", mids: mids, grabOffset: .zero), windows: windows))
        }

        let stripA = NSRect(x: 0, y: 0, width: 300, height: 42)
        let stripB = NSRect(x: 400, y: 0, width: 300, height: 42)
        let mids: [CGFloat] = [50, 150, 250]

        // 14a. same-window strip -> reorder at the strip-local insertion index (source mids: {50} < 120 -> 1).
        do {
            let a = geo("A", stripA, mids: mids, zIndex: 2)
            let b = geo("B", stripB, mids: mids, zIndex: 1)
            let out = decideTab(source: "A", at: NSPoint(x: 120, y: 20), mids: mids, [a, b])
            check("drop decide: same-window strip -> reorder at the local index",
                  out == .reorder(windowId: "A", toIndex: 1), "got \(out)")
        }

        // 14b. another window's strip -> dock at THAT window's strip-local index (its own tabMids; localX in B
        // = 560-400 = 160 -> {50,150} < 160 -> 2).
        do {
            let a = geo("A", stripA, mids: mids, zIndex: 2)
            let b = geo("B", stripB, mids: mids, zIndex: 1)
            let out = decideTab(source: "A", at: NSPoint(x: 560, y: 20), mids: mids, [a, b])
            check("drop decide: another window's strip -> dock at the target-local index",
                  out == .dock(windowId: "B", toIndex: 2), "got \(out)")
        }

        // 14c. OVERLAP: two strips overlap under the cursor. decide picks the higher-zIndex window, AND that
        // equals the pre-round-5 controllers-order (first-containing) result — the zero-behavior seam. R1
        // assigns zIndex from the controllers order (first controller = highest), so the two agree. The final
        // pin proves the seam is real: sourcing zIndex from the true front-to-back order (R2) flips the winner.
        do {
            let overlap = NSRect(x: 0, y: 0, width: 300, height: 42)
            let p = NSPoint(x: 120, y: 20)
            // controllers order [top, bot] -> R1 zIndex top=2 (highest), bot=1. Source is a third window not
            // under the cursor, so this is a dock, not a reorder.
            let top = geo("top", overlap, mids: mids, zIndex: 2)
            let bot = geo("bot", overlap, mids: mids, zIndex: 1)
            let out = decideTab(source: "src", at: p, mids: mids, [top, bot])
            let controllersOrderWinner = [top, bot].first { $0.stripRect.contains(p) }?.id
            check("drop decide: overlap resolves to the higher-zIndex window",
                  out == .dock(windowId: "top", toIndex: 1), "got \(out)")
            check("drop decide: R1 overlap winner == pre-round-5 controllers-order (first-containing) result",
                  controllersOrderWinner == "top" && out == .dock(windowId: "top", toIndex: 1))
            let topFlipped = geo("top", overlap, mids: mids, zIndex: 1)
            let botFlipped = geo("bot", overlap, mids: mids, zIndex: 2)
            let flipped = decideTab(source: "src", at: p, mids: mids, [topFlipped, botFlipped])
            check("drop decide: the zIndex seam is real — a flipped z-order flips the overlap winner (R2's job)",
                  flipped == .dock(windowId: "bot", toIndex: 1), "got \(flipped)")
        }

        // 14d. dropped clear of every strip -> a new window at the drop point.
        do {
            let a = geo("A", stripA, mids: mids, zIndex: 2)
            let b = geo("B", stripB, mids: mids, zIndex: 1)
            let p = NSPoint(x: 5000, y: 5000)
            let out = decideTab(source: "A", at: p, mids: mids, [a, b])
            check("drop decide: outside every strip -> new window at the drop point",
                  out == .newWindow(point: p), "got \(out)")
        }

        // 14e. same-window drop whose source mids never resolved -> snap back (failed geometry query).
        do {
            let a = geo("A", stripA, mids: [], zIndex: 2)
            let out = decideTab(source: "A", at: NSPoint(x: 120, y: 20), mids: [], [a])
            check("drop decide: same-window drop with empty source mids -> snap back",
                  out == .snapBack, "got \(out)")
        }

        // 14f. content arm -> attach to the source window's active note, regardless of key (decide has no key
        // concept; WindowGeo carries no key flag — it returns the window's active note unconditionally). A
        // SEPARATE arm from the tab outcomes: it never snaps back or spawns a window.
        do {
            let a = geo("A", stripA, zIndex: 2, active: "note-active")
            let out = NotesDropCoordinator.decide(NotesDropCoordinator.DropQuery(
                endpoint: .zero, sourceWindowId: "A", kind: .content([]), windows: [a]))
            check("drop decide: content drop -> attach to the source window's active note (regardless of key)",
                  out == .attachContent(windowId: "A", noteId: "note-active"), "got \(out)")
            let blank = geo("A", stripA, zIndex: 2, active: nil)
            let outNil = NotesDropCoordinator.decide(NotesDropCoordinator.DropQuery(
                endpoint: .zero, sourceWindowId: "A", kind: .content([]), windows: [blank]))
            check("drop decide: content drop with no active note -> attachContent(nil), still no snap-back",
                  outNil == .attachContent(windowId: "A", noteId: nil as String?), "got \(outNil)")
        }

        // 14g. Z-ORDER FLIP (round-5 R2): the SHELL now sources overlap zIndex from the TRUE front-to-back
        // window order (NSApp.orderedWindows) instead of the controllers-array order, so the VISUALLY FRONTMOST
        // window wins an overlap-region drop. The live NSApp order can't run headlessly, but the pure ranking it
        // feeds — `overlapZIndices` — can: pin that it FLIPS the winner when the front-to-back order diverges
        // from the array order, PRESERVES it when they agree, and sinks unordered windows behind ordered ones.
        do {
            let overlap = NSRect(x: 0, y: 0, width: 300, height: 42)
            let p = NSPoint(x: 120, y: 20)               // over both overlapping strips
            // windows array [top, bot] (controllers order). CASE A — `bot` is visually in front (front-to-back
            // ranks [1, 0]): overlapZIndices lifts bot above top, so decide docks into `bot` — a FLIP from R1's
            // controllers order (which docked into `top`, the first-containing window).
            let zFlip = NotesDropCoordinator.overlapZIndices(frontToBackRanks: [1, 0])
            let topFlip = geo("top", overlap, mids: mids, zIndex: zFlip[0])
            let botFlip = geo("bot", overlap, mids: mids, zIndex: zFlip[1])
            let flipped = decideTab(source: "src", at: p, mids: mids, [topFlip, botFlip])
            check("z-order flip: shell zIndex from front-to-back order docks into the visually-frontmost window (flips R1)",
                  zFlip == [-1, 0] && flipped == .dock(windowId: "bot", toIndex: 1), "z=\(zFlip) out=\(flipped)")
            // CASE B — `top` is visually in front (ranks [0, 1]): the front-to-back order matches the array
            // order, so the winner is UNCHANGED from R1 (top). The flip only bites when the two orders diverge.
            let zSame = NotesDropCoordinator.overlapZIndices(frontToBackRanks: [0, 1])
            let topSame = geo("top", overlap, mids: mids, zIndex: zSame[0])
            let botSame = geo("bot", overlap, mids: mids, zIndex: zSame[1])
            let same = decideTab(source: "src", at: p, mids: mids, [topSame, botSame])
            check("z-order flip: when front-to-back matches the controllers order, the overlap winner is unchanged (top)",
                  zSame == [0, -1] && same == .dock(windowId: "top", toIndex: 1), "z=\(zSame) out=\(same)")
            // A not-yet-ordered window (rank nil) sinks behind every ordered window, and array order breaks ties
            // among unordered windows — the R1 controllers-order fallback, so it never steals an overlap.
            check("z-order flip: unordered windows sink behind ordered ones; array order breaks ties among them",
                  NotesDropCoordinator.overlapZIndices(frontToBackRanks: [nil, 0]) == [-1, 0]
                  && NotesDropCoordinator.overlapZIndices(frontToBackRanks: [nil, nil]) == [0, -1])
        }

        // 14h. MINI DRAG-OUT (round-5 R2, item 7b): grabbing a mini note posts a normal `.tab` drag through the
        // SAME coordinator (the mini strip's tabs are display:none, so the grab handle IS the drag-out — there
        // is no separate "drag a tab out"). decide treats a mini SOURCE no differently: dropped on another
        // window's strip -> dock; dropped clear of every strip -> new window. The grab handle + the live
        // cross-window drag are GUI-side; decide's outcome is what is pinned here.
        do {
            let src = geo("M", stripA, mids: mids, zIndex: 2, mini: true)     // mini source window
            let dst = geo("B", stripB, mids: mids, zIndex: 1)
            let dock = decideTab(source: "M", at: NSPoint(x: 560, y: 20), mids: mids, [src, dst])
            check("mini drag-out: a grab-started drag from a mini window docks onto another window's strip",
                  dock == .dock(windowId: "B", toIndex: 2), "got \(dock)")
            let out = decideTab(source: "M", at: NSPoint(x: 5000, y: 5000), mids: mids, [src, dst])
            check("mini drag-out: dropped clear of every strip -> a new window",
                  out == .newWindow(point: NSPoint(x: 5000, y: 5000)), "got \(out)")
        }

        // 14i. DOCK INTO A MINI WINDOW (round-5 R2): a mini target has no visible tab slots, so decide applies
        // the forgiving rule — append to the END (`.dock` at the target's tab count), never a mid-index, never
        // snap-back — regardless of where in its band the cursor lands. A NON-mini target with the SAME geometry
        // aims at the precise slot, proving the mini rule (not the localX math) is what bites.
        do {
            let miniTarget = geo("M", stripB, mids: [50, 150], zIndex: 1, mini: true)   // 2 tabs
            let src = geo("A", stripA, mids: mids, zIndex: 2)
            // localX in B = 500 - 400 = 100, a "precise slot" (between mids 50 and 150 -> index 1) for a full
            // window; the mini rule ignores it and appends to the END (count == 2).
            let out = decideTab(source: "A", at: NSPoint(x: 500, y: 20), mids: mids, [src, miniTarget])
            check("dock into mini: forgiving last-tab -> .dock(window, count) appends to the END (ignores the slot)",
                  out == .dock(windowId: "M", toIndex: 2), "got \(out)")
            let full = geo("M", stripB, mids: [50, 150], zIndex: 1)                     // same geometry, NOT mini
            let outFull = decideTab(source: "A", at: NSPoint(x: 500, y: 20), mids: mids, [src, full])
            check("dock into mini: a NON-mini target with the same geometry aims at the precise slot (mini rule bites)",
                  outFull == .dock(windowId: "M", toIndex: 1), "got \(outFull)")
        }

        // 14j. DOCK INTO A MINI WINDOW STAYS MINI (round-5 R2): the dock executor (dockNote ->
        // rememberTransientTab + insertDockedTab) never touches the window's manual-mini flag, so a note docked
        // into a mini window leaves it mini — no auto-flip to full. Drive the target-side dock mutations on a
        // real headless controller and assert its persisted manualMini is unchanged. (isEffectiveMini is always
        // true headlessly — a nil window has contentWidth 0 < 560 — so the persisted manualMini flag is the
        // honest invariant to pin here.)
        do {
            let store = StickyNotesStore(root: freshRoot())
            let target = NotesWindowController(store: store, windowId: "window-mini-dock",
                                               isPrimary: false, initialManualMini: true)
            check("dock into mini: the target starts mini (manualMini true)", target.membership.manualMini == true)
            let docked = StickyNoteWire(id: "docked", body: "hi", title: "Docked")
            target.rememberTransientTab(docked)
            target.insertDockedTab(docked, localX: 999)
            check("dock into mini: docking a tab leaves manualMini untouched (window stays mini, no auto-flip to full)",
                  target.membership.manualMini == true)
        }

        // 14k. SCROLL-AWARE tab index (round-5 R3, item-9): the wave-1 notes strip is a horizontal scroller, and
        // the source mids are captured ONCE at drag start; if the strip scrolls mid-drag the cached mids/localX
        // go stale. decide folds the hit strip's LIVE scrollOffset into the index (a tab at content-mid m draws
        // at viewport m - scrollOffset, so it sits left of the cursor iff m < localX + scrollOffset). A drop past
        // every drawn tab lands at count — the forgiving last-tab default for an overflowing strip. The live
        // scroll RE-QUERY mid-drag is GUI-side (covered by real-app verification); the pure offset math is pinned here.
        do {
            // Source strip A scrolled right by 120. Content mids {50,150,250}; cursor localX 40 -> effective
            // 40+120 = 160 -> {50,150} left of it -> reorder index 2.
            let scrolledSource = geo("A", stripA, mids: mids, zIndex: 2, scroll: 120)
            let b = geo("B", stripB, mids: mids, zIndex: 1)
            let out = decideTab(source: "A", at: NSPoint(x: 40, y: 20), mids: mids, [scrolledSource, b])
            check("scroll-aware reorder: decide folds the source strip's live scrollOffset into the reorder index",
                  out == .reorder(windowId: "A", toIndex: 2), "got \(out)")
            // Control — the SAME cursor with NO scroll lands at a different index (0), proving the scroll (not
            // the localX) is what moved the answer.
            let unscrolled = geo("A", stripA, mids: mids, zIndex: 2)
            let ctrl = decideTab(source: "A", at: NSPoint(x: 40, y: 20), mids: mids, [unscrolled, b])
            check("scroll-aware reorder: the same cursor unscrolled lands elsewhere (scroll, not localX, moves it)",
                  ctrl == .reorder(windowId: "A", toIndex: 0), "got \(ctrl)")
            // Beyond the last visible tab under scroll -> forgiving last-tab (reorder at count, never a mid-index,
            // never snap-back). Source scrolled 150; cursor localX 200 -> effective 350 -> all mids left -> 3.
            let beyondSource = geo("A", stripA, mids: mids, zIndex: 2, scroll: 150)
            let beyond = decideTab(source: "A", at: NSPoint(x: 200, y: 20), mids: mids, [beyondSource, b])
            check("scroll-aware reorder: a drop beyond the last visible tab -> forgiving last-tab (index == count)",
                  beyond == .reorder(windowId: "A", toIndex: mids.count), "got \(beyond)")
            // Cross-window dock onto a SCROLLED target is scroll-aware too: target localX = 560-400 = 160;
            // +scroll 100 -> effective 260 -> all mids {50,150,250} left -> dock at 3 (count). The target island
            // recomputes live at dock time; the pure decide index stays honest under scroll.
            let scrolledTarget = geo("B", stripB, mids: mids, zIndex: 1, scroll: 100)
            let a = geo("A", stripA, mids: mids, zIndex: 2)
            let dockOut = decideTab(source: "A", at: NSPoint(x: 560, y: 20), mids: mids, [a, scrolledTarget])
            check("scroll-aware dock: decide folds the target strip's scrollOffset into the dock index",
                  dockOut == .dock(windowId: "B", toIndex: 3), "got \(dockOut)")
        }
    }

}
