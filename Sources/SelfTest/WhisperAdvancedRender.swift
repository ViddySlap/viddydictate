import Cocoa

/// Offscreen render + structural gate for the installer's Voice models group (selectable Whisper
/// versions, part 3 of 3). This is the ONLY AppKit surface for this change: the pure model and pure
/// selftest are Foundation-only. It renders the real `ComponentPickerView` for two states (default
/// Turbo only; Turbo plus Large V3 with Large V3 active) in light and dark, and writes PNGs only when
/// `VD_RENDER_OUT` is a non-empty directory (the lane's replay link runs it natively). When that env
/// is unset it still renders and runs every in-memory check, but writes no files.
enum WhisperAdvancedRender {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    private struct Capture {
        let name: String
        let appearance: NSAppearance.Name
        let view: ComponentPickerView
        let pixels: SelfTestRenderCapture.Pixels?
    }

    /// Held for the lifetime of the gate: a borderless host window released mid-render takes the view
    /// hierarchy being photographed with it (the same reason ComponentPickerRender holds its hosts).
    private static var hosts: [NSWindow] = []

    static func run(outDir: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Pinned, so a capture does not silently change meaning with whatever this Mac is set to.
        app.appearance = NSAppearance(named: .aqua)

        let out = ProcessInfo.processInfo.environment["VD_RENDER_OUT"].flatMap { $0.isEmpty ? nil : $0 }
        if let out {
            do { try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true) }
            catch {
                check("render output directory", false, "cannot create \(out): \(error)")
                return false
            }
        }

        let turbo = WhisperModelCatalog.default.repo
        let largeV3 = "mlx-community/whisper-large-v3-mlx"
        let stateA = ComponentPicker.Selection()
        let stateB = ComponentPicker.Selection(whisper: WhisperVoiceModels.State(
            ticked: [turbo, largeV3], active: largeV3))

        let defaultLight = make(state: stateA, appearance: .aqua,
                                name: "whisper-advanced-default-light", outDir: out)
        let defaultDark = make(state: stateA, appearance: .darkAqua,
                               name: "whisper-advanced-default-dark", outDir: out)
        let twoLight = make(state: stateB, appearance: .aqua,
                            name: "whisper-advanced-two-models-light", outDir: out)
        let twoDark = make(state: stateB, appearance: .darkAqua,
                           name: "whisper-advanced-two-models-dark", outDir: out)

        for capture in [defaultLight, defaultDark, twoLight, twoDark] {
            backgroundCheck(capture)
            headerCheck(capture)
            footerCheck(capture)
        }

        structuralCheck(defaultLight, expectedActiveVariantID: "large-v3-turbo", name: "default-light")
        structuralCheck(defaultDark, expectedActiveVariantID: "large-v3-turbo", name: "default-dark")
        structuralCheck(twoLight, expectedActiveVariantID: "large-v3", name: "two-models-light")
        structuralCheck(twoDark, expectedActiveVariantID: "large-v3", name: "two-models-dark")

        print("[whisper-advanced-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")"
            + (out.map { " -> \($0)" } ?? ""))
        return failures == 0
    }

    // MARK: - build + capture

    private static func make(state: ComponentPicker.Selection, appearance: NSAppearance.Name,
                             name: String, outDir: String?) -> Capture {
        let view = ComponentPickerView(width: 620, selection: state, facts: mac(), environment: .init())
        view.wantsLayer = true
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: max(200, view.frame.height)),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.appearance = NSAppearance(named: appearance)
        host.contentView?.addSubview(view)
        hosts.append(host)
        applyBackdrop(to: view)

        let rep: NSBitmapImageRep?
        if let outDir {
            rep = SelfTestRenderCapture.capture(view, card: nil, to: outDir + "/" + name + ".png",
                                                name: name) { n, ok, detail in check(n, ok, detail) }
        } else {
            rep = SelfTestRenderCapture.render(view)
        }
        return Capture(name: name, appearance: appearance, view: view,
                       pixels: rep.flatMap { SelfTestRenderCapture.Pixels($0, of: view) })
    }

    private static func applyBackdrop(to view: NSView) {
        view.wantsLayer = true
        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private static func mac() -> ComponentPicker.MachineFacts {
        let physical = UInt64(64 * 1_073_741_824)
        let limit = Double(physical) * 0.820
        return ComponentPicker.MachineFacts(
            physicalBytes: physical,
            budgetBytes: UInt64(limit * 0.6),
            maxBudgetBytes: UInt64(limit * 1.0),
            wiredBytes: UInt64(5 * 1_000_000_000))
    }

    // MARK: - pixel checks

    private static func backgroundCheck(_ capture: Capture) {
        guard let pixels = capture.pixels else {
            check("[\(capture.name)] page background", false, "no pixels")
            return
        }
        let isDark = capture.appearance == .darkAqua
        let bg = pixels.rgb(x: 8, y: 1)
        let lum = SelfTestRenderCapture.luminance(bg)
        check("[\(capture.name)] page background \(isDark ? "is dark (lum < 0.35)" : "is light (lum > 0.65)")",
              isDark ? lum < 0.35 : lum > 0.65,
              "lum=\(String(format: "%.3f", lum))")
    }

    private static func headerCheck(_ capture: Capture) {
        guard let header = SelfTestRenderCapture.label(ComponentPicker.voiceHeaderIdentifier, in: capture.view),
              let pixels = capture.pixels else {
            check("[\(capture.name)] VOICE MODELS header contrast >= 4.5", false, "header or pixels missing")
            return
        }
        let rect = header.convert(SelfTestRenderCapture.textRect(of: header), to: capture.view)
        let contrast = pixels.textContrast(in: rect, of: capture.view) ?? 1
        check("[\(capture.name)] VOICE MODELS header contrast >= 4.5", contrast >= 4.5,
              "contrast=\(String(format: "%.2f", contrast))")
    }

    private static func footerCheck(_ capture: Capture) {
        guard let footer = SelfTestRenderCapture.label(ComponentPicker.totalIdentifier, in: capture.view),
              let pixels = capture.pixels else {
            check("[\(capture.name)] footer total contrast >= 4.5 and above Continue", false,
                  "footer or pixels missing")
            return
        }
        let rect = footer.convert(SelfTestRenderCapture.textRect(of: footer), to: capture.view)
        let contrast = pixels.textContrast(in: rect, of: capture.view) ?? 1
        let continueFrame = SelfTestRenderCapture.find(ComponentPicker.continueIdentifier, in: capture.view)?.frame
        let above = continueFrame.map { footer.frame.maxY <= $0.minY + 0.5 } ?? false
        let padding = continueFrame.map { $0.minY - footer.frame.maxY } ?? -1
        check("[\(capture.name)] footer total contrast >= 4.5 and above Continue", contrast >= 4.5
                && above && padding >= 8,
              "contrast=\(String(format: "%.2f", contrast)) padding=\(String(format: "%.1f", padding))")
    }

    // MARK: - structural checks

    private static func structuralCheck(_ capture: Capture, expectedActiveVariantID: String, name: String) {
        let view = capture.view
        let activeButtons = SelfTestRenderCapture.allViews(in: view).compactMap { $0 as? NSButton }
            .filter { ($0.identifier?.rawValue ?? "").hasSuffix("-active") && $0.state == .on }
        check("[\(name)] exactly one active voice radio", activeButtons.count == 1, "\(activeButtons.count)")
        if let active = activeButtons.first {
            check("[\(name)] the active radio is \(expectedActiveVariantID)",
                  active.identifier?.rawValue == ComponentPicker.voiceActiveIdentifier(expectedActiveVariantID),
                  active.identifier?.rawValue ?? "?")
        }

        let turboTicked = (SelfTestRenderCapture.find(
            ComponentPicker.voiceTickIdentifier("large-v3-turbo"), in: view) as? NSButton)?.state == .on
        check("[\(name)] Large V3 Turbo is ticked", turboTicked)

        let largeV3Ticked = (SelfTestRenderCapture.find(
            ComponentPicker.voiceTickIdentifier("large-v3"), in: view) as? NSButton)?.state == .on
        if expectedActiveVariantID == "large-v3" {
            check("[\(name)] Large V3 is ticked and active",
                  largeV3Ticked && activeButtons.first?.identifier?.rawValue
                    == ComponentPicker.voiceActiveIdentifier("large-v3"))
        } else {
            check("[\(name)] Large V3 is not ticked", !largeV3Ticked)
        }

        let allCards = WhisperModelCatalog.variants.allSatisfy {
            SelfTestRenderCapture.find(ComponentPicker.voiceCardIdentifier($0.id), in: view) != nil
        }
        check("[\(name)] all four voice cards exist", allCards)
    }
}
