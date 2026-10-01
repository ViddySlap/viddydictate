import Foundation

/// The Feature Tour (spec section 7, D6/D7/D9/D10), as DATA: the pages, the chord placeholders they render from
/// the live hotkey map, the D10 coverage rule, the first-show rule, and the practice box's three states.
///
/// `FeatureTourWindowController` draws this and performs nothing on its own; every word a user reads in the
/// tour is in `FeatureTour.pages`, so a page edit is a one-file change and `--feature-tour-selftest` gates it
/// without AppKit or a Mac.
///
/// **Chords are never typed into the copy.** A page names a chord by placeholder (`{lock}`, `{wakeup}`) and
/// `render(_:map:)` fills it from the `HotkeyMap` the Hotkeys tab edits, with the same `KeySpec.label` the
/// Hotkeys tab draws, so a rebound key reads as rebound here too. Fixed keys that no map owns (Esc, the A/B
/// picker's arrows and Return) are plain words.
///
/// **D10.** Every built-in hotkey slot (the wakeup and each `HotkeyCommand`) is listed in some page's `commands`
/// and named by placeholder in that page's text. A user's own custom hotkeys are not listed one by one; the
/// Sticky Skills page says how to make one.
///
/// **D7.** The tour explains and links. A page may carry one `settingsLink` (opened with the Settings window's
/// own `show(tab:)`) and one `liveStatus` readout; nothing here installs, starts or changes anything.
struct FeatureTourPage: Equatable {
    /// Stable, used in render file names and view identifiers.
    let id: String
    let title: String
    /// What the feature does and how to trigger it, one short paragraph per line, with chord placeholders.
    let body: [String]
    /// The one thing a user would not guess. Drawn in its own card. Placeholders allowed.
    let nonObvious: String?
    /// The built-in hotkey slots this page teaches, in the order its keys card lists them. Each one must also be
    /// named by placeholder in the page's text (`--feature-tour-selftest` holds both directions).
    let commands: [HotkeySlot]
    /// The Settings tab the page's "Open the ... tab" button opens, if any.
    let settingsLink: SettingsTab?
    /// The live readout the page shows, if any.
    let liveStatus: FeatureTourLiveStatus?

    init(id: String, title: String, body: [String], nonObvious: String? = nil, commands: [HotkeySlot] = [],
         settingsLink: SettingsTab? = nil, liveStatus: FeatureTourLiveStatus? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.nonObvious = nonObvious
        self.commands = commands
        self.settingsLink = settingsLink
        self.liveStatus = liveStatus
    }

    /// Every user-visible string the page carries, unrendered (placeholders intact).
    var templates: [String] { [title] + body + (nonObvious.map { [$0] } ?? []) }

    func renderedBody(map: HotkeyMap) -> [String] { body.map { FeatureTour.render($0, map: map) } }
    func renderedNonObvious(map: HotkeyMap) -> String? { nonObvious.map { FeatureTour.render($0, map: map) } }
}

/// The live readouts a page can carry. Each is read, never acted on (D7).
enum FeatureTourLiveStatus: String, CaseIterable {
    /// Microphone / Accessibility / Input Monitoring, granted or not (`PermissionsStatus`, the reading the
    /// first-run permissions screen uses).
    case permissions
    /// LM Studio and Ollama, each in the Setup tab's own state words (`LocalAppRows`).
    case localApps
    /// D9's practice box, or the reason it is not live yet.
    case practice
}

enum FeatureTour {

    // MARK: - The pages

    /// The 11 pages of spec section 7, as amended by grill `viddydictate-grill-20260930` (page 6: LM Studio simple,
    /// Ollama advanced, Staff picks, the one-time macOS prompt, the memory budget, the MLX tip).
    static let pages: [FeatureTourPage] = [
        FeatureTourPage(
            id: "welcome",
            title: "Welcome to ViddyDictate",
            body: [
                "Hold {wakeup}, talk, and let go. Your words land wherever the cursor is.",
                "Everything runs on this Mac unless you choose a cloud provider.",
                "This tour takes a minute. It's in the menu bar under Feature Tour\u{2026} whenever you want it again.",
            ],
            commands: [.wakeup]),
        FeatureTourPage(
            id: "permissions",
            title: "Three permissions",
            body: [
                "Microphone lets ViddyDictate hear you. Accessibility lets it type into the app you're using. "
                    + "Input Monitoring lets the hotkey work while another app is in front.",
            ],
            nonObvious: "After you turn on Accessibility or Input Monitoring, quit and reopen ViddyDictate. "
                + "Until then the hotkeys stay dead.",
            settingsLink: .setup,
            liveStatus: .permissions),
        FeatureTourPage(
            id: "dictation",
            title: "Dictation controls",
            body: [
                "While you hold {wakeup}: tap {lock} to latch hands-free, Esc to cancel the take, "
                    + "and {undo} to undo the last result.",
                "Past dictations are on the History tab. Recent takes' audio stays on this Mac (Audio tab).",
            ],
            nonObvious: "The Dictionary teaches Whisper how to spell your names and terms. "
                + "Hold {wakeup} and tap {dictionary} to open it.",
            commands: [.wakeup, .command(.lock), .command(.undo), .command(.dictionary)],
            settingsLink: .dictionary,
            liveStatus: .practice),
        FeatureTourPage(
            id: "cleanup",
            title: "Cleanup",
            body: [
                "Hold {wakeup} and tap {cleanupToggle} to turn cleanup on or off for what you're dictating.",
                "{levelUp} and {levelDown} step between Cleanup, Tighten and Summarize.",
            ],
            nonObvious: "When a cleanup looks off, an A/B picker appears. Use the arrow keys to choose, "
                + "then Return, so you can keep your raw words.",
            commands: [.wakeup, .command(.cleanupToggle), .command(.levelUp), .command(.levelDown)],
            settingsLink: .hotkeys),
        FeatureTourPage(
            id: "providers",
            title: "Text providers",
            body: [
                "Cleanup, email, web answers and Sticky Skills need a text provider: Claude, Codex, or Local "
                    + "(a model on this Mac).",
                "Each hotkey picks its own provider on the Hotkeys tab, and each starts on a Staff pick you're "
                    + "free to change.",
            ],
            nonObvious: "Plain dictation works with no provider at all.",
            settingsLink: .setup),
        FeatureTourPage(
            id: "local-models",
            title: "Local models",
            body: [
                "LM Studio is the simple choice. Ollama is the advanced one. Use either, or both.",
                "Every built-in model is a Staff pick you're free to change.",
                "ViddyDictate keeps local models inside a memory budget and unloads them when they sit idle. "
                    + "If you see \u{201C}Not enough space in RAM\u{201D}, raise the budget or pick a smaller "
                    + "model on the Setup tab.",
                "Tip: on a Mac with 32 GB or more, Ollama runs faster with its MLX option. ViddyDictate never "
                    + "turns it on for you.",
            ],
            nonObvious: "The first time Ollama starts, macOS asks for Touch ID or your password so it can install "
                + "its command-line tool. Approve it once.",
            settingsLink: .setup,
            liveStatus: .localApps),
        FeatureTourPage(
            id: "selection",
            title: "Selection tools",
            body: [
                "Select text anywhere, hold {wakeup} and tap {cleanupSelection}. The text is cleaned up or "
                    + "prompt-prepped in place, and a level picker lets you choose how much.",
                "{email} writes an email from what you dictate, or from the selected text.",
            ],
            commands: [.wakeup, .command(.cleanupSelection), .command(.email)],
            settingsLink: .hotkeys),
        FeatureTourPage(
            id: "web-answers",
            title: "Web answers",
            body: [
                "Hold {wakeup}, tap {searchLocal} and ask a question. ViddyDictate searches DuckDuckGo from this "
                    + "Mac and answers. It needs the optional web search helper.",
                "{searchGemini} asks Gemini instead. It needs a Gemini key on the Setup tab.",
            ],
            nonObvious: "Answers land in a sticky note. They're never pasted into your document.",
            commands: [.wakeup, .command(.searchLocal), .command(.searchGemini)],
            settingsLink: .setup),
        FeatureTourPage(
            id: "sticky-notes",
            title: "Sticky notes",
            body: [
                "Hold {wakeup} and tap {notes} to open your sticky notes. Notes have tabs, and you can drag one "
                    + "out into its own window.",
                "{bullseyeToggle} arms the bullseye, the note that receives your answers. "
                    + "{bullseyeReveal} brings it to the front.",
            ],
            nonObvious: "Files mode: use Open With on a .md file to edit it here. ViddyDictate backs it up first.",
            commands: [.wakeup, .command(.notes), .command(.bullseyeToggle), .command(.bullseyeReveal)],
            settingsLink: .notes),
        FeatureTourPage(
            id: "skills",
            title: "Sticky Skills and custom hotkeys",
            body: [
                "Sticky Skills run on a whole note. The built-in one, Note to Handoff, also reads the images and "
                    + "video frames in it.",
                "Make your own mode with + Add new hotkey on the Hotkeys tab: its key, its prompt, and where the "
                    + "result lands.",
            ],
            nonObvious: "Any key can be rebound on the Hotkeys tab. This tour always shows your current keys.",
            settingsLink: .hotkeys),
        FeatureTourPage(
            id: "staying-current",
            title: "Staying current",
            body: [
                "ViddyDictate checks for updates and tells you. It never updates itself.",
                "Power Mode: Final-only, in the menu bar, transcribes once when you let go and shows a small pill "
                    + "instead of the full HUD. Handy on battery.",
                "Settings\u{2026} and this tour are both in the menu bar.",
            ]),
    ]

    // MARK: - Chords from the live map

    /// The built-in hotkey slots, every one of which D10 says some page must teach. Read from the enum, so a
    /// command added to `HotkeyCommand` without a page fails the gate rather than shipping untaught.
    static var builtInSlots: [HotkeySlot] { [.wakeup] + HotkeyCommand.allCases.map { .command($0) } }

    /// The placeholder name for a slot: `wakeup`, or the command's raw value (`lock`, `cleanupToggle`, ...).
    static func token(for slot: HotkeySlot) -> String {
        switch slot {
        case .wakeup: return "wakeup"
        case .command(let command): return command.rawValue
        }
    }

    static func slot(forToken token: String) -> HotkeySlot? {
        if token == "wakeup" { return .wakeup }
        return HotkeyCommand(rawValue: token).map { .command($0) }
    }

    /// The chord a slot is bound to, exactly as the Hotkeys tab draws it (`KeySpec.label`).
    static func chordLabel(_ slot: HotkeySlot, map: HotkeyMap) -> String {
        switch slot {
        case .wakeup: return map.wakeup.label
        case .command(let command): return map.key(for: command).label
        }
    }

    /// Every `{name}` in `template`, in order, known or not.
    static func placeholders(in template: String) -> [String] {
        var names: [String] = []
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "}") else { break }
            names.append(String(rest[after..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return names
    }

    /// Fill every known placeholder from `map`. An unknown name is left as written, braces and all, so a typo
    /// shows up on screen and in the gate rather than vanishing.
    static func render(_ template: String, map: HotkeyMap) -> String {
        var out = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let name = String(rest[after..<close])
            if let slot = slot(forToken: name) {
                out += chordLabel(slot, map: map)
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    // MARK: - D10 coverage

    /// The built-in slots no page lists in its `commands`. Empty is the D10 rule holding.
    static func uncoveredSlots(in pages: [FeatureTourPage]) -> [HotkeySlot] {
        let listed = Set(pages.flatMap { $0.commands.map(token(for:)) })
        return builtInSlots.filter { !listed.contains(token(for: $0)) }
    }

    // MARK: - Copy for the window

    static let windowTitle = "Feature Tour"
    static let menuTitle = "Feature Tour\u{2026}"
    static let backTitle = "Back"
    static let nextTitle = "Next"
    static let doneTitle = "Done"
    static let skipTitle = "Skip tour"
    static let nonObviousHeader = "WORTH KNOWING"
    /// The Hotkeys tab's own legend wording, so the tour's keys card reads the same.
    static let keysHeader = "KEYS ON THIS PAGE  (hold the wakeup, tap a key)"
    static let wakeupRowLabel = "Dictation wakeup \u{2014} hold to dictate"
    static let permissionsHeader = "ON THIS MAC NOW"
    static let localAppsHeader = "LOCAL MODEL APPS ON THIS MAC NOW"
    static let practiceHeader = "TRY IT HERE"

    static func stepText(_ index: Int, of count: Int) -> String { "\(index + 1) of \(count)" }

    static func settingsButtonTitle(_ tab: SettingsTab) -> String { "Open the \(tab.rawValue) tab" }
}

// MARK: - First show (D6)

/// When the tour opens by itself: once, on the first launch of a fresh install, after the first-run setup window
/// and provider onboarding have closed. Never for an upgrading user, who reaches it from the menu bar.
///
/// "Fresh" is decided ONCE, on the first launch that knows about the tour, by S8's own upgrader detection: a
/// launch where `FirstRunSetupLaunchRule` shows the first-run setup window is a fresh install, and one where it
/// does not (the core is already installed, from this version's queue or an earlier version's) is an existing
/// install. The answer is written down at once, before any window, so a fresh user who relaunches before the
/// tour ever appeared (the post-permission relaunch, with the core installed by then) is still owed it.
enum FeatureTourFirstShow {
    struct State: Equatable {
        /// The install has been classified fresh or existing (`Settings.featureTourLaunchClassified`).
        var classified: Bool
        /// The tour has been shown, or this is an existing install (`Settings.featureTourSeen`).
        var seen: Bool
    }

    enum Entry: Equatable {
        /// The automatic first show, after setup and onboarding.
        case launch
        /// The menu bar item. Always opens the tour.
        case menu
    }

    /// Run at the start of every launch. Only the first launch that sees `classified == false` changes anything:
    /// an install whose first-run setup window is not shown is an existing install, marked seen.
    static func classify(_ state: State, setupWindowShowsThisLaunch: Bool) -> State {
        guard !state.classified else { return state }
        return State(classified: true, seen: state.seen || !setupWindowShowsThisLaunch)
    }

    static func shouldShow(_ entry: Entry, _ state: State) -> Bool {
        switch entry {
        case .menu: return true
        case .launch: return state.classified && !state.seen
        }
    }

    /// Marked when the tour is SHOWN, not when it is finished: closing it halfway is not a reason to show it again.
    static func shown(_ state: State) -> State { State(classified: true, seen: true) }
}

// MARK: - The practice box (D9)

/// Page 3's practice box. It is only worth typing into when the hotkey tap is live in THIS launch; a fresh install
/// that granted Accessibility and Input Monitoring after launch has the grants but not the tap, and macOS only
/// lets the tap start on the next launch.
enum FeatureTourPractice {
    enum State: Equatable {
        case ready
        /// Both grants are on but the tap is not live in this launch.
        case relaunchNeeded
        /// One of the two hotkey grants is still off.
        case grantFirst
    }

    /// `tapLive` is the launch's own answer: `AppDelegate.startController()` installed the event tap.
    static func state(tapLive: Bool, accessibility: Bool, inputMonitoring: Bool) -> State {
        if tapLive { return .ready }
        return accessibility && inputMonitoring ? .relaunchNeeded : .grantFirst
    }

    static let relaunchNote = "Relaunch ViddyDictate, then try here."

    static func note(_ state: State, map: HotkeyMap) -> String {
        switch state {
        case .ready:
            return FeatureTour.render("Hold {wakeup}, say a sentence, and let go. Your words land in this box.",
                                      map: map)
        case .relaunchNeeded:
            return relaunchNote
        case .grantFirst:
            return "Turn on Accessibility and Input Monitoring (page 2), then relaunch ViddyDictate and try here."
        }
    }

    static let placeholder = "Your words land here."
}
