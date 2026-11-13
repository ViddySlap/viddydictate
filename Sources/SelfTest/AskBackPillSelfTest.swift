import Foundation

// VDASK-5 self-test: the compact pill word and the ? toggle's pure rules, plus source-shape rows for the AppKit
// wiring no headless row can reach (the controller-level click rows live in AskBackControllerSelfTest.swift).
// Mirrors the Linux oracle's pill-rows.swift. Synthetic only.

enum AskBackPillSelfTest {
    static func run() -> Bool {
        print("--- ask-back pill: compact word, ? toggle rules, wiring ---")
        let check = SelfTestReporter()

        // The compact word, from the level.
        check("pill: compact word for Cleanup, Tighten and Summarize",
              CompactPillWord.word(forLevel: 0) == "CLEANUP" && CompactPillWord.word(forLevel: 1) == "TIGHTEN"
                && CompactPillWord.word(forLevel: 2) == "SUMMARIZE")
        check("pill: an out-of-range level clamps to the end words",
              CompactPillWord.word(forLevel: -3) == "CLEANUP" && CompactPillWord.word(forLevel: 9) == "SUMMARIZE")
        check("pill: compact paints only the active word; the full layout paints all three",
              (0...2).allSatisfy { CompactPillWord.drawnIndices(level: $0, compact: true) == [$0] }
                && CompactPillWord.drawnIndices(level: 1, compact: false) == [0, 1, 2])
        check("pill: the slider's three labels are the compact words (one source)",
              StrengthSlider.threeStopLabels == CompactPillWord.words)

        // The ? state for each combination of setting, level and provider.
        let providers: [AskBackProvider?] = [.claude, .codex, .local, nil]
        var tableOK = true, greyOK = true, cleanupOK = true, brightOK = true, tipOK = true
        for enabled in [true, false] {
            for level in AskBackLevel.allCases {
                for p in providers {
                    let s = AskBackToggleRules.state(enabled: enabled, level: level, provider: p)
                    let cloud = (p == .claude || p == .codex)
                    if cloud != s.clickable { tableOK = false }
                    if !cloud && (s.bright || s.outlined || s.tooltip != "Ask-back needs Claude or Codex") { greyOK = false }
                    if cloud && level == .cleanup && !(s.clickable && !s.bright && s.outlined) { cleanupOK = false }
                    if cloud && level != .cleanup && (s.bright != enabled || s.outlined) { brightOK = false }
                    if cloud && s.tooltip != (enabled ? "Ask-back on: questions before Tighten and Summarize" : "Ask-back off") { tipOK = false }
                }
            }
        }
        check("toggle: clickable exactly when the route is Claude or Codex (setting x level x provider)", tableOK)
        check("toggle: a local or off route is greyed with the tooltip, whatever the setting or level", greyOK)
        check("toggle: Cleanup on Claude or Codex stays clickable but dim-outlined", cleanupOK)
        check("toggle: Tighten and Summarize are bright when on, dim when off", brightOK)
        check("toggle: the on and off tooltips are exact", tipOK)

        let live = AskBackToggleRules.state(enabled: true, level: .tighten, provider: .claude)
        let grey = AskBackToggleRules.state(enabled: true, level: .tighten, provider: .local)
        check("click: a clickable ? flips the setting both ways",
              AskBackToggleRules.settingAfterClick(enabled: true, state: live) == false
                && AskBackToggleRules.settingAfterClick(enabled: false, state: live) == true)
        check("click: a greyed ? ignores a click", AskBackToggleRules.settingAfterClick(enabled: true, state: grey) == nil
              && AskBackToggleRules.settingAfterClick(enabled: false, state: grey) == nil)

        // Source-shape rows, named: AppKit views and the tap-free HUD wiring a headless row cannot construct.
        let appDir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        func src(_ name: String) -> String {
            (try? String(contentsOf: appDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let hud = src("HUDPanel.swift")
        func body(_ from: String, _ upTo: String) -> String {
            guard let r = hud.range(of: from), let e = hud[r.upperBound...].range(of: upTo) else { return "" }
            return String(hud[r.lowerBound..<e.lowerBound])
        }
        check("wiring (AppKit button): the ? button refuses first responder, so a click never takes key focus from the paste target",
              body("final class AskBackToggleButton", "required init?").contains("refusesFirstResponder = true"))
        let apply = body("func apply(_ s: AskBackToggleState)", "private func updateStyle")
        check("wiring (AppKit button): the ? button is disabled when greyed and carries the state's tooltip",
              apply.contains("isEnabled = s.clickable") && apply.contains("toolTip = s.tooltip"))
        check("wiring (HUD panel): the button's action calls onToggleAskBack and it hides and shows with Lock and Stop",
              hud.contains("@objc private func askBackClicked() { onToggleAskBack?() }")
                && hud.contains("root.addSubview(askBackButton)")
                && hud.contains("lockButton.isHidden = hidden; stopButton.isHidden = hidden; askBackButton.isHidden = hidden")
                && hud.contains("lockButton.isHidden = false; stopButton.isHidden = false; askBackButton.isHidden = false"))
        check("wiring (info pill): the pill's slider is compact and paints through CompactPillWord.drawnIndices",
              src("InfoPill.swift").contains("slider.compactWord = true")
                && src("StrengthSlider.swift").contains("CompactPillWord.drawnIndices(level: CleanupLevel.clamped(level).rawValue, compact: compactWord)"))
        let dc = src("DictationController.swift")
        check("wiring (controller): the HUD click reaches toggleAskBackFromHUD, and a Settings or route change refreshes the ?",
              dc.contains("hud.onToggleAskBack = { [weak self] in self?.toggleAskBackFromHUD() }")
                && dc.contains("forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshAskBackToggle() }")
                && dc.contains("forName: ModelsPowerSettingsStore.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshAskBackToggle() }"))
        let settingsView = src("ModelsPowerSettingsView.swift")
        check("wiring (Settings): the checkbox reads Settings.askBackEnabled and the Settings view rebuilds on Settings.didChange, so it follows the ?",
              settingsView.contains("askCheck.state = Settings.askBackEnabled ? .on : .off")
                && settingsView.contains("forName: Settings.didChange, object: nil, queue: .main\n        ) { [weak self] _ in self?.rebuild() }"))

        print(check.summaryLine(prefix: "[askback-pill-selftest]"))
        return check.passed
    }
}
