import Cocoa

/// Document view for the workstation composition: flipped so segments stack top-down in the order the
/// model receives them.
private final class PromptCompositionView: NSView {
    override var isFlipped: Bool { true }
}

/// How a workstation Test run reaches a provider, and where its sample comes from (item W2).
///
/// Both collaborators are injectable for one reason: a gate has to be able to drive the REAL Test
/// button through the REAL result path without a provider running and without reading the machine's
/// own dictation history. Production supplies neither, which is itself the thing the gate asserts —
/// `runner == nil` means the sheet dispatches through `CustomModeClient.run`, the same call a live
/// take makes.
struct PromptTestBenchConfig {
    typealias Runner = (CustomMode, String, @escaping (CleanupClient.Result) -> Void) -> Void

    /// The mode being tuned. Its route decides which provider and model a test runs against; the
    /// prompt a test runs is the one currently in the editable region, not this descriptor's stored one.
    var mode: CustomMode
    /// Newest-first history, consulted once to seed the sample field.
    var history: () -> [TranscriptionHistory.Entry] = { TranscriptionHistory.shared.all() }
    /// nil means production: `CustomModeClient.run(_:input:arming:.inert)`.
    var runner: Runner?

    init(mode: CustomMode,
         history: @escaping () -> [TranscriptionHistory.Entry] = { TranscriptionHistory.shared.all() },
         runner: Runner? = nil) {
        self.mode = mode
        self.history = history
        self.runner = runner
    }
}

/// The "Edit prompt" surface for the Models & Power page. Two shapes, one object:
///
/// - **Plain editor** (every built-in route/variant): a titled sheet with an `NSTextView`, Restore /
///   Cancel / Save. A mode's long system prompt is edited off the card row (glossary "Hotkeys page").
/// - **Prompt workstation** (a custom mode's shared task prompt, items W1 + W2): the same sheet, but it
///   renders the ASSEMBLED prompt instead of a bare box — the `<<<TRANSCRIPT>>>` / `<<<END_TRANSCRIPT>>>`
///   marker block drawn verbatim in its real position, with the editable region inline and still fully
///   editable — and carries a Test bench underneath it. Show-and-teach, not hide-and-protect.
///
/// The workstation's scaffold is never hand-written here: it comes from `PromptAssembly`, which derives
/// it from the same functions the run itself uses. The panel claims the composition is literally what
/// gets sent, so that claim is structural rather than a promise this file has to keep by hand. The
/// scaffold is presentation only: Save hands back the editable region's bytes and nothing else, so
/// opening the panel and saving without typing leaves a stored prompt byte-identical.
///
/// The Test bench (W2) runs the mode's real provider and model against a real sample and LANDS NOTHING:
/// no paste, no note, no clipboard write, no History entry, no bullseye, no undo. It reaches that by not
/// holding a delivery collaborator at all — it calls the transform half (`CustomModeClient.run`) and
/// draws the answer. See `PromptTestBench` for the sourcing rules and the wording.
///
/// `shippedDefault` is what makes Restore honest: with it the sheet can SHOW the bytes this build
/// ships, so restoring is "look at the default, then keep it" rather than "delete everything and hope".
/// The sheet never decides what saving those bytes means. A built-in prompt store clears an override
/// when the text matches the shipped bytes; a custom mode stores the restored new-mode default verbatim.
/// It retains itself for the sheet's lifetime so the caller does not have to.
final class PromptEditorSheet: NSObject, NSTextViewDelegate {
    private var retain: PromptEditorSheet?
    private var sheet: NSWindow!
    private var textView: NSTextView!
    private let shippedDefault: String?
    private let assembly: PromptAssemblyLayout?
    private let bench: PromptTestBenchConfig?
    private let assemblyNoteText: String
    private let userRoleTitle: String
    private let onSave: (String) -> Void

    private var restoreButton: NSButton?
    private var compositionScroll: NSScrollView?
    private var compositionDoc: PromptCompositionView?

    // MARK: Test bench state (workstation only)

    private var sampleView: NSTextView?
    private var sampleSeed = PromptTestBench.Seed.none
    private var sourceField: NSTextField?
    private var reseedButton: NSButton?
    private var testButton: NSButton?
    private var testStatus: NSTextField?
    private var resultView: NSTextView?
    /// Identifies the run currently on the wire. A result whose token is stale — the user pressed Test
    /// again, or closed the panel — is dropped rather than drawn, so a slow provider can never repaint
    /// a panel that has moved on.
    private var runToken: UUID?
    /// Every composition row in visual order, with the gap that follows it.
    private var compositionRows: [(view: NSView, gapAfter: CGFloat)] = []
    /// The system- and user-message segment views only (role headers excluded), in visual order, so a
    /// gate can read what is ON SCREEN back out and compare it to what a real run would send.
    private var systemSegmentViews: [NSView] = []
    private var userSegmentViews: [NSView] = []

    /// The one line the workstation says about itself. It is a strong claim, which is why the scaffold
    /// is derived rather than transcribed.
    static let assemblyNote = "This is the whole prompt exactly as it is sent. Only the box you can "
        + "type in is saved to this hotkey. The dim lines are added by the app every run, and your "
        + "dictation replaces the marked line between the markers."

    static let stickySkillAssemblyNote = "This is the whole prompt shape the sticky skill sends. Only "
        + "the box you can type in is saved. The dim task addendum and data fence are added by the app "
        + "every run; the current note title, attachments, and body replace the marked placeholders."

    private init(shippedDefault: String?, assembly: PromptAssemblyLayout?,
                 bench: PromptTestBenchConfig? = nil,
                 assemblyNoteText: String = PromptEditorSheet.assemblyNote,
                 userRoleTitle: String = "USER MESSAGE (your dictation, fenced as data)",
                 onSave: @escaping (String) -> Void) {
        self.shippedDefault = shippedDefault
        self.assembly = assembly
        self.bench = bench
        self.assemblyNoteText = assemblyNoteText
        self.userRoleTitle = userRoleTitle
        self.onSave = onSave
    }

    /// Present the editor on `parent`, seeded with `text`, calling `onSave` with the edited text if the
    /// user saves (never on cancel).
    static func present(on parent: NSWindow, title: String, subtitle: String? = nil, text: String,
                        shippedDefault: String? = nil,
                        restoreButtonTitle: String = "Restore shipped default",
                        onSave: @escaping (String) -> Void) {
        let s = PromptEditorSheet(shippedDefault: shippedDefault, assembly: nil, onSave: onSave)
        s.retain = s
        s.build(title: title, subtitle: subtitle, text: text,
                restoreButtonTitle: restoreButtonTitle)
        parent.beginSheet(s.sheet, completionHandler: nil)
    }

    /// Build the real sheet WITHOUT presenting it, so a probe can drive Restore/Save through the same
    /// controls a user clicks. Nothing here is test-only behavior: the returned object is the object
    /// `present` would have shown.
    static func makeForTesting(title: String, subtitle: String? = nil, text: String,
                               shippedDefault: String?,
                               restoreButtonTitle: String = "Restore shipped default",
                               onSave: @escaping (String) -> Void) -> PromptEditorSheet {
        let s = PromptEditorSheet(shippedDefault: shippedDefault, assembly: nil, onSave: onSave)
        s.build(title: title, subtitle: subtitle, text: text,
                restoreButtonTitle: restoreButtonTitle)
        return s
    }

    // MARK: - Prompt workstation (custom modes)

    /// The workstation for one custom mode's shared task prompt. `present` and the probes go through
    /// this single builder, so there is no second configuration to drift. The panel opens on the mode's
    /// STORED prompt; `bench` decides what a Test run reaches, and defaults to production.
    static func customModeWorkstation(title: String, mode: CustomMode,
                                      bench: PromptTestBenchConfig? = nil,
                                      onSave: @escaping (String) -> Void) -> PromptEditorSheet {
        let s = PromptEditorSheet(shippedDefault: defaultCustomModeTaskPrompt,
                                  assembly: PromptAssembly.customMode(taskPrompt: mode.prompt),
                                  bench: bench ?? PromptTestBenchConfig(mode: mode),
                                  onSave: onSave)
        s.build(title: title,
                subtitle: "Shared by every provider. Restore default loads the prompt used for newly created hotkeys.",
                text: mode.prompt, restoreButtonTitle: "Restore default")
        return s
    }

    static func presentCustomModeWorkstation(on parent: NSWindow, title: String, mode: CustomMode,
                                             onSave: @escaping (String) -> Void) {
        let s = customModeWorkstation(title: title, mode: mode, onSave: onSave)
        s.retain = s
        parent.beginSheet(s.sheet, completionHandler: nil)
    }

    /// Sticky Skills share the same off-card workstation chrome but not the custom-hotkey assembly. This
    /// variant draws the real whole-note task/guard/payload shape and intentionally has no transform test
    /// bench: a faithful skill test requires title, attachments, vision, output handler, and the coordinator,
    /// so pretending a plain text transform exercised it would be worse than offering no test here.
    static func presentStickySkillWorkstation(on parent: NSWindow, title: String,
                                              skill: StickySkill, mode: CustomMode,
                                              onSave: @escaping (String) -> Void) {
        let s = PromptEditorSheet(
            shippedDefault: nil,
            assembly: PromptAssembly.stickySkill(taskPrompt: mode.prompt, skill: skill),
            assemblyNoteText: stickySkillAssemblyNote,
            userRoleTitle: "USER MESSAGE (the whole sticky note, fenced as data)",
            onSave: onSave)
        s.retain = s
        s.build(
            title: title,
            subtitle: "The task is provider-neutral. The app-owned whole-note data fence is shown but cannot be edited.",
            text: mode.prompt,
            restoreButtonTitle: "Restore default")
        parent.beginSheet(s.sheet, completionHandler: nil)
    }

    // MARK: - Test seams

    var contentViewForTesting: NSView { sheet.contentView! }
    var editorTextForTesting: String { textView.string }
    var sampleTextForTesting: String { sampleView?.string ?? "" }
    var resultTextForTesting: String { resultView?.string ?? "" }
    var statusTextForTesting: String { testStatus?.stringValue ?? "" }
    var sourceTextForTesting: String { sourceField?.stringValue ?? "" }

    /// True when a Test would dispatch through `CustomModeClient.run` rather than an injected stub —
    /// the property that makes "the button runs the mode's REAL provider and model" a gated fact about
    /// the sheet the production presenter builds, not a claim about a probe's own wiring.
    var usesProductionRunnerForTesting: Bool { bench != nil && bench?.runner == nil }

    /// What the panel is DISPLAYING, read back out of the live views in visual order — not out of the
    /// model it was built from. A gate compares this against what a real run would send, which is the
    /// only way "the display cannot drift" is a fact rather than an intention.
    var displayedAssemblyForTesting: (system: String, user: String)? {
        guard assembly != nil else { return nil }
        return (Self.joinedText(systemSegmentViews), Self.joinedText(userSegmentViews))
    }

    private static func joinedText(_ views: [NSView]) -> String {
        views.map { view -> String in
            if let tv = view as? NSTextView { return tv.string }
            if let field = view as? NSTextField { return field.stringValue }
            return ""
        }.joined()
    }

    // MARK: - Build

    private func build(title: String, subtitle: String?, text: String,
                       restoreButtonTitle: String) {
        let size = assembly == nil
            ? NSSize(width: 520, height: 380)
            : NSSize(width: 620, height: 690)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = title
        let root = NSView(frame: NSRect(origin: .zero, size: size))

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.frame = NSRect(x: 16, y: size.height - 34, width: size.width - 32, height: 18)
        root.addSubview(heading)

        if let subtitle = subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 10.5)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            sub.identifier = NSUserInterfaceItemIdentifier("prompt-editor-subtitle")
            sub.frame = NSRect(x: 16, y: size.height - 54, width: size.width - 32, height: 15)
            root.addSubview(sub)
        }

        var editorTop = size.height - (subtitle == nil ? 44 : 62)
        if let assembly = assembly {
            let note = NSTextField(wrappingLabelWithString: assemblyNoteText)
            note.font = .systemFont(ofSize: 10.5)
            note.textColor = .secondaryLabelColor
            note.identifier = NSUserInterfaceItemIdentifier("prompt-editor-assembly-note")
            note.preferredMaxLayoutWidth = size.width - 32
            let noteHeight = ceil(note.sizeThatFits(
                NSSize(width: size.width - 32, height: .greatestFiniteMagnitude)).height)
            note.frame = NSRect(x: 16, y: editorTop - noteHeight, width: size.width - 32, height: noteHeight)
            root.addSubview(note)
            editorTop -= noteHeight + 8
            // The bench sits in the fixed lower band, between the scrolling composition and the footer,
            // so neither it nor Restore can be scrolled out of reach while a prompt is being iterated.
            let benchTop = buildTestBench(root: root, size: size)
            buildComposition(root: root, size: size, top: editorTop, bottom: benchTop + 10,
                             text: text, assembly: assembly)
        } else {
            buildPlainEditor(root: root, size: size, top: editorTop, text: text)
        }

        if shippedDefault != nil {
            let restore = NSButton(title: restoreButtonTitle, target: self,
                                   action: #selector(restoreShippedDefault))
            restore.bezelStyle = .rounded
            restore.font = .systemFont(ofSize: 11)
            restore.identifier = NSUserInterfaceItemIdentifier("prompt-editor-restore")
            restore.frame = NSRect(x: 16, y: 12, width: 176, height: 30)
            root.addSubview(restore)
            restoreButton = restore
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.identifier = NSUserInterfaceItemIdentifier("prompt-editor-cancel")
        cancel.frame = NSRect(x: size.width - 16 - 90 - 8 - 90, y: 12, width: 90, height: 30)
        root.addSubview(cancel)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.identifier = NSUserInterfaceItemIdentifier("prompt-editor-save")
        save.frame = NSRect(x: size.width - 16 - 90, y: 12, width: 90, height: 30)
        root.addSubview(save)

        w.contentView = root
        sheet = w
        layoutComposition()
        updateRestoreState()
    }

    /// The pre-workstation shape: one scrolling text view, unchanged.
    private func buildPlainEditor(root: NSView, size: NSSize, top: CGFloat, text: String) {
        // Set an explicit frame + container size at creation so the view renders immediately (a
        // zero-frame NSTextView starts blank until resized).
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 52, width: size.width - 32, height: top - 52))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        let tv = makeEditor(width: scroll.contentSize.width, text: text)
        tv.frame = NSRect(origin: .zero, size: scroll.contentSize)
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        root.addSubview(scroll)
        textView = tv
    }

    /// The workstation shape: the assembled prompt, top to bottom, in the order the model receives it.
    /// One outer scroll owns the whole composition so the editable region can grow with what is typed
    /// and the footer controls (Restore especially) never scroll out of reach.
    private func buildComposition(root: NSView, size: NSSize, top: CGFloat, bottom: CGFloat,
                                  text: String, assembly: PromptAssemblyLayout) {
        let scroll = NSScrollView(frame: NSRect(x: 16, y: bottom, width: size.width - 32,
                                                height: max(120, top - bottom)))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = true
        let doc = PromptCompositionView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        doc.autoresizingMask = [.width]
        scroll.documentView = doc
        root.addSubview(scroll)
        compositionScroll = scroll
        compositionDoc = doc

        let tv = makeEditor(width: scroll.contentSize.width - 20, text: text)
        textView = tv

        compositionRows = []
        systemSegmentViews = []
        userSegmentViews = []

        add(roleHeader("SYSTEM MESSAGE (the mode's instructions)", id: "prompt-editor-role-system"), gap: 4)
        for (i, segment) in assembly.system.enumerated() {
            let view = segmentView(segment, message: "system", index: i, editor: tv)
            systemSegmentViews.append(view)
            add(view, gap: 4)
        }
        add(roleHeader(userRoleTitle, id: "prompt-editor-role-user"),
            gap: 4, leadingGap: 14)
        for (i, segment) in assembly.user.enumerated() {
            let view = segmentView(segment, message: "user", index: i, editor: tv)
            userSegmentViews.append(view)
            add(view, gap: 4)
        }
    }

    // MARK: - Test bench (W2)

    /// The one line the bench says about itself. It is the answer to the question a user asks the
    /// instant a test produces text: where did that go? Nowhere — and that has to be said before the
    /// button is pressed, not after.
    static let testBenchNote = "Test runs this prompt against this hotkey's real model, using the "
        + "sample below. The answer is shown here only: nothing is pasted, saved to a note, copied to "
        + "the clipboard, or added to History."

    /// Lay the bench out bottom-up in the fixed band above the footer and return its top edge, which is
    /// where the scrolling composition has to stop.
    private func buildTestBench(root: NSView, size: NSSize) -> CGFloat {
        guard let bench = bench else { return 52 }
        let x: CGFloat = 16
        let w = size.width - 32
        var y: CGFloat = 52

        // Bottom of the band: the answer. Read-only and selectable, so it can be copied deliberately —
        // the bench never puts anything on the clipboard on the user's behalf.
        let (resultScroll, result) = benchTextView(x: x, y: y, width: w, height: 68, editable: false)
        result.identifier = NSUserInterfaceItemIdentifier("prompt-test-result")
        root.addSubview(resultScroll)
        resultView = result
        y += 68 + 3
        root.addSubview(benchCaption("RESULT", at: NSRect(x: x, y: y, width: w, height: 13)))
        y += 13 + 6

        let test = NSButton(title: "Test", target: self, action: #selector(runTest))
        test.bezelStyle = .rounded
        test.identifier = NSUserInterfaceItemIdentifier("prompt-test-run")
        test.frame = NSRect(x: x, y: y, width: 110, height: 26)
        root.addSubview(test)
        testButton = test

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 10.5)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.identifier = NSUserInterfaceItemIdentifier("prompt-test-status")
        status.frame = NSRect(x: x + 120, y: y + 5, width: w - 120, height: 16)
        root.addSubview(status)
        testStatus = status
        y += 26 + 6

        // The free-text field. It is the sample field, always editable and never capped — the History
        // default is a seed for it, not a separate mode. Building an email-writer hotkey means testing
        // against one specific long dictation, and a cap here would forbid exactly that.
        let (sampleScroll, sample) = benchTextView(x: x, y: y, width: w, height: 48, editable: true)
        sample.identifier = NSUserInterfaceItemIdentifier("prompt-test-sample")
        sample.delegate = self
        root.addSubview(sampleScroll)
        sampleView = sample
        y += 48 + 5

        let reseed = NSButton(title: "Load recent dictation", target: self,
                              action: #selector(loadRecentDictation))
        reseed.bezelStyle = .rounded
        reseed.font = .systemFont(ofSize: 11)
        reseed.identifier = NSUserInterfaceItemIdentifier("prompt-test-reseed")
        reseed.frame = NSRect(x: x + w - 176, y: y - 2, width: 176, height: 24)
        root.addSubview(reseed)
        reseedButton = reseed

        let source = NSTextField(labelWithString: "")
        source.font = .systemFont(ofSize: 10.5)
        source.lineBreakMode = .byTruncatingTail
        source.identifier = NSUserInterfaceItemIdentifier("prompt-test-source")
        source.frame = NSRect(x: x, y: y + 3, width: w - 186, height: 15)
        root.addSubview(source)
        sourceField = source
        y += 24 + 6

        let note = NSTextField(wrappingLabelWithString: Self.testBenchNote)
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .secondaryLabelColor
        note.identifier = NSUserInterfaceItemIdentifier("prompt-test-note")
        note.preferredMaxLayoutWidth = w
        let noteHeight = ceil(note.sizeThatFits(NSSize(width: w, height: .greatestFiniteMagnitude)).height)
        note.frame = NSRect(x: x, y: y, width: w, height: noteHeight)
        root.addSubview(note)
        y += noteHeight + 5

        root.addSubview(benchCaption("TEST", at: NSRect(x: x, y: y, width: w, height: 14)))
        y += 14 + 6

        let divider = NSBox(frame: NSRect(x: x, y: y, width: w, height: 1))
        divider.boxType = .separator
        root.addSubview(divider)
        y += 1

        // Seed once, from the caller's history view. `Seed.date == nil` means nothing in History fits
        // the cap, and the field stays empty rather than showing a truncated take.
        sampleSeed = PromptTestBench.seed(from: bench.history())
        sample.string = sampleSeed.text
        updateTestBenchState()
        return y
    }

    private func benchCaption(_ title: String, at frame: NSRect) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 9.5, weight: .semibold)
        field.textColor = .tertiaryLabelColor
        field.frame = frame
        return field
    }

    private func benchTextView(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                               editable: Bool) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView(frame: NSRect(x: x, y: y, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.font = .systemFont(ofSize: 11.5)
        tv.isRichText = false
        tv.isEditable = editable
        tv.isSelectable = true
        if !editable { tv.drawsBackground = true; tv.backgroundColor = .underPageBackgroundColor }
        scroll.documentView = tv
        return (scroll, tv)
    }

    /// Recompute everything the bench derives from its sample: the provenance line, and whether Test and
    /// the reseed button can do anything. Provenance is derived on every keystroke rather than latched
    /// at load, which is what stops a History default left in the box from reading as typed text.
    private func updateTestBenchState() {
        guard let sample = sampleView else { return }
        let source = PromptTestBench.source(current: sample.string, seed: sampleSeed)
        sourceField?.stringValue = PromptTestBench.sourceLabel(source)
        testButton?.isEnabled = runToken == nil && PromptTestBench.isRunnable(sample.string)
        if sampleSeed.date == nil {
            reseedButton?.isEnabled = false
            reseedButton?.toolTip = "No dictation in your History is "
                + "\(PromptTestBench.historySampleCharacterLimit) characters or fewer."
        } else {
            reseedButton?.isEnabled = sample.string != sampleSeed.text
            reseedButton?.toolTip = "Put your most recent dictation back in the sample box."
        }
    }

    @objc private func loadRecentDictation() {
        guard let sample = sampleView, sampleSeed.date != nil else { return }
        sample.string = sampleSeed.text
        updateTestBenchState()
    }

    /// Run the mode's real provider and model against the sample, with the prompt CURRENTLY in the
    /// editable region, and draw the answer. Nothing lands: the result goes to a read-only field in
    /// this sheet, and the run is dispatched inert so it does not even disturb a pending Retry.
    ///
    /// Asynchronous throughout — the sheet stays usable while a slow model runs, and Cancel still works.
    @objc private func runTest() {
        guard let bench = bench, let sample = sampleView,
              PromptTestBench.isRunnable(sample.string) else { return }
        let candidate = PromptTestBench.candidate(bench.mode, editedPrompt: textView.string)
        let token = UUID()
        runToken = token
        testButton?.isEnabled = false
        testStatus?.stringValue = "Running on this hotkey's configured model..."
        resultView?.string = ""

        let deliver: (CleanupClient.Result) -> Void = { [weak self] result in
            // The transform seam calls back on an arbitrary queue, EXCEPT on the route-is-off path,
            // which answers synchronously on the caller's thread. Draw immediately when already on
            // main rather than deferring a whole run loop turn for a result that is already in hand.
            Self.onMain {
                // A result from a superseded run (Test pressed again) or a closed panel is dropped, not
                // drawn. There is nowhere else for it to go: the bench has no landing path.
                guard let self = self, self.runToken == token else { return }
                self.runToken = nil
                self.show(PromptTestBench.outcome(for: result))
            }
        }
        if let runner = bench.runner {
            runner(candidate, sample.string, deliver)
        } else {
            CustomModeClient.run(candidate, input: sample.string, arming: .inert, completion: deliver)
        }
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func show(_ outcome: PromptTestBench.Outcome) {
        testStatus?.stringValue = outcome.statusText
        resultView?.string = outcome.resultText
        updateTestBenchState()
    }

    private func add(_ view: NSView, gap: CGFloat, leadingGap: CGFloat = 0) {
        if leadingGap > 0, !compositionRows.isEmpty {
            compositionRows[compositionRows.count - 1].gapAfter += leadingGap
        }
        compositionDoc?.addSubview(view)
        compositionRows.append((view, gap))
    }

    private func segmentView(_ segment: PromptAssemblySegment, message: String, index: Int,
                             editor: NSTextView) -> NSView {
        switch segment {
        case .editable:
            return editor
        case .scaffold(let s):
            // Verbatim, and selectable so the markers can be copied into a prompt being written
            // elsewhere. Never editable: this text belongs to the app, not to the stored prompt.
            let field = monoLabel(s, color: .secondaryLabelColor)
            field.identifier = NSUserInterfaceItemIdentifier("prompt-editor-scaffold-\(message)-\(index)")
            return field
        case .transcript(let s):
            let field = monoLabel(s, color: .secondaryLabelColor)
            field.identifier = NSUserInterfaceItemIdentifier("prompt-editor-transcript-placeholder")
            field.drawsBackground = true
            field.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.30)
            return field
        }
    }

    private func roleHeader(_ title: String, id: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 9.5, weight: .semibold)
        field.textColor = .tertiaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.identifier = NSUserInterfaceItemIdentifier(id)
        return field
    }

    private func monoLabel(_ value: String, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.textColor = color
        field.isSelectable = true
        field.isEditable = false
        return field
    }

    private func makeEditor(width: CGFloat, text: String) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.string = text
        tv.delegate = self
        tv.identifier = NSUserInterfaceItemIdentifier("prompt-editor-text")
        if assembly != nil {
            // Inside the composition the editable region has to read as the one thing you can change.
            tv.wantsLayer = true
            tv.textContainerInset = NSSize(width: 5, height: 6)
            tv.drawsBackground = true
            tv.backgroundColor = .textBackgroundColor
            tv.layer?.cornerRadius = 5
            tv.layer?.borderWidth = 1
            tv.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
        }
        return tv
    }

    // MARK: - Layout

    /// Stack the composition rows top-down and size the document view to fit. Re-run on every text
    /// change so the editable region grows with what is typed instead of clipping it.
    private func layoutComposition() {
        guard let doc = compositionDoc, let scroll = compositionScroll else { return }
        let width = scroll.contentSize.width
        let inset: CGFloat = 10
        let contentWidth = max(80, width - inset * 2)
        var y: CGFloat = inset
        for row in compositionRows {
            let height: CGFloat
            if let tv = row.view as? NSTextView {
                height = editorHeight(tv, width: contentWidth)
            } else if let field = row.view as? NSTextField {
                field.preferredMaxLayoutWidth = contentWidth
                height = max(14, ceil(field.sizeThatFits(
                    NSSize(width: contentWidth, height: .greatestFiniteMagnitude)).height))
            } else {
                height = row.view.frame.height
            }
            row.view.frame = NSRect(x: inset, y: y, width: contentWidth, height: height)
            y += height + row.gapAfter
        }
        doc.frame = NSRect(x: 0, y: 0, width: width, height: max(y + inset, scroll.contentSize.height))
    }

    private func editorHeight(_ tv: NSTextView, width: CGFloat) -> CGFloat {
        guard let manager = tv.layoutManager, let container = tv.textContainer else { return 140 }
        container.containerSize = NSSize(width: width - tv.textContainerInset.width * 2,
                                         height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return max(110, ceil(manager.usedRect(for: container).height) + tv.textContainerInset.height * 2 + 4)
    }

    func textDidChange(_ notification: Notification) {
        // The sheet is the delegate for two editable regions: the prompt itself and the bench's sample.
        // Editing the sample changes only what the bench claims about where the sample came from.
        if let changed = notification.object as? NSTextView, changed === sampleView {
            updateTestBenchState()
            return
        }
        layoutComposition()
        updateRestoreState()
    }

    /// Restore is enabled exactly when it would change something, and it is recomputed on every edit so
    /// it comes BACK after the user restores and then types again. It lives in the fixed footer rather
    /// than in the scrolling composition, so it is reachable in every state of the panel.
    private func updateRestoreState() {
        guard let button = restoreButton, let shipped = shippedDefault else { return }
        button.isEnabled = textView.string != shipped
        button.toolTip = button.isEnabled
            ? "Load the prompt this build ships. Saving it then clears your override."
            : "This is already the prompt this build ships."
    }

    /// Load the shipped bytes into the editor WITHOUT saving, so the user reads what they are about to
    /// return to and can still cancel. Save is what actually clears the override.
    @objc private func restoreShippedDefault() {
        guard let shipped = shippedDefault else { return }
        textView.string = shipped
        layoutComposition()
        updateRestoreState()
    }

    /// Only the editable region's bytes travel back. The scaffold is presentation and never joins them,
    /// so opening the panel on an existing mode and saving without typing is a byte-identical no-op.
    @objc private func save() {
        onSave(textView.string)
        finish()
    }

    @objc private func cancel() { finish() }

    private func finish() {
        // Retire any test still on the wire. Its result has nowhere to land by construction; clearing
        // the token means it is not drawn into a panel the user has already dismissed either.
        runToken = nil
        if let parent = sheet.sheetParent { parent.endSheet(sheet) }
        retain = nil
    }
}
