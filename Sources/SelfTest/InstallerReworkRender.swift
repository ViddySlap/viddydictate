import Cocoa

/// Offscreen render-to-PNG seam for the installer-rework chain (`--installer-rework-render <dir>`).
///
/// NOT protected: a later link in this chain extends this file as new screens land (welcome-recommended,
/// welcome-advanced, welcome-dictation-only, permissions-relaunch, ready-ok, ready-degraded). It reuses
/// `SelfTestRenderCapture`, like every other render gate - this is an in-process render, not a screen
/// capture, since screen capture from an agent shell is TCC-blocked.
///
/// Its one job beyond `--component-picker-render` and `--install-progress-render` is appearance: every
/// screen that exists today is captured in BOTH light and dark, so a judge sees the installer the way a
/// real Mac shows it rather than only the pinned dark fixture the other two render gates use.
///
/// PNGs written, `-light` and `-dark` each:
///   - `welcome-picker` - today's first screen (there is no welcome/choose screen yet - gap G-CHOICE).
///   - `permissions-none` / `permissions-partial` / `permissions-all` - B19's three rows.
///   - `progress-early` / `progress-mid` / `progress-failed` / `progress-done` - B7's list.
enum InstallerReworkRender {
    private static var failures = 0
    private static var hosts: [NSWindow] = []

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " - \(detail)")")
        if !ok { failures += 1 }
    }

    static func run(outDir: String) -> Bool {
        failures = 0
        hosts = []
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        do { try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[installer-rework-render] cannot create \(outDir): \(error)")
            return false
        }

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            app.appearance = NSAppearance(named: appearance)
            renderWelcome(outDir: outDir, suffix: suffix)
            renderPermissions(outDir: outDir, suffix: suffix)
            renderProgress(outDir: outDir, suffix: suffix)
        }

        print("[installer-rework-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    // MARK: - welcome / choose (today: the picker, directly - gap G-CHOICE)

    private static func renderWelcome(outDir: String, suffix: String) {
        let facts = ComponentPicker.MachineFacts(physicalBytes: 68_719_476_736, budgetBytes: 33_000_000_000,
                                                 maxBudgetBytes: 46_000_000_000, wiredBytes: 5_000_000_000)
        let view = ComponentPickerView(
            width: 620, selection: ComponentPicker.defaultSelection(facts: facts, environment: .init()),
            facts: facts, environment: .init())
        host(view)
        capture(view, to: outDir + "/welcome-picker-\(suffix).png",
               name: "welcome/choose (today: the picker directly) - \(suffix)")
    }

    // MARK: - permissions (B19)

    private static func renderPermissions(outDir: String, suffix: String) {
        let sampler = InstallerReworkRenderByteSampler()
        var state = InstallProgressState(plan: corePlan())
        let installing = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])
        sampler.package = (ComponentPicker.SizeCatalog.measured.transcriptionEngine ?? 0) * 2 / 3
        state.apply(snapshot: installing, sampler: sampler, at: 0)

        let none = PermissionsSetupView(width: 620, status: PermissionsStatus(),
                                        progressRows: state.rows, aggregate: state.aggregate)
        host(none)
        capture(none, to: outDir + "/permissions-none-\(suffix).png", name: "permissions, none granted - \(suffix)")

        none.apply(status: PermissionsStatus(microphone: true))
        capture(none, to: outDir + "/permissions-partial-\(suffix).png",
               name: "permissions, one granted - \(suffix)")

        none.apply(status: PermissionsStatus(microphone: true, accessibility: true, inputMonitoring: true))
        capture(none, to: outDir + "/permissions-all-\(suffix).png", name: "permissions, all granted - \(suffix)")
    }

    // MARK: - progress (B7)

    private static func renderProgress(outDir: String, suffix: String) {
        var state = InstallProgressState(plan: corePlan())
        let sampler = InstallerReworkRenderByteSampler()
        let installing = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])

        sampler.package = 96_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 0)
        let early = InstallProgressView(width: 620, style: .full)
        host(early)
        early.apply(state)
        capture(early, to: outDir + "/progress-early-\(suffix).png", name: "progress, early - \(suffix)")

        sampler.model = 620_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 1)
        let mid = InstallProgressView(width: 620, style: .full)
        host(mid)
        mid.apply(state)
        capture(mid, to: outDir + "/progress-mid-\(suffix).png", name: "progress, mid - \(suffix)")

        let vendorText = "Could not resolve huggingface.co (temporary failure in name resolution)"
        var failedState = InstallProgressState(plan: corePlan())
        failedState.apply(
            snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .failed],
                              failure: [BootstrapInstallPlan.sttDaemon.id: vendorText]),
            sampler: sampler, at: 2)
        let failed = InstallProgressView(width: 620, style: .full)
        host(failed)
        failed.apply(failedState)
        capture(failed, to: outDir + "/progress-failed-\(suffix).png", name: "progress, failed - \(suffix)")

        var doneState = InstallProgressState(plan: corePlan())
        doneState.apply(
            snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .installed,
                              BootstrapInstallPlan.webSearch.id: .installed]),
            sampler: sampler, at: 3)
        let done = InstallProgressView(width: 620, style: .full)
        host(done)
        done.apply(doneState)
        capture(done, to: outDir + "/progress-done-\(suffix).png", name: "progress, done - \(suffix)")
    }

    // MARK: - helpers (mirrors InstallProgressRender's small fixtures)

    private final class InstallerReworkRenderByteSampler: InstallByteSampling {
        var package: UInt64 = 0
        var model: UInt64 = 0
        func bytes(at source: InstallProgress.ByteSource) -> UInt64 {
            switch source {
            case .packageCache: return package
            case .modelCache: return model
            case .vendor: return 0
            }
        }
    }

    private static func snapshot(_ phases: [String: BootstrapComponentPhase],
                                 failure: [String: String] = [:]) -> BootstrapSnapshot {
        var state = BootstrapSnapshot.fresh()
        state.components = state.components.map { record in
            var record = record
            if let phase = phases[record.id] { record.phase = phase }
            record.failureMessage = failure[record.id]
            return record
        }
        return state
    }

    private static func corePlan() -> ComponentPicker.InstallPlan {
        ComponentPicker.InstallPlan(components: BootstrapInstallPlan.mandatoryCore, lmStudio: false, models: [])
    }

    private static func host(_ view: NSView) {
        // Captured on its own the view has neither its window backdrop nor a layer, which renders a
        // bezelled control's title onto transparency; same fix as every other render gate.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: max(200, view.frame.height)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView?.addSubview(view)
        hosts.append(window)
    }

    private static func capture(_ view: NSView, to path: String, name: String) {
        SelfTestRenderCapture.capture(view, card: nil, to: path, name: name) { n, ok, detail in
            check(n, ok, detail)
        }
    }
}
