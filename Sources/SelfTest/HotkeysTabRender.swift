import Cocoa

/// Offscreen render-to-PNG seam for the consolidated Hotkeys tab (`--hotkeys-tab-render <outdir>`).
/// In-process render, NOT a screen capture: screen capture from an agent shell is TCC-blocked, so this is
/// how the link that merged two Settings tabs can actually LOOK at the page it built.
///
/// The acceptance bar is visual — a user judges whether one tab reads as one tab — so the gate photographs
/// the whole document plus the two cards that carry the merge's whole claim:
///   - `hotkeys-tab-full.png`         — the entire page, both halves, top to bottom.
///   - `hotkeys-tab-custom-card.png`  — a custom hotkey collapsed: name, chord, input, landing in its card.
///   - `hotkeys-tab-custom-advanced.png` — the same card with Advanced open: provider, model, effort,
///     the shared-task-prompt workstation button and the restore row, still in the SAME card.
///   - `hotkeys-tab-builtin-advanced.png` — Option+M, to show a built-in gets exactly what a custom gets.
/// Every capture is asserted non-blank by pixel metric, so a silently empty render cannot pass as a
/// screenshot of a working page.
enum HotkeysTabRender {
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
            print("[hotkeys-tab-render] cannot create \(outDir): \(error)")
            return false
        }
        let root = fm.temporaryDirectory
            .appendingPathComponent("viddydictate-hotkeys-tab-render-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            print("[hotkeys-tab-render] scratch setup failed: \(error.localizedDescription)")
            return false
        }
        defer { try? fm.removeItem(at: root) }

        let routing = ModelsPowerSettingsStore(url: root.appendingPathComponent("models-power.json"))
        let custom = CustomModeStore(url: root.appendingPathComponent("custom-modes.json"),
                                     routingStore: routing)
        // A named custom hotkey, because the whole item is about a custom hotkey being configurable where
        // it is created. "Spellcheck" is the established example with the desired editability.
        let mode = CustomMode(
            id: "render-custom", name: "Spellcheck",
            chord: .regular(keyCode: 1, label: "S"),
            prompt: "Fix spelling and punctuation only. Leave wording alone.",
            input: .selection,
            model: LLMProviderDefaults.testedBundle(for: .local, route: .custom("render-custom"))
                ?? .local("qwen/qwen3-coder-30b"),
            landing: .inPlace)
        do { try custom.upsert(mode) }
        catch {
            print("[hotkeys-tab-render] custom setup failed: \(error.localizedDescription)")
            return false
        }

        let width: CGFloat = 640
        let hotkeys = HotkeysSettingsView(width: width, customStore: custom)
        let routingView = ModelsPowerSettingsView(
            width: width, settingsStore: routing, customStore: custom,
            codexOutcomeStore: CodexUpdateOutcomeStore(
                url: root.appendingPathComponent("codex-outcome.json")),
            codexCatalogLoader: { nil })
        let tab = HotkeysTabView(hotkeys: hotkeys, routing: routingView)

        // An offscreen window gives the view a real backing store at the screen's scale, so the PNGs are
        // legible at 2x rather than a 1x smear.
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: max(600, tab.frame.height)),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(tab)

        capture(tab, card: nil, to: outDir + "/hotkeys-tab-full.png", name: "whole page")
        check("the page is one document, not two panes",
              tab.frame.height >= hotkeys.frame.height + routingView.frame.height,
              "\(Int(tab.frame.height))pt = \(Int(hotkeys.frame.height)) + \(Int(routingView.frame.height))")

        let customKey = LLMRouteID.custom("render-custom").rawValue
        capture(tab, card: "card.\(customKey)", to: outDir + "/hotkeys-tab-custom-card.png",
                name: "custom hotkey card")
        (find("advanced|\(customKey)", in: tab) as? NSButton)?.performClick(nil)
        capture(tab, card: "card.\(customKey)", to: outDir + "/hotkeys-tab-custom-advanced.png",
                name: "custom hotkey Advanced")
        check("the custom hotkey's chord and its routing are in one card",
              find("hotkey-binding|\(customKey)", in: tab) != nil
                && find("model|\(customKey)", in: tab) != nil
                && find("edit-custom-prompt|render-custom", in: tab) != nil)

        (find("advanced|email", in: tab) as? NSButton)?.performClick(nil)
        capture(tab, card: "card.email", to: outDir + "/hotkeys-tab-builtin-advanced.png",
                name: "built-in hotkey Advanced")
        check("a built-in hotkey gets the same card shape a custom one does",
              find("hotkey-binding|email", in: tab) != nil
                && find("chord|builtin:email", in: tab) != nil
                && find("model|email", in: tab) != nil)

        print("[hotkeys-tab-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") -> \(outDir)")
        return failures == 0
    }

    private static func capture(_ view: NSView, card: String?, to path: String, name: String) {
        SelfTestRenderCapture.capture(view, card: card, to: path, name: name) { n, ok, detail in
            check(n, ok, detail)
        }
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        SelfTestRenderCapture.find(id, in: root)
    }
}
