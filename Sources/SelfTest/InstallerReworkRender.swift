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
///   - `welcome-choose` - the first screen (welcome/choose, in front of the picker).
///   - `permissions-none` / `permissions-partial` / `permissions-all` - B19's three rows.
///   - `progress-early` / `progress-mid` / `progress-failed` / `progress-done` - B7's list.
///   - `ready-ok` / `ready-degraded` / `ready-relaunch` - the final screen (gap G-READY).
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
            let forced = NSAppearance(named: appearance)!
            app.appearance = forced
            // Force every dynamic NSColor resolved during this pass's render+capture (window background,
            // label colour, button bezels, ...) to use this pass's own appearance. Otherwise cacheDisplay
            // draws under whatever appearance happened to be ambient, which is effectively always light,
            // so the *-dark.png files came out identical to the light ones.
            forced.performAsCurrentDrawingAppearance {
                renderWelcome(outDir: outDir, suffix: suffix)
                renderPermissions(outDir: outDir, suffix: suffix)
                renderPermissionsRelaunch(outDir: outDir, suffix: suffix)
                renderProgress(outDir: outDir, suffix: suffix)
                renderReady(outDir: outDir, suffix: suffix)
            }
        }

        print("[installer-rework-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    // MARK: - welcome / choose

    private static func renderWelcome(outDir: String, suffix: String) {
        let view = WelcomeChooseView(width: 620)
        host(view)
        capture(view, to: outDir + "/welcome-choose-\(suffix).png",
               name: "welcome/choose - \(suffix)")
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

    // MARK: - permissions relaunch (spec item 5)

    private static func renderPermissionsRelaunch(outDir: String, suffix: String) {
        let sampler = InstallerReworkRenderByteSampler()
        sampler.package = (ComponentPicker.SizeCatalog.measured.transcriptionEngine ?? 0) * 2 / 3
        let granted = PermissionsStatus(microphone: true, accessibility: true, inputMonitoring: true)

        // Waiting: the install queue is still running, so the Relaunch button renders disabled with the
        // "becomes available when setup finishes" caption.
        var installingState = InstallProgressState(plan: corePlan())
        let installing = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])
        installingState.apply(snapshot: installing, sampler: sampler, at: 0)
        let waiting = PermissionsSetupView(width: 620, status: granted,
                                           progressRows: installingState.rows,
                                           aggregate: installingState.aggregate)
        host(waiting)
        waiting.apply(status: granted, relaunchOffer: true)
        capture(waiting, to: outDir + "/permissions-relaunch-waiting-\(suffix).png",
                name: "permissions, relaunch offered while installing - \(suffix)")

        // Enabled: every component installed, so aggregate.anyRunning is false and the button is live.
        var doneState = InstallProgressState(plan: corePlan())
        doneState.apply(
            snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .installed,
                              BootstrapInstallPlan.webSearch.id: .installed]),
            sampler: sampler, at: 1)
        let enabled = PermissionsSetupView(width: 620, status: granted,
                                           progressRows: doneState.rows,
                                           aggregate: doneState.aggregate)
        host(enabled)
        enabled.apply(status: granted, relaunchOffer: true)
        capture(enabled, to: outDir + "/permissions-relaunch-\(suffix).png",
                name: "permissions, relaunch offered and enabled - \(suffix)")
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

    // MARK: - ready (gap G-READY)

    private static func renderReady(outDir: String, suffix: String) {
        let sampler = InstallerReworkRenderByteSampler()
        let granted = PermissionsStatus(microphone: true, accessibility: true, inputMonitoring: true)

        var okState = InstallProgressState(plan: corePlan())
        okState.apply(
            snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .installed,
                              BootstrapInstallPlan.webSearch.id: .installed]),
            sampler: sampler, at: 0)
        let ok = ReadyStepView(width: 620, rows: okState.rows, permissions: granted, practice: .ready,
                              offerRelaunch: false)
        host(ok)
        capture(ok, to: outDir + "/ready-ok-\(suffix).png", name: "ready, ok - \(suffix)")

        let vendorText = "Could not resolve huggingface.co (temporary failure in name resolution)"
        var degradedState = InstallProgressState(plan: corePlan())
        degradedState.apply(
            snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .failed,
                              BootstrapInstallPlan.webSearch.id: .installed],
                              failure: [BootstrapInstallPlan.sttDaemon.id: vendorText]),
            sampler: sampler, at: 1)
        let degraded = ReadyStepView(width: 620, rows: degradedState.rows,
                                     permissions: PermissionsStatus(microphone: true), practice: .grantFirst,
                                     offerRelaunch: false)
        host(degraded)
        capture(degraded, to: outDir + "/ready-degraded-\(suffix).png", name: "ready, degraded - \(suffix)")

        var relaunchState = InstallProgressState(plan: corePlan())
        relaunchState.apply(
            snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .installed,
                              BootstrapInstallPlan.webSearch.id: .installed]),
            sampler: sampler, at: 2)
        let relaunch = ReadyStepView(width: 620, rows: relaunchState.rows, permissions: granted,
                                     practice: .relaunchNeeded, offerRelaunch: true)
        host(relaunch)
        capture(relaunch, to: outDir + "/ready-relaunch-\(suffix).png", name: "ready, relaunch - \(suffix)")
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: max(200, view.frame.height)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView?.addSubview(view)
        // Read the dynamic window-background colour only after the view has a window, so it has an
        // appearance context. Combined with run(outDir:)'s performAsCurrentDrawingAppearance block this
        // resolves to the pass's own appearance instead of ambient light.
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        hosts.append(window)
    }

    private static func capture(_ view: NSView, to path: String, name: String) {
        SelfTestRenderCapture.capture(view, card: nil, to: path, name: name) { n, ok, detail in
            check(n, ok, detail)
        }
    }
}
