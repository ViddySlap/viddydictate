import Cocoa
import Security

/// Offscreen render-to-PNG seam for the Setup tab (`--setup-render <outdir>`), the surface that shows P8's
/// preflight report (item P11).
///
/// Like `--hud-render` and `--models-power-render` this is an in-process render, NOT a screen capture
/// (screen capture from an agent shell is TCC-blocked), so the link that builds the surface can actually
/// LOOK at it. The observation is synthetic, so nothing here depends on this machine's daemon, providers,
/// keychain, or TCC grants - which also means the "before" capture can be a machine where every single
/// check fails, a state no real Mac would helpfully be in on demand.
///
/// PNGs written:
///   - `setup-warnings.png`     - every check failing: seven rows, each with its fix and its consequence.
///   - `setup-row-provider.png` - the longest row on its own (the no-provider remedy is a menu of three).
///   - `setup-clean.png`        - after Check again on a now-healthy machine: the same surface, all OK.
///   - `setup-gemini-key.png`   - the Gemini key section with no key stored: the instructions, the URL, the
///                                warm line, the secure field (L5).
///   - `setup-gemini-saved.png` - the same section after a key was pasted and saved, which is also the proof
///                                the field was CLEARED and the value reached no label.
///   - `setup-gemini-delete-confirm.png` - the delete confirmation, mid-question, with the key still stored
///                                (L9).
///   - `setup-gemini-environment.png`    - the one state that offers no delete at all: a key arriving from
///                                the environment override, with the reason on screen (L9).
/// The pair is the before/after proof that the surface is re-runnable rather than a first-run snapshot.
enum SetupRender {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    static func run(outDir: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Pin the appearance so a capture does not silently change meaning with whatever the host Mac is
        // set to. The app itself follows the system; only the render seam is pinned.
        app.appearance = NSAppearance(named: .darkAqua)

        let fm = FileManager.default
        do { try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[setup-render] cannot create \(outDir): \(error)")
            return false
        }

        // The measuring half, replaced. `calls` is what proves Check again actually re-measures instead of
        // re-rendering a cached verdict: a button that only redrew would leave this at 1.
        var observation = PreflightSelfTest.broken
        var calls = 0
        let view = SetupSettingsView(width: 640) { completion in
            calls += 1
            completion(observation)
        }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        // In the app this view is a scroll-view document over the tab's own backdrop. Captured on its own it
        // has neither, and the mixed layer-backed/unlayered hierarchy that produces renders a bezelled
        // control's title onto transparency - the Check again button came out as a blank white pill. Giving
        // the captured root a layer and the window backdrop it normally sits on restores it. Same class of
        // artifact the prompt-editor capture documents in ModelsPowerRender.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        check("building the surface runs the check once", calls == 1, "calls=\(calls)")
        assertReport(view, Preflight.evaluate(observation), state: "warnings")
        assertLayout(view)
        capture(view, card: nil, to: outDir + "/setup-warnings.png", name: "warnings")
        capture(view, card: PreflightSurface.cardIdentifier(.textProvider),
                to: outDir + "/setup-row-provider.png", name: "provider row")

        // Re-run against a machine that has since been fixed. Same view, same button, new reading.
        observation = PreflightSelfTest.healthy
        let button = find(PreflightSurface.recheckIdentifier, in: view) as? NSButton
        check("Check again is offered once a check has finished", button?.isEnabled == true)
        button?.performClick(nil)
        check("Check again measures the machine again", calls == 2, "calls=\(calls)")
        assertReport(view, Preflight.evaluate(observation), state: "clean")
        assertLayout(view)
        check("a fixed machine leaves no stale fix on screen",
              PreflightCheck.allCases.allSatisfy {
                  find(PreflightSurface.identifier(.remedy, $0), in: view) == nil
                      && find(PreflightSurface.identifier(.reduced, $0), in: view) == nil
              })
        capture(view, card: nil, to: outDir + "/setup-clean.png", name: "clean")

        view.removeFromSuperview()
        driveGeminiKeySection(outDir: outDir)
        print("[setup-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    // MARK: - The Gemini key section (L5, spec decision D7)

    /// The section that takes a secret, driven end to end on its own tab with a synthetic writer in place of
    /// the login keychain (an agent shell cannot write one, and this gate must not depend on machine state).
    ///
    /// What a screenshot cannot assert, and this does: that the field is a SECURE field, that a pasted key
    /// reaches the app's keychain writer, that no label anywhere on the tab carries the value afterwards,
    /// that a successful save clears the field and re-MEASURES the tab (so the preflight key row below
    /// refreshes from the same observation), and that a blank Save writes nothing at all.
    ///
    /// L9 adds the other half: that a stored key can be REMOVED, that one click asks rather than deleting,
    /// that cancelling changes nothing, that a confirmed delete reaches the app's one `SecItemDelete`, and
    /// that the section re-measures afterwards instead of announcing a result it did not verify.
    private static func driveGeminiKeySection(outDir: String) {
        var keySource: SecretStore.Source?
        var written: [String] = []
        var deletes = 0
        var calls = 0
        let view = SetupSettingsView(width: 640, observer: { completion in
            calls += 1
            var observation = PreflightSelfTest.broken
            observation.webAnswerKeySource = keySource
            completion(observation)
        }, geminiKeyWriter: { value in
            written.append(value)
            // Stored for real, as far as this surface can tell: the next measurement finds a key, exactly as
            // it would after a real SecItemAdd.
            keySource = .keychain
            return errSecSuccess
        }, geminiKeyDeleter: {
            deletes += 1
            // Gone for real, as far as this surface can tell: the next measurement finds nothing, exactly as
            // it would after a real SecItemDelete on a machine with no override exported.
            keySource = nil
            return errSecSuccess
        })
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1800),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        check("[gemini] the section is on the Setup tab",
              find(GeminiKeySetup.cardIdentifier, in: view) != nil)
        assertGeminiCopy(view, status: .notStored, state: "no key")
        assertGeminiLayout(view, state: "no key")
        capture(view, card: GeminiKeySetup.cardIdentifier, to: outDir + "/setup-gemini-key.png",
                name: "gemini key section")

        guard let field = find(GeminiKeySetup.identifier(.field), in: view) as? NSTextField else {
            check("[gemini] the section offers a field to paste a key into", false)
            return
        }
        // Secure by type, not by a flag: an NSSecureTextField cannot be made to display what it holds.
        check("[gemini] the key is typed into a secure field", field is NSSecureTextField,
              String(describing: type(of: field)))
        check("[gemini] the empty field prompts for the key rather than showing anything",
              field.stringValue.isEmpty && !(field.placeholderString ?? "").isEmpty)

        guard let save = find(GeminiKeySetup.identifier(.save), in: view) as? NSButton else {
            check("[gemini] the section offers a Save button", false)
            return
        }

        // A blank Save must write NOTHING: an empty write would replace a working key with an empty one.
        save.performClick(nil)
        check("[gemini] saving an empty field writes nothing", written.isEmpty, "\(written.count) write(s)")
        check("[gemini] saving an empty field says so instead of claiming a save",
              label(GeminiKeySetup.identifier(.message), in: view)?.stringValue
                == GeminiKeySetup.message(.nothingEntered))
        check("[gemini] a blank save does not re-measure the tab", calls == 1, "calls=\(calls)")

        // The real path: a canary key pasted and saved.
        let canary = "AIzaSY-RENDER-CANARY-\(UUID().uuidString)"
        (find(GeminiKeySetup.identifier(.field), in: view) as? NSTextField)?.stringValue = canary
        (find(GeminiKeySetup.identifier(.save), in: view) as? NSButton)?.performClick(nil)
        check("[gemini] the pasted key reaches the app's own keychain writer, once",
              written == [canary], "\(written.count) write(s)")
        check("[gemini] a stored key re-measures the tab rather than trusting the section's own write",
              calls == 2, "calls=\(calls)")
        check("[gemini] the field is cleared once the key is stored",
              (find(GeminiKeySetup.identifier(.field), in: view) as? NSTextField)?.stringValue.isEmpty
                == true)
        check("[gemini] the section confirms the save",
              label(GeminiKeySetup.identifier(.message), in: view)?.stringValue
                == GeminiKeySetup.message(.stored))
        assertGeminiCopy(view, status: .stored(.keychain), state: "stored")
        assertGeminiLayout(view, state: "stored")

        // The whole point of D7's never-echo rule, asserted over the ENTIRE tab rather than the one field:
        // no label, no tooltip, and no control title anywhere may carry the value.
        check("[gemini] nothing on the tab echoes the stored key", echoes(of: canary, in: view).isEmpty,
              echoes(of: canary, in: view).joined(separator: ","))

        // The preflight row below the section reads the SAME measurement, so it has to have gone green too.
        check("[gemini] the preflight key row agrees with the section after the save",
              keyRowStatus(in: view) == expectedKeyRowStatus(.keychain))

        capture(view, card: GeminiKeySetup.cardIdentifier, to: outDir + "/setup-gemini-saved.png",
                name: "gemini key section (stored)")

        // --- Deleting the stored key (L9) ---
        //
        // The product decision overrides the earlier "Replace only" design: a stored key can be replaced OR removed
        // in the app. What follows is the whole affordance driven through the real controls - the mis-click
        // guard, the cancel, the delete, and the re-measurement that keeps the section from claiming a
        // result it did not verify.
        check("[gemini] a stored key offers a way to delete it",
              find(GeminiKeySetup.identifier(.delete), in: view) != nil)
        check("[gemini] a stored key is not asked about until Delete is clicked",
              find(GeminiKeySetup.identifier(.deletePrompt), in: view) == nil
                && find(GeminiKeySetup.identifier(.deleteConfirm), in: view) == nil)

        // A single mis-click must not drop a working key.
        (find(GeminiKeySetup.identifier(.delete), in: view) as? NSButton)?.performClick(nil)
        check("[gemini] one click on Delete asks rather than deleting",
              deletes == 0 && calls == 2, "\(deletes) delete(s), calls=\(calls)")
        check("[gemini] the confirmation says what it is about to do",
              label(GeminiKeySetup.identifier(.deletePrompt), in: view)?.stringValue
                == GeminiKeySetup.deletePrompt)
        check("[gemini] the key still reads as stored while the question is open",
              label(GeminiKeySetup.identifier(.status), in: view)?.stringValue
                == GeminiKeySetup.statusText(.stored(.keychain)))
        assertGeminiLayout(view, state: "delete confirm")
        capture(view, card: GeminiKeySetup.cardIdentifier,
                to: outDir + "/setup-gemini-delete-confirm.png", name: "gemini key section (confirm delete)")

        // Backing out leaves the key exactly where it was.
        (find(GeminiKeySetup.identifier(.deleteCancel), in: view) as? NSButton)?.performClick(nil)
        check("[gemini] cancelling the confirmation deletes nothing and re-measures nothing",
              deletes == 0 && calls == 2, "\(deletes) delete(s), calls=\(calls)")
        check("[gemini] cancelling takes the question off screen and offers Delete again",
              find(GeminiKeySetup.identifier(.deletePrompt), in: view) == nil
                && find(GeminiKeySetup.identifier(.delete), in: view) != nil)
        assertGeminiCopy(view, status: .stored(.keychain), state: "cancelled")

        // The real path: ask, then answer.
        (find(GeminiKeySetup.identifier(.delete), in: view) as? NSButton)?.performClick(nil)
        (find(GeminiKeySetup.identifier(.deleteConfirm), in: view) as? NSButton)?.performClick(nil)
        check("[gemini] a confirmed delete reaches the app's own keychain delete, once",
              deletes == 1, "\(deletes) delete(s)")
        check("[gemini] a delete re-measures the tab rather than trusting the section's own delete",
              calls == 3, "calls=\(calls)")
        check("[gemini] the section reports the removal",
              label(GeminiKeySetup.identifier(.message), in: view)?.stringValue
                == GeminiKeySetup.message(.removed))
        assertGeminiCopy(view, status: .notStored, state: "deleted")
        assertGeminiLayout(view, state: "deleted")
        check("[gemini] a removed key leaves nothing to delete on screen",
              GeminiKeySetup.Part.allCases
                .filter { [.delete, .deletePrompt, .deleteConfirm, .deleteCancel].contains($0) }
                .allSatisfy { find(GeminiKeySetup.identifier($0), in: view) == nil })
        check("[gemini] the field is still offered after a delete, so a new key can be pasted in",
              find(GeminiKeySetup.identifier(.field), in: view) is NSSecureTextField)
        check("[gemini] nothing on the tab echoes the deleted key either",
              echoes(of: canary, in: view).isEmpty, echoes(of: canary, in: view).joined(separator: ","))

        // The row an inch below the section read the same measurement, so it has to have gone back to a
        // warning. This is the property that makes the delete honest: the section cannot report a feature
        // off while the preflight row says it is on, because neither of them decides.
        check("[gemini] the preflight key row agrees with the section after the delete",
              keyRowStatus(in: view) == expectedKeyRowStatus(nil))
        view.removeFromSuperview()

        driveGeminiEnvironmentState(outDir: outDir)
    }

    /// The state that made this affordance worth declining until it could be built honestly: a key arriving
    /// from `VIDDYDICTATE_GEMINI_API_KEY` rather than the keychain.
    ///
    /// `SecretStore` resolves keychain first, so this state means the keychain held NOTHING - a Delete
    /// button here would delete nothing, report success, and leave Option+G answering. The section offers no
    /// control at all and says so instead. That is asserted here rather than reasoned about, because "the
    /// button is not there" is exactly the kind of claim that rots silently.
    private static func driveGeminiEnvironmentState(outDir: String) {
        let view = SetupSettingsView(width: 640, observer: { completion in
            var observation = PreflightSelfTest.broken
            observation.webAnswerKeySource = .environment
            completion(observation)
        }, geminiKeyWriter: { _ in errSecSuccess },
           geminiKeyDeleter: {
            check("[gemini override] the section never reaches the keychain delete in this state", false)
            return errSecSuccess
        })
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1800),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        check("[gemini override] an override-sourced key offers no delete control",
              GeminiKeySetup.Part.allCases
                .filter { [.delete, .deletePrompt, .deleteConfirm, .deleteCancel].contains($0) }
                .allSatisfy { find(GeminiKeySetup.identifier($0), in: view) == nil })
        check("[gemini override] the section says why, in full, where the button would have been",
              label(GeminiKeySetup.identifier(.environmentNote), in: view)?.stringValue
                == GeminiKeySetup.environmentNote)
        check("[gemini override] the field is still offered, so a key can be stored properly",
              find(GeminiKeySetup.identifier(.field), in: view) is NSSecureTextField)
        assertGeminiCopy(view, status: .stored(.environment), state: "override")
        assertGeminiLayout(view, state: "override")
        capture(view, card: GeminiKeySetup.cardIdentifier,
                to: outDir + "/setup-gemini-environment.png", name: "gemini key section (override)")
        view.removeFromSuperview()
    }

    /// Every label, tooltip, and control title on the tab that carries `value`. Empty is the only passing
    /// answer; the identifiers come back so a failure names the surface that echoed rather than just saying
    /// that one did.
    private static func echoes(of value: String, in view: NSView) -> [String] {
        var found: [String] = []
        sweep(view) { subview in
            if let text = subview as? NSTextField, !(text is NSSecureTextField),
               text.stringValue.contains(value) {
                found.append("label:\(text.identifier?.rawValue ?? "?")")
            }
            if subview.toolTip?.contains(value) == true {
                found.append("tooltip:\(subview.identifier?.rawValue ?? "?")")
            }
            if let button = subview as? NSButton, button.title.contains(value) {
                found.append("button:\(button.identifier?.rawValue ?? "?")")
            }
        }
        return found
    }

    private static func keyRowStatus(in view: NSView) -> String? {
        label(PreflightSurface.identifier(.status, .webAnswerKey), in: view)?.stringValue
    }

    private static func expectedKeyRowStatus(_ source: SecretStore.Source?) -> String {
        var observation = PreflightSelfTest.broken
        observation.webAnswerKeySource = source
        return PreflightSurface.statusText(Preflight.evaluate(observation).finding(.webAnswerKey)!)
    }

    /// Every line the pure layer says the section shows, on screen and reading exactly what it says.
    private static func assertGeminiCopy(_ view: NSView, status: GeminiKeySetup.Status, state: String) {
        var wrong: [String] = []
        let expected: [(GeminiKeySetup.Part, String)] = [
            (.status, GeminiKeySetup.statusText(status)),
            (.headline, GeminiKeySetup.headline(status)),
            (.statusLine, GeminiKeySetup.statusLine(status)),
            (.turnsOn, GeminiKeySetup.turnsOn),
            (.instructions, GeminiKeySetup.instructions),
            (.agentHelp, GeminiKeySetup.agentHelp),
            (.fieldHint, GeminiKeySetup.fieldHint(status)),
            (.fallback, GeminiKeySetup.fallback),
        ]
        for (part, value) in expected
        where label(GeminiKeySetup.identifier(part), in: view)?.stringValue != value {
            wrong.append(part.rawValue)
        }
        check("[gemini \(state)] every line of the section is on screen and is the pure layer's own",
              wrong.isEmpty, wrong.joined(separator: ","))
        // The two facts a user cannot get anywhere else, held at the surface as well as in the pure gate.
        check("[gemini \(state)] the console URL is on screen",
              label(GeminiKeySetup.identifier(.instructions), in: view)?.stringValue
                .contains("https://aistudio.google.com/apikey") == true)
        check("[gemini \(state)] the shipped script is named on screen as the fallback",
              label(GeminiKeySetup.identifier(.fallback), in: view)?.stringValue
                .contains("./scripts/set-gemini-key.sh") == true)
    }

    /// The layout claims a screenshot cannot make for itself. The section is the tallest card on the tab and
    /// it holds a control, so a clipped line here would hide the URL or leave Save under the next section.
    private static func assertGeminiLayout(_ view: NSView, state: String) {
        guard let card = find(GeminiKeySetup.cardIdentifier, in: view) else {
            check("[gemini \(state)] the section has a card", false)
            return
        }
        var clipped: [String] = []
        // Controls are excluded: they are fixed-height by design, and the claim here is about text that has
        // to be READ in full. `Part.isControl` owns that split, so a control added later cannot red this.
        for part in GeminiKeySetup.Part.allCases where !part.isControl {
            guard let field = label(GeminiKeySetup.identifier(part), in: view) else { continue }
            let needed = field.sizeThatFits(
                NSSize(width: field.frame.width, height: .greatestFiniteMagnitude)).height
            if field.frame.height + 0.5 < needed { clipped.append(part.rawValue) }
        }
        check("[gemini \(state)] no line of the section is clipped by its own frame",
              clipped.isEmpty, clipped.joined(separator: ","))

        let contentBottom = card.subviews.map(\.frame.maxY).max() ?? 0
        check("[gemini \(state)] the card contains its own contents",
              card.frame.height + 0.5 >= contentBottom,
              "card=\(Int(card.frame.height)) content=\(Int(contentBottom))")
        check("[gemini \(state)] the tab is tall enough to scroll to the section",
              view.frame.height >= card.convert(card.bounds, to: view).maxY,
              "height=\(Int(view.frame.height)) card ends \(Int(card.convert(card.bounds, to: view).maxY))")

        // The field and the button share a row, so a width change on either would silently overlap them.
        if let field = find(GeminiKeySetup.identifier(.field), in: view),
           let save = find(GeminiKeySetup.identifier(.save), in: view) {
            check("[gemini \(state)] the field and Save do not overlap",
                  field.frame.maxX <= save.frame.minX + 0.5,
                  "field ends \(Int(field.frame.maxX)), Save starts \(Int(save.frame.minX))")
            check("[gemini \(state)] Save is inside the card",
                  save.frame.maxX <= card.bounds.maxX + 0.5)
        }

        // The confirmation's two buttons share a row the same way, and a destructive control half-outside
        // its card is how the wrong one gets clicked.
        if let confirm = find(GeminiKeySetup.identifier(.deleteConfirm), in: view),
           let cancel = find(GeminiKeySetup.identifier(.deleteCancel), in: view) {
            check("[gemini \(state)] Delete and Cancel do not overlap",
                  confirm.frame.maxX <= cancel.frame.minX + 0.5,
                  "Delete ends \(Int(confirm.frame.maxX)), Cancel starts \(Int(cancel.frame.minX))")
            check("[gemini \(state)] the confirmation's buttons are inside the card",
                  cancel.frame.maxX <= card.bounds.maxX + 0.5)
        }

        // The section must sit below the provider sign-in section, not on top of it (one document view).
        if let providerCard = find(ProviderOnboarding.cardIdentifier(.codex), in: view) {
            let provider = providerCard.convert(providerCard.bounds, to: view)
            let gemini = card.convert(card.bounds, to: view)
            check("[gemini \(state)] the section sits below the provider sign-in section",
                  gemini.minY >= provider.maxY - 0.5,
                  "provider ends \(Int(provider.maxY)), gemini starts \(Int(gemini.minY))")
        }
    }

    private static func sweep(_ root: NSView, _ visit: (NSView) -> Void) {
        visit(root)
        root.subviews.forEach { sweep($0, visit) }
    }

    /// Every row the report describes is on screen, headed by its own title, and reading exactly what the
    /// presentation layer says it should. This is the assertion that makes the PNG trustworthy: a capture
    /// alone cannot tell a correct row from a plausible one.
    private static func assertReport(_ view: NSView, _ report: PreflightReport, state: String) {
        check("[\(state)] the headline reports the count the report carries",
              label(PreflightSurface.headlineIdentifier, in: view)?.stringValue
                == PreflightSurface.headline(report))

        var wrong: [String] = []
        for finding in report.findings {
            let target = finding.check
            if label(PreflightSurface.identifier(.title, target), in: view)?.stringValue
                != target.title { wrong.append("\(target.rawValue).title") }
            if label(PreflightSurface.identifier(.status, target), in: view)?.stringValue
                != PreflightSurface.statusText(finding) { wrong.append("\(target.rawValue).status") }
            if label(PreflightSurface.identifier(.summary, target), in: view)?.stringValue
                != finding.summary { wrong.append("\(target.rawValue).summary") }
            // Present exactly when the finding has one: a passing row that rendered a "Fix:" line would be
            // as wrong as a warning row that dropped it.
            if label(PreflightSurface.identifier(.remedy, target), in: view)?.stringValue
                != PreflightSurface.remedyLine(finding) { wrong.append("\(target.rawValue).remedy") }
            if label(PreflightSurface.identifier(.reduced, target), in: view)?.stringValue
                != PreflightSurface.reducedLine(finding) { wrong.append("\(target.rawValue).reduced") }
        }
        check("[\(state)] every check is on screen and every line of it is the finding's own",
              wrong.isEmpty, wrong.joined(separator: ","))
        check("[\(state)] one card per check, none missing",
              PreflightCheck.allCases.allSatisfy {
                  find(PreflightSurface.cardIdentifier($0), in: view) != nil
              })
    }

    /// The layout claims a screenshot cannot make for itself: nothing is clipped, nothing overlaps, and the
    /// document view is tall enough to contain what it holds. The longest remedy here is a three-option menu
    /// that wraps to several lines, and a clipped remedy is not an actionable message.
    private static func assertLayout(_ view: NSView) {
        var clipped: [String] = []
        for target in PreflightCheck.allCases {
            for part in [PreflightSurface.RowPart.summary, .remedy, .reduced] {
                guard let field = label(PreflightSurface.identifier(part, target), in: view) else { continue }
                let needed = field.sizeThatFits(
                    NSSize(width: field.frame.width, height: .greatestFiniteMagnitude)).height
                if field.frame.height + 0.5 < needed {
                    clipped.append("\(target.rawValue).\(part.rawValue)")
                }
            }
        }
        check("no row's text is clipped by its own frame", clipped.isEmpty, clipped.joined(separator: ","))

        let cards = PreflightCheck.allCases
            .compactMap { find(PreflightSurface.cardIdentifier($0), in: view) }
            .sorted { $0.frame.minY < $1.frame.minY }
        var overlapping = false
        for (previous, next) in zip(cards, cards.dropFirst()) where next.frame.minY < previous.frame.maxY {
            overlapping = true
        }
        check("the rows do not overlap each other", !overlapping, "\(cards.count) cards")

        let deepest = cards.map(\.frame.maxY).max() ?? 0
        check("the surface is tall enough to scroll to its last row",
              view.frame.height >= deepest,
              "height=\(Int(view.frame.height)) last row ends \(Int(deepest))")

        for target in PreflightCheck.allCases {
            guard let card = find(PreflightSurface.cardIdentifier(target), in: view) else { continue }
            let contentBottom = card.subviews.map(\.frame.maxY).max() ?? 0
            if card.frame.height < contentBottom {
                check("card \(target.rawValue) contains its own contents", false,
                      "card=\(Int(card.frame.height)) content=\(Int(contentBottom))")
                return
            }
        }
        check("every card contains its own contents", true)
    }

    /// Render `card` (or the whole view) to PNG and assert it carries real pixels. The mechanics are shared
    /// with the other capture gates (`SelfTestRenderCapture`); this gate keeps only its own check accounting.
    private static func capture(_ view: NSView, card: String?, to path: String, name: String) {
        SelfTestRenderCapture.capture(view, card: card, to: path, name: name) { n, ok, detail in
            check(n, ok, detail)
        }
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        SelfTestRenderCapture.find(id, in: root)
    }

    private static func label(_ id: String, in root: NSView) -> NSTextField? {
        SelfTestRenderCapture.label(id, in: root)
    }
}
