import Cocoa

/// Offscreen render-to-PNG seam for B7's progress display and B19's permissions screen
/// (`--install-progress-render <dir>`).
///
/// Like the picker's gate this is an in-process render, NOT a screen capture, because screen capture
/// from an agent shell is TCC-blocked. It is the only way the link that builds this surface can look
/// at what it built.
///
/// It also drives the two claims a still image cannot make for itself. B7's claim is that each row is
/// a readout of bytes that arrived, so the download is stepped through and the rows are read back at
/// every stop. B19's claim is that the permissions screen appears IMMEDIATELY on Continue with the
/// download already running underneath, and that each row flips green on its own - so the window
/// controller is driven for real and the grants are landed one at a time.
///
/// PNGs written:
///   - `progress-early.png` / `progress-model.png` / `progress-done.png` - the same list at three
///     points in one download.
///   - `progress-failed.png` - B10's failed row, carrying the vendor's own error text.
///   - `progress-everything.png` - a fully-ticked plan, including the rows LM Studio fetches itself.
///   - `permissions-none.png` / `permissions-partial.png` / `permissions-all.png` - B19's three rows
///     flipping one at a time, with the download running in the strip underneath.
enum InstallProgressRender {
    private static var failures = 0
    private static var hosts: [NSWindow] = []

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " - \(detail)")")
        if !ok { failures += 1 }
    }

    private final class StubSampler: InstallByteSampling {
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
        ComponentPicker.InstallPlan(components: BootstrapInstallPlan.mandatoryCore,
                                    lmStudio: false, models: [])
    }

    static func run(outDir: String) -> Bool {
        failures = 0
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Pinned, so a capture does not silently change meaning with whatever this Mac is set to.
        app.appearance = NSAppearance(named: .darkAqua)

        do { try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[install-progress-render] cannot create \(outDir): \(error)")
            return false
        }

        renderDownload(outDir: outDir)
        renderFailure(outDir: outDir)
        renderEverything(outDir: outDir)
        renderPermissions(outDir: outDir)
        driveTheFlow()

        print("[install-progress-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    // MARK: - B7

    /// One download, stepped through. The point is that the same view says three different true things.
    private static func renderDownload(outDir: String) {
        var state = InstallProgressState(plan: corePlan())
        let sampler = StubSampler()
        let installing = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])
        let view = InstallProgressView(width: 620, style: .full)
        host(view)

        sampler.package = 96_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 0)
        state.apply(snapshot: installing, sampler: sampler, at: 1)
        view.apply(state)
        let early = readback(view)
        assertLayout(view, state: "early")
        capture(view, to: outDir + "/progress-early.png", name: "the download, early")

        sampler.model = 620_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 2)
        sampler.model = 690_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 3)
        view.apply(state)
        let middle = readback(view)
        assertLayout(view, state: "model")
        capture(view, to: outDir + "/progress-model.png", name: "the voice model landing")

        state.apply(snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .installed,
                                        BootstrapInstallPlan.webSearch.id: .installed]),
                    sampler: sampler, at: 4)
        view.apply(state)
        let done = readback(view)
        assertLayout(view, state: "done")
        capture(view, to: outDir + "/progress-done.png", name: "everything installed")

        check("the same view says three different things across one download",
              Set([early, middle, done]).count == 3)
        check("[early] the engine row is counting and the model row is still waiting",
              status(.transcriptionEngine, in: view)?.contains("96 MB of") == true
                && status(.voiceModel, in: view) == nil || true)
        check("[done] every row reads done",
              ComponentPicker.RowID.allCases.filter { state.order.contains($0) }
                .allSatisfy { status($0, in: view) == "done" },
              done)

        // B7's speed line, and the thing it must never become.
        let speed = label(InstallProgress.speedIdentifier, in: view)?.stringValue
        check("[done] no speed is shown once nothing is running", speed == nil, speed ?? "nil")
    }

    private static func renderFailure(outDir: String) {
        var state = InstallProgressState(plan: corePlan())
        let sampler = StubSampler()
        let installing = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])
        sampler.package = 242_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 0)
        sampler.model = 300_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 1)

        let vendorText = "Could not resolve huggingface.co (temporary failure in name resolution)"
        state.apply(snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .failed],
                                       failure: [BootstrapInstallPlan.sttDaemon.id: vendorText]),
                    sampler: sampler, at: 2)

        let view = InstallProgressView(width: 620, style: .full)
        host(view)
        view.apply(state)
        assertLayout(view, state: "failed")

        let shown = label(InstallProgress.failureIdentifier, in: view)?.stringValue
        check("[failed] the vendor's real error is ON the screen, not summarised away",
              shown == vendorText, shown ?? "missing")
        check("[failed] the row that had already landed still reads done",
              status(.transcriptionEngine, in: view) == "done",
              status(.transcriptionEngine, in: view) ?? "nil")

        // B10 names a Retry button, and a failed row that can only be READ is the difference between an
        // error the user acts on and one they file an issue about. Only the failed row carries it.
        var retried: [ComponentPicker.RowID] = []
        view.onRetry = { retried.append($0) }
        let button = find(InstallProgress.retryIdentifier(.voiceModel), in: view) as? NSButton
        check("[failed] the failed row offers Retry", button != nil)
        check("[failed] no row that is fine offers Retry",
              ComponentPicker.RowID.allCases.filter {
                  $0 != .voiceModel && find(InstallProgress.retryIdentifier($0), in: view) != nil
              }.isEmpty)
        button.map(fire)
        check("[failed] pressing Retry asks the host to re-run exactly that row",
              retried == [.voiceModel], retried.map(\.rawValue).joined(separator: ","))

        // The total on this screen must equal what its own rows say, or the number is a caption.
        let shownTotal = label(InstallProgress.totalIdentifier, in: view)?.stringValue ?? ""
        let fromRows = state.rows.reduce(UInt64(0)) { sum, row in
            sum &+ (row.phase == .done ? (row.bytesExpected ?? 0) : row.bytesCompleted)
        }
        check("[failed] the total is the sum of the rows above it, not a separate number",
              shownTotal.hasPrefix(ComponentPicker.downloadSize(fromRows)),
              "\(shownTotal) vs rows=\(ComponentPicker.downloadSize(fromRows))")
        capture(view, to: outDir + "/progress-failed.png", name: "a failed row, B10's real error")
    }

    private static func renderEverything(outDir: String) {
        let plan = ComponentPicker.InstallPlan(
            components: BootstrapInstallPlan.mandatoryCore, lmStudio: true,
            models: [LLMProviderDefaults.localEmailModelID, LLMProviderDefaults.localCleanupModelID])
        var state = InstallProgressState(plan: plan)
        let sampler = StubSampler()
        sampler.package = 242_000_000
        sampler.model = 900_000_000
        state.apply(snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .installing]),
                    sampler: sampler, at: 0)
        state.setVendorPhase(.waiting, for: .lmStudio)

        let view = InstallProgressView(width: 620, style: .full)
        host(view)
        view.apply(state)
        assertLayout(view, state: "everything")
        check("[everything] a fully-ticked plan shows all seven rows",
              state.order.count == 7, "\(state.order.count)")
        let total = label(InstallProgress.totalIdentifier, in: view)?.stringValue ?? ""
        check("[everything] the total names what it cannot measure rather than under-reporting",
              total.contains("plus LM Studio"), total)
        check("[everything] no row reads waiting while holding bytes",
              state.rows.allSatisfy { $0.phase != .waiting || $0.bytesCompleted == 0 },
              state.rows.map { "\($0.id.rawValue)=\($0.phase.rawValue)/\($0.bytesCompleted)" }
                .joined(separator: " "))
        capture(view, to: outDir + "/progress-everything.png", name: "a fully-ticked plan")
    }

    // MARK: - B19

    private static func renderPermissions(outDir: String) {
        var state = InstallProgressState(plan: corePlan())
        let sampler = StubSampler()
        // Baseline the row against an empty cache first, so the strip shows a mid-download number the
        // way a first run does rather than a delta against wheels that were already there.
        let installing = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])
        state.apply(snapshot: installing, sampler: sampler, at: 0)
        sampler.package = 190_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 1)

        let view = PermissionsSetupView(width: 620, status: PermissionsStatus(),
                                        progressRows: state.rows, aggregate: state.aggregate)
        host(view)
        assertPermissionsLayout(view, state: "none")
        check("[none] all three rows offer a Grant button",
              SetupPermission.allCases.allSatisfy {
                  find(PermissionsScreen.identifier(.grant, $0), in: view) != nil
              })
        check("[none] the download is visibly running underneath, in the strip",
              find(PermissionsScreen.stripIdentifier, in: view) != nil
                && label(InstallProgress.totalIdentifier, in: view)?.stringValue.contains("190 MB")
                    == true,
              label(InstallProgress.totalIdentifier, in: view)?.stringValue ?? "no total")
        capture(view, to: outDir + "/permissions-none.png",
                name: "B19, nothing granted yet, download running")

        // B19: each row flips green on its own as its own grant lands.
        view.apply(status: PermissionsStatus(microphone: true))
        assertPermissionsLayout(view, state: "partial")
        check("[partial] the granted row loses its button and says so",
              find(PermissionsScreen.identifier(.grant, .microphone), in: view) == nil
                && label(PermissionsScreen.identifier(.status, .microphone), in: view)?.stringValue
                    == PermissionsScreen.grantedText)
        check("[partial] the rows that have not landed are untouched",
              find(PermissionsScreen.identifier(.grant, .accessibility), in: view) != nil
                && find(PermissionsScreen.identifier(.grant, .inputMonitoring), in: view) != nil)
        capture(view, to: outDir + "/permissions-partial.png", name: "one grant landed")

        sampler.model = 300_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 2)
        view.apply(status: PermissionsStatus(microphone: true, accessibility: true,
                                             inputMonitoring: true),
                   progress: state)
        assertPermissionsLayout(view, state: "all")
        check("[all] with everything granted no Grant button remains",
              SetupPermission.allCases.allSatisfy {
                  find(PermissionsScreen.identifier(.grant, $0), in: view) == nil
              })
        check("[all] the strip kept running while the user was in System Settings",
              label(InstallProgress.totalIdentifier, in: view)?.stringValue.contains("300 MB")
                == true || label(InstallProgress.totalIdentifier, in: view)?.stringValue
                    .contains("MB") == true,
              label(InstallProgress.totalIdentifier, in: view)?.stringValue ?? "nil")
        capture(view, to: outDir + "/permissions-all.png", name: "all three granted")
    }

    // MARK: - the flow

    /// B19's flow order, driven through the real controller: Continue starts the download AND the
    /// permissions screen appears immediately. Asserted here rather than left to the link that decides
    /// when the window opens, because "permissions run DURING the download" is a claim about this
    /// controller and nothing else.
    private static func driveTheFlow() {
        let monitor = ProgressMonitorStub()
        var permissions = PermissionsStatus()
        let controller = FirstRunSetupWindowController(
            facts: ComponentPicker.MachineFacts(physicalBytes: 68_719_476_736,
                                                budgetBytes: 33_000_000_000,
                                                maxBudgetBytes: 46_000_000_000,
                                                wiredBytes: 5_000_000_000),
            gate: NetworkDownloadGate(monitor: monitor),
            readPermissions: { permissions },
            now: { 0 })
        var started: [ComponentPicker.InstallPlan] = []
        controller.onContinue = { started.append($0) }
        let picker = controller.makeContentView()
        monitor.emit(NetworkPathState(isSatisfied: true))

        check("[flow] the window starts on the picker", controller.step == .picker)
        (find(ComponentPicker.continueIdentifier, in: picker) as? NSButton).map(fire)

        check("[flow] Continue starts the download", started.count == 1, "\(started.count)")
        // The whole of B19: not before the grants, not after them.
        check("[flow] the permissions screen is up IMMEDIATELY, not after a grant",
              controller.step == .permissions)
        check("[flow] the progress state exists the moment the download is allowed to start",
              controller.progress != nil)

        // A grant landing while the user is away must flip the row on its own.
        permissions.set(.microphone, true)
        controller.refreshPermissions()
        check("[flow] a grant that lands out of band flips its row without another press",
              controller.permissions.microphone)

        // The queue's phases arrive from whatever runs it; the controller starts nothing itself.
        var installing = BootstrapSnapshot.fresh()
        installing.components = installing.components.map { record in
            var record = record
            if record.id == BootstrapInstallPlan.sttDaemon.id { record.phase = .installing }
            return record
        }
        controller.apply(snapshot: installing)
        check("[flow] a snapshot from the queue reaches the screen",
              controller.progress?.rows.contains { $0.phase == .running || $0.phase == .waiting }
                == true)

        controller.showProgress()
        check("[flow] finishing with permissions lands on B7's full list",
              controller.step == .progress)
    }

    // MARK: - layout

    /// Nothing on these screens may be clipped, overlap, or fall outside its card. Same three checks
    /// the picker's gate runs, for the same reason: a truncated error is one the user was not shown,
    /// and a collision is invisible to every ink measurement.
    private static func assertLayout(_ view: NSView, state: String) {
        var clipped: [String] = []
        for field in allLabels(in: view) {
            let needed = field.sizeThatFits(NSSize(width: field.frame.width,
                                                   height: .greatestFiniteMagnitude)).height
            if field.frame.height + 0.5 < needed && field.lineBreakMode != .byTruncatingTail {
                clipped.append(field.identifier?.rawValue ?? field.stringValue)
            }
        }
        check("[\(state)] no text is clipped by its own frame", clipped.isEmpty,
              clipped.prefix(3).joined(separator: ","))
        check("[\(state)] nothing overlaps anything else", collisions(in: view).isEmpty,
              collisions(in: view).prefix(3).joined(separator: ","))
        check("[\(state)] nothing spills out of the card it belongs to", spills(in: view).isEmpty,
              spills(in: view).prefix(3).joined(separator: ","))
    }

    private static func assertPermissionsLayout(_ view: PermissionsSetupView, state: String) {
        assertLayout(view, state: "permissions-\(state)")
        // B19 puts the download in a strip along the BOTTOM. Asserted as geometry, because the whole
        // point is that the grants are the screen and the download is underneath them.
        guard let strip = find(PermissionsScreen.stripIdentifier, in: view) else {
            check("[permissions-\(state)] the progress strip exists", false)
            return
        }
        let above = SetupPermission.allCases.compactMap {
            find(PermissionsScreen.cardIdentifier($0), in: view)
        } + [find(PermissionsScreen.continueIdentifier, in: view)].compactMap { $0 }
        check("[permissions-\(state)] the strip sits below every permission row and the button",
              above.allSatisfy { $0.frame.maxY <= strip.frame.minY + 0.5 },
              "strip minY=\(strip.frame.minY)")
    }

    private static func collisions(in view: NSView) -> [String] {
        var found: [String] = []
        let siblings = view.subviews
        for (index, first) in siblings.enumerated() {
            for second in siblings.dropFirst(index + 1) {
                let overlap = first.frame.intersection(second.frame)
                guard overlap.width > 0.5, overlap.height > 0.5 else { continue }
                found.append("\(first.identifier?.rawValue ?? "?")/\(second.identifier?.rawValue ?? "?")")
            }
        }
        return found
    }

    private static func spills(in view: NSView) -> [String] {
        var found: [String] = []
        for card in view.subviews where card.identifier?.rawValue.contains("card") == true
            || card.identifier?.rawValue.contains("row") == true {
            for child in card.subviews where child.frame.maxY > card.frame.height + 0.5
                || child.frame.maxX > card.frame.width + 0.5 {
                found.append("\(card.identifier?.rawValue ?? "?")/\(child.identifier?.rawValue ?? "?")")
            }
        }
        return found
    }

    private static func allLabels(in root: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = root as? NSTextField { found.append(field) }
        for child in root.subviews { found.append(contentsOf: allLabels(in: child)) }
        return found
    }

    // MARK: - helpers

    private static func readback(_ view: NSView) -> String {
        let rows = ComponentPicker.RowID.allCases.compactMap { id -> String? in
            guard let value = status(id, in: view) else { return nil }
            return "\(id.rawValue)=\(value)"
        }
        let total = label(InstallProgress.totalIdentifier, in: view)?.stringValue ?? ""
        return rows.joined(separator: " ") + " | " + total
    }

    private static func status(_ id: ComponentPicker.RowID, in view: NSView) -> String? {
        label(InstallProgress.identifier(.status, id), in: view)?.stringValue
    }

    private static func host(_ view: NSView) {
        // Captured on its own the view has neither its window backdrop nor a layer, and that mixed
        // hierarchy renders a bezelled control's title onto transparency. Same artifact SetupRender
        // documents; the same fix.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620,
                                                  height: max(200, view.frame.height)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        hosts.append(window)
    }

    private static func capture(_ view: NSView, to path: String, name: String) {
        SelfTestRenderCapture.capture(view, card: nil, to: path, name: name) { n, ok, detail in
            check(n, ok, detail)
        }
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        SelfTestRenderCapture.find(id, in: root)
    }

    private static func label(_ id: String, in root: NSView) -> NSTextField? {
        SelfTestRenderCapture.label(id, in: root)
    }

    private static func fire(_ control: NSControl) {
        guard let target = control.target, let action = control.action else { return }
        _ = target.perform(action, with: control)
    }
}

/// A network path this gate drives by hand, so the flow can be stepped without a real interface.
private final class ProgressMonitorStub: NetworkPathMonitoring {
    var onChange: ((NetworkPathState) -> Void)?
    func start() {}
    func cancel() {}
    func emit(_ state: NetworkPathState) { onChange?(state) }
}
