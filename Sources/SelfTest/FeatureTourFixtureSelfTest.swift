import Foundation

/// `--feature-tour-selftest`: the Feature Tour (spec section 7) as DATA. G7.
///
/// - **(a) D10 coverage.** Every built-in hotkey slot (the wakeup and each `HotkeyCommand`, read from the enum) is
///   listed by some page, and each page's keys card lists exactly the chords its text names, with no unknown
///   placeholder.
/// - **(b) Live chords.** A remapped map (lock -> K) shows K on lock's page and no Space; every slot, given its own
///   sentinel key, shows on exactly the pages that teach it. Chords are drawn with the Hotkeys tab's `KeySpec.label`.
/// - **(c) First show (D6).** A fresh install shows the tour once; the next launch does not; a fresh install that
///   relaunched before its tour appeared is still owed it; an upgraded install (S8's own upgrader detection) is
///   marked seen and never gets it by itself; the menu bar item opens it in every state, and sits under Settings...
/// - **(d) Copy.** No page says "ratif" or "tested", and no page types a built-in chord (Space, P, right Option...)
///   instead of a placeholder.
/// - **(e) Page 6** names LM Studio the simple choice and Ollama the advanced one, says Staff pick, and keeps the
///   one-time macOS prompt, the memory budget and idle unload, and the MLX tip that ViddyDictate never sets.
/// - **The practice box (D9)** says "Relaunch ViddyDictate, then try here." when the grants are on but this launch's
///   tap is not.
///
/// No window, no Settings write, no store: the first-show rule is pure, fed by `FirstRunSetupLaunchRule` over
/// hand-built snapshots. The AppKit half is `--feature-tour-render`.
///
/// Negative controls, each of which the gate must catch:
/// (1) a page list missing one built-in command;
/// (2) a hard-coded default chord: a renderer that always draws lock as Space, and a page that types "Space";
/// (3) the tour auto-showing for an upgraded user.
enum FeatureTourFixtureSelfTest {
    typealias Renderer = (String, HotkeyMap) -> String
    typealias Classifier = (FeatureTourFirstShow.State, Bool) -> FeatureTourFirstShow.State

    // Assertion names the negative controls look up.
    private static let coverageCheck = "every built-in hotkey slot is taught by some page (D10)"
    private static let remapCheck = "lock remapped to K shows K on its page, and the default Space does not appear"
    private static let hardCodedCheck = "no page types a built-in chord instead of a placeholder"
    private static let upgradeCheck =
        "an upgraded install is marked seen at its first launch and never gets the tour by itself"

    static func run() -> Bool {
        print("=== Feature Tour fixture selftest (D10 coverage, live chords, first show, copy) ===")
        let reporter = SelfTestReporter()

        print("--- (a) D10 coverage ---")
        checkCoverage(FeatureTour.pages, reporter)
        checkPageShape(FeatureTour.pages, reporter)
        print("--- (b) chords from the live hotkey map ---")
        checkRemap(FeatureTour.pages, render: FeatureTour.render, reporter)
        checkEverySlotIsLive(FeatureTour.pages, reporter)
        print("--- (c) first show and the menu bar item ---")
        checkFirstShow(classify: FeatureTourFirstShow.classify, reporter)
        checkMenuWiring(reporter)
        print("--- (d) copy ---")
        checkCopy(FeatureTour.pages, reporter)
        print("--- (e) page 6, Local models ---")
        checkLocalModelsPage(FeatureTour.pages, reporter)
        print("--- the practice box (D9) ---")
        checkPractice(reporter)
        checkNegativeControls(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "feature tour"))
        print(reporter.passed ? "[feature-tour-selftest] PASS" : "[feature-tour-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - Helpers

    private static func tokens(_ slots: [HotkeySlot]) -> [String] { slots.map(FeatureTour.token(for:)) }

    /// Everything a page shows, rendered with `map` by `render`.
    private static func shown(_ page: FeatureTourPage, map: HotkeyMap, render: Renderer) -> String {
        page.templates.map { render($0, map) }.joined(separator: "\n")
    }

    /// Whitespace-separated words with surrounding punctuation trimmed, so "Space," and "(K)" read as words.
    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()\u{201C}\u{201D}.,;:!"))
        }
    }

    private static func remapped(_ slot: HotkeySlot, label: String) -> HotkeyMap {
        var map = HotkeyMap.defaults()
        map.assign(.regular(keyCode: 40, label: label), to: slot)
        return map
    }

    // MARK: - (a)

    private static func checkCoverage(_ pages: [FeatureTourPage], _ r: SelfTestReporter) {
        let missing = tokens(FeatureTour.uncoveredSlots(in: pages))
        r.record(coverageCheck, missing.isEmpty,
                 missing.isEmpty ? "\(FeatureTour.builtInSlots.count) slots"
                    : "missing: " + missing.joined(separator: ","))
        r.record("the built-in slots are the wakeup plus every HotkeyCommand case",
                 tokens(FeatureTour.builtInSlots) == ["wakeup"] + HotkeyCommand.allCases.map(\.rawValue))

        var unknown: [String] = []
        var mismatched: [String] = []
        for page in pages {
            let named = page.templates.flatMap(FeatureTour.placeholders(in:))
            unknown += named.filter { FeatureTour.slot(forToken: $0) == nil }.map { "\(page.id):{\($0)}" }
            if Set(named) != Set(tokens(page.commands)) || Set(tokens(page.commands)).count != page.commands.count {
                mismatched.append(page.id)
            }
        }
        r.record("every placeholder names a real hotkey slot", unknown.isEmpty, unknown.joined(separator: " "))
        r.record("each page's keys card lists exactly the chords its text names", mismatched.isEmpty,
                 mismatched.joined(separator: ","))
        r.record("an unknown placeholder is left on screen as written, not dropped",
                 FeatureTour.render("tap {nope}", map: .defaults()) == "tap {nope}")
    }

    private static func checkPageShape(_ pages: [FeatureTourPage], _ r: SelfTestReporter) {
        let ids = pages.map(\.id)
        r.record("the 11 pages of spec section 7, in its order",
                 ids == ["welcome", "permissions", "dictation", "cleanup", "providers", "local-models", "selection",
                         "web-answers", "sticky-notes", "skills", "staying-current"],
                 ids.joined(separator: ","))
        r.record("every page has a title and a body", pages.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
        let live = pages.compactMap { page in page.liveStatus.map { "\(page.id)=\($0.rawValue)" } }
        r.record("permissions live on page 2, the practice box on page 3, the local apps on page 6",
                 live == ["permissions=permissions", "dictation=practice", "local-models=localApps"],
                 live.joined(separator: ","))
        let longest = pages.flatMap(\.body).map(\.count).max() ?? 0
        r.record("pages stay short: at most four body lines, none over 200 characters",
                 pages.allSatisfy { $0.body.count <= 4 } && longest <= 200, "longest line \(longest)")
        r.record("the Settings button names its tab",
                 FeatureTour.settingsButtonTitle(.hotkeys) == "Open the Hotkeys tab")
    }

    // MARK: - (b)

    private static func checkRemap(_ pages: [FeatureTourPage], render: Renderer, _ r: SelfTestReporter) {
        let lockPages = pages.filter { tokens($0.commands).contains(HotkeyCommand.lock.rawValue) }
        let map = remapped(.command(.lock), label: "K")
        let remappedWords = lockPages.map { words(shown($0, map: map, render: render)) }
        r.record(remapCheck,
                 !lockPages.isEmpty
                    && remappedWords.allSatisfy { $0.contains("K") && !$0.contains("Space") },
                 lockPages.map(\.id).joined(separator: ","))
        r.record("with the default map the same page does show Space, so the check above can see it",
                 lockPages.allSatisfy { words(shown($0, map: .defaults(), render: render)).contains("Space") })
    }

    private static func checkEverySlotIsLive(_ pages: [FeatureTourPage], _ r: SelfTestReporter) {
        var wrong: [String] = []
        for slot in FeatureTour.builtInSlots {
            let token = FeatureTour.token(for: slot)
            let sentinel = "<\(token)-fixture-key>"
            let map: HotkeyMap
            if case .wakeup = slot {
                var m = HotkeyMap.defaults()
                m.assign(.modifier(mask: 0x10, label: sentinel), to: .wakeup)
                map = m
            } else {
                map = remapped(slot, label: sentinel)
            }
            for page in pages {
                let teaches = tokens(page.commands).contains(token)
                if shown(page, map: map, render: FeatureTour.render).contains(sentinel) != teaches {
                    wrong.append("\(token)@\(page.id)")
                }
            }
        }
        r.record("every slot, rebound to its own key, shows on exactly the pages that teach it", wrong.isEmpty,
                 wrong.joined(separator: " "))
        let map = remapped(.command(.notes), label: "J")
        r.record("a chord is drawn with the Hotkeys tab's own label",
                 FeatureTour.chordLabel(.command(.notes), map: map) == map.key(for: .notes).label
                    && FeatureTour.chordLabel(.wakeup, map: map) == map.wakeup.label
                    && FeatureTour.chordLabel(.command(.bullseyeReveal), map: map) == "\u{21E7}N")
    }

    // MARK: - (c)

    private static var coreInstalled: BootstrapSnapshot {
        var snapshot = BootstrapSnapshot.fresh(descriptors: BootstrapInstallPlan.allComponents)
        for descriptor in BootstrapInstallPlan.mandatoryCore {
            snapshot.apply(InstallerComponentResult(componentID: descriptor.id, title: descriptor.title,
                                                    state: .installed))
        }
        return snapshot
    }

    /// One launch: classify, then the automatic show if it is owed. Returns the state after, and whether it showed.
    private static func launch(_ state: FeatureTourFirstShow.State, setupShows: Bool, classify: Classifier,
                               quitBeforeTour: Bool = false) -> (FeatureTourFirstShow.State, Bool) {
        let classified = classify(state, setupShows)
        guard !quitBeforeTour, FeatureTourFirstShow.shouldShow(.launch, classified) else { return (classified, false) }
        return (FeatureTourFirstShow.shown(classified), true)
    }

    private static func checkFirstShow(classify: Classifier, _ r: SelfTestReporter) {
        let blank = FeatureTourFirstShow.State(classified: false, seen: false)
        // S8's own rule decides whether setup shows: a fresh store does, a store whose core is installed does not,
        // and neither does a 1.1.0 Mac whose working core came from install-daemon.sh.
        let freshShows = FirstRunSetupLaunchRule.shouldPresent(.init(
            snapshot: BootstrapSnapshot.fresh(descriptors: BootstrapInstallPlan.allComponents),
            earlierCoreOnDisk: false))
        let installedShows = FirstRunSetupLaunchRule.shouldPresent(.init(snapshot: coreInstalled,
                                                                         earlierCoreOnDisk: false))
        let legacyShows = FirstRunSetupLaunchRule.shouldPresent(.init(
            snapshot: BootstrapSnapshot.fresh(descriptors: BootstrapInstallPlan.allComponents),
            earlierCoreOnDisk: true))
        r.record("S8's rule shows setup to a fresh store only (fresh, core installed, 1.1.0 install-daemon core)",
                 freshShows && !installedShows && !legacyShows)

        let (afterFirst, firstShown) = launch(blank, setupShows: freshShows, classify: classify)
        let (afterSecond, secondShown) = launch(afterFirst, setupShows: installedShows, classify: classify)
        r.record("a fresh install shows the tour on its first launch", firstShown)
        r.record("and not on its second", !secondShown && afterSecond.seen)

        let (quit, _) = launch(blank, setupShows: freshShows, classify: classify, quitBeforeTour: true)
        let (_, relaunchShown) = launch(quit, setupShows: installedShows, classify: classify)
        r.record("a fresh install that relaunched before its tour appeared is still owed it", relaunchShown)

        let (upgraded, upgradeShown) = launch(blank, setupShows: installedShows, classify: classify)
        let (_, upgradeAgain) = launch(upgraded, setupShows: installedShows, classify: classify)
        let (legacy, legacyShown) = launch(blank, setupShows: legacyShows, classify: classify)
        r.record(upgradeCheck, !upgradeShown && !upgradeAgain && upgraded.seen && upgraded.classified,
                 "shown at launch: \(upgradeShown), then \(upgradeAgain)")
        r.record("a 1.1.0 install whose core came from install-daemon.sh is marked seen too",
                 !legacyShown && legacy.seen)

        let states = [blank, afterFirst, quit, upgraded,
                      FeatureTourFirstShow.State(classified: false, seen: true)]
        r.record("the menu bar item opens the tour in every state",
                 states.allSatisfy { FeatureTourFirstShow.shouldShow(.menu, $0) })
        r.record("nothing shows by itself before a launch has classified the install",
                 !FeatureTourFirstShow.shouldShow(.launch, blank))
    }

    /// The pure rule cannot prove the app uses it, so the call sites are read the way `HangWatchdogSelfTest` reads
    /// its own: the menu item sits right under Settings... and opens page 1 with no first-show check, and the
    /// launch classifies before the first-run window and hands off to the tour last.
    private static func checkMenuWiring(_ r: SelfTestReporter) {
        let path = "Sources/App/AppDelegate.swift"
        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        r.record("AppDelegate is readable from the worktree root", !source.isEmpty,
                 source.isEmpty ? "run this gate from the repository root" : path)
        guard !source.isEmpty else { return }
        let lines = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let settings = lines.firstIndex { $0.contains("title: \"Settings\u{2026}\"") && $0.contains("openSettings") }
        let tour = lines.firstIndex {
            $0.contains("FeatureTour.menuTitle") && $0.contains("#selector(openFeatureTour)")
        }
        r.record("the menu bar item \"Feature Tour\u{2026}\" sits right under Settings\u{2026}",
                 FeatureTour.menuTitle == "Feature Tour\u{2026}" && settings != nil && tour == settings.map { $0 + 1 })
        let opener = lines.first { $0.contains("func openFeatureTour()") } ?? ""
        r.record("the menu item opens page 1 whatever featureTourSeen says",
                 opener.contains("featureTourWC.show(page: 0)") && !opener.contains("FeatureTourFirstShow"), opener)
        let classify = source.range(of: "recordFeatureTourLaunch(setupWindowShows:")
        let setup = source.range(of: "FirstRunSetupPresenter.shared.presentOnLaunchIfNeeded")
        let tourLast = source.range(of: "presentFirstRunOnboardingIfNeeded { [weak self] in")
            .flatMap { onboarding in
                source.range(of: "presentFeatureTourIfOwed()", range: onboarding.upperBound..<source.endIndex)
            }
        r.record("launch classifies before the first-run window, and the tour follows onboarding",
                 classify != nil && setup != nil && classify!.lowerBound < setup!.lowerBound && tourLast != nil)
    }

    // MARK: - (d)

    /// Built-in chord labels typed as words, and modifier glyphs, in a template with its placeholders taken out.
    static func hardCodedChords(in template: String) -> [String] {
        var text = template
        for name in FeatureTour.placeholders(in: template) {
            text = text.replacingOccurrences(of: "{\(name)}", with: " ")
        }
        var found = ["\u{2325}", "\u{21E7}", "\u{2318}", "\u{2303}", "Option+", "Option-"].filter(text.contains)
        let labels = Set(HotkeyCommand.allCases.map(\.defaultKey.label) + [HotkeyMap.defaultWakeup.label])
        for raw in text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()\u{201C}\u{201D}.,;:!?"))
            if labels.contains(raw) || (!trimmed.isEmpty && labels.contains(trimmed)) { found.append(raw) }
        }
        return found
    }

    private static func checkCopy(_ pages: [FeatureTourPage], _ r: SelfTestReporter) {
        let windowCopy = [FeatureTour.windowTitle, FeatureTour.menuTitle, FeatureTour.backTitle, FeatureTour.nextTitle,
                          FeatureTour.doneTitle, FeatureTour.skipTitle, FeatureTour.nonObviousHeader,
                          FeatureTour.keysHeader, FeatureTour.wakeupRowLabel, FeatureTour.permissionsHeader,
                          FeatureTour.localAppsHeader, FeatureTour.practiceHeader, FeatureTourPractice.relaunchNote,
                          FeatureTourPractice.placeholder,
                          FeatureTourPractice.note(.grantFirst, map: .defaults())]
        let all = pages.flatMap(\.templates) + windowCopy
        let evidence = all.filter { $0.lowercased().contains("ratif") || $0.lowercased().contains("tested") }
        r.record("no page or tour label says ratified or tested (D11: Staff pick)", evidence.isEmpty,
                 evidence.joined(separator: " | "))
        var typed: [String] = []
        for page in pages {
            for template in page.templates {
                typed += hardCodedChords(in: template).map { "\(page.id): \($0)" }
            }
        }
        typed += windowCopy.flatMap(hardCodedChords(in:)).map { "window: \($0)" }
        r.record(hardCodedCheck, typed.isEmpty, typed.joined(separator: " | "))
        r.record("the chord scan does see a typed chord",
                 hardCodedChords(in: "tap Space, then P or \u{2325}") == ["\u{2325}", "Space,", "P"])
    }

    // MARK: - (e)

    private static func checkLocalModelsPage(_ pages: [FeatureTourPage], _ r: SelfTestReporter) {
        guard let page = pages.first(where: { $0.id == "local-models" }) else {
            r.record("page 6 is the Local models page", false)
            return
        }
        r.record("page 6 is the Local models page", pages.firstIndex(of: page) == 5)
        let text = page.templates.joined(separator: " ")
        let sentences = text.components(separatedBy: ". ")
        let simple = sentences.firstIndex { $0.contains("LM Studio") && !$0.contains("Ollama")
            && $0.lowercased().contains("simple") }
        let advanced = sentences.firstIndex { $0.contains("Ollama") && !$0.contains("LM Studio")
            && $0.lowercased().contains("advanced") }
        r.record("LM Studio is the simple choice and Ollama the advanced one, LM Studio first",
                 simple != nil && advanced != nil && simple! < advanced!)
        r.record("either app, or both", text.contains("either, or both"))
        r.record("every built-in model is called a Staff pick", text.contains(StaffPicks.label))
        r.record("Ollama's one-time Touch ID or password prompt is named",
                 text.contains("Touch ID or your password") && text.contains("once"))
        r.record("the memory budget, the idle unload, and Not enough space in RAM are kept",
                 text.contains("memory budget") && text.contains("idle")
                    && text.contains("Not enough space in RAM") && text.contains("Setup tab"))
        r.record("the MLX tip names 32 GB and says ViddyDictate never turns it on",
                 text.contains("MLX") && text.contains("32 GB") && text.contains("never turns it on"))
        r.record("it shows the local apps live and links to the Setup tab",
                 page.liveStatus == .localApps && page.settingsLink == .setup)
    }

    // MARK: - D9

    private static func checkPractice(_ r: SelfTestReporter) {
        typealias P = FeatureTourPractice
        r.record("a live tap makes the practice box ready",
                 P.state(tapLive: true, accessibility: true, inputMonitoring: true) == .ready
                    && P.state(tapLive: true, accessibility: false, inputMonitoring: false) == .ready)
        r.record("both grants on but no tap in this launch means relaunch",
                 P.state(tapLive: false, accessibility: true, inputMonitoring: true) == .relaunchNeeded)
        r.record("a missing grant says grant first, not relaunch",
                 P.state(tapLive: false, accessibility: true, inputMonitoring: false) == .grantFirst
                    && P.state(tapLive: false, accessibility: false, inputMonitoring: true) == .grantFirst)
        r.record("the relaunch note is D9's words",
                 P.note(.relaunchNeeded, map: .defaults()) == "Relaunch ViddyDictate, then try here.")
        let map = remapped(.wakeup, label: "<wakeup-fixture-key>")
        r.record("the ready note names the live wakeup",
                 P.note(.ready, map: map).contains("<wakeup-fixture-key>"))
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(_ r: SelfTestReporter) {
        let real = FeatureTour.pages
        requireCaught(r, mutant: "page list missing the bullseye reveal", by: coverageCheck) {
            let pages = real.map { page -> FeatureTourPage in
                guard page.id == "sticky-notes" else { return page }
                return FeatureTourPage(
                    id: page.id, title: page.title,
                    body: page.body.map { $0.replacingOccurrences(of: " {bullseyeReveal} brings it to the front.",
                                                                  with: "") },
                    nonObvious: page.nonObvious,
                    commands: page.commands.filter { FeatureTour.token(for: $0) != "bullseyeReveal" },
                    settingsLink: page.settingsLink, liveStatus: page.liveStatus)
            }
            checkCoverage(pages, $0)
        }
        requireCaught(r, mutant: "renderer that always draws lock as Space", by: remapCheck) {
            checkRemap(real, render: { template, map in
                var fixed = map
                fixed.restoreDefault(.command(.lock))
                return FeatureTour.render(template, map: fixed)
            }, $0)
        }
        requireCaught(r, mutant: "page that types Space for lock", by: hardCodedCheck) {
            let pages = real.map { page -> FeatureTourPage in
                guard page.id == "dictation" else { return page }
                return FeatureTourPage(id: page.id, title: page.title,
                                       body: page.body.map { $0.replacingOccurrences(of: "{lock}", with: "Space") },
                                       nonObvious: page.nonObvious, commands: page.commands,
                                       settingsLink: page.settingsLink, liveStatus: page.liveStatus)
            }
            checkCopy(pages, $0)
        }
        requireCaught(r, mutant: "first-show rule that owes every install the tour", by: upgradeCheck) {
            checkFirstShow(classify: { state, _ in
                FeatureTourFirstShow.State(classified: true, seen: state.seen)
            }, $0)
        }
    }

    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }
}
