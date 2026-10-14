import Cocoa

/// Offscreen render + pure-model gate for the Settings "Speech" tab (`--whisper-speech-selftest`).
///
/// The pure half runs ALWAYS and constructs no AppKit: it drives `WhisperPickerModel` with injected
/// recorded/no-op effects over TMPDIR scratch files, so a pi sandbox that aborts on AppKit (exit 134)
/// never reaches it. The AppKit render half runs only when `VD_RENDER_OUT` is a non-empty directory,
/// which the lane's replay link does natively; verify.sh's deterministic tier runs the pure half only.
///
/// Five fixture states are photographed (default active light; two installed + one installing
/// with the plain Installing... line; a failed install; not enough disk space; default active dark),
/// each asserted non-blank by pixel metric, re-read from disk as a valid image, and the light/dark
/// pair asserted to differ.
enum WhisperSpeechTabRender {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    static func run() -> Bool {
        print("=== ViddyDictate Whisper Speech Settings tab — selftest ===")
        runPureChecks()
        let outDir = ProcessInfo.processInfo.environment["VD_RENDER_OUT"].flatMap {
            $0.isEmpty ? nil : $0
        }
        if let outDir {
            runRender(outDir: outDir)
        }
        print("[whisper-speech-selftest] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")"
            + (outDir.map { " -> \($0)" } ?? ""))
        return failures == 0
    }

    // MARK: - pure checks (no AppKit)

    private static func runPureChecks() {
        let turbo = WhisperModelCatalog.`default`.repo
        let v2 = "mlx-community/whisper-large-v2-mlx"
        let v3 = "mlx-community/whisper-large-v3-mlx"

        // ── row states ────────────────────────────────────────────────────────────────
        let defaultModel = WhisperPickerModel(
            catalog: WhisperModelCatalog.variants, activeRepo: turbo, installed: [turbo],
            freeDiskBytes: 1_000_000_000_000, effects: baseEffects())
        let defaultRows = defaultModel.rows
        let turboRow = defaultRows.first { $0.repo == turbo }
        let otherRows = defaultRows.filter { $0.repo != turbo }
        check("whisper-ui: new: the default active state marks the active variant Active with no action and every other variant Not installed with Install",
              turboRow?.state == .active
                && turboRow?.action == WhisperPickerModel.RowAction.none
                && !otherRows.isEmpty
                && otherRows.allSatisfy { $0.state == .notInstalled && $0.action == .install })

        let installing = WhisperPickerModel(
            catalog: WhisperModelCatalog.variants, activeRepo: turbo, installed: [turbo, v3],
            freeDiskBytes: 1_000_000_000_000, effects: baseEffects())
        installing.installRepo = v2
        let installingRows = installing.rows
        let installingRow = installingRows.first { $0.repo == v2 }
        let installingText = installingRow.map { WhisperPickerModel.stateText($0.state) == "Installing..." } ?? false
        check("whisper-ui: new: installing row is Installing... with no percent",
              installingRow?.state == .installing && installingText,
              "state=\(String(describing: installingRow?.state)) text=\(installingRow.map { WhisperPickerModel.stateText($0.state) } ?? "nil")")
        check("whisper-ui: new: installing row offers no action",
              installingRow?.action == WhisperPickerModel.RowAction.none,
              "action=\(String(describing: installingRow?.action))")

        let failed = WhisperPickerModel(
            catalog: WhisperModelCatalog.variants, activeRepo: turbo, installed: [turbo],
            freeDiskBytes: 1_000_000_000_000, effects: baseEffects())
        failed.failedRepo = v2
        failed.failedReason = "The download could not be completed."
        let failedRows = failed.rows
        check("whisper-ui: new: a failed install shows Failed: <reason> and offers Install to retry",
              failedRows.first { $0.repo == v2 }?.state == .failed("The download could not be completed.")
                && failedRows.first { $0.repo == v2 }?.action == .install)

        // ── short disk ───────────────────────────────────────────────────────────────
        var installCalls: [String] = []
        var shortEffects = baseEffects()
        shortEffects.runInstall = { repo, _ in installCalls.append(repo) }
        let short = WhisperPickerModel(
            catalog: WhisperModelCatalog.variants, activeRepo: turbo, installed: [turbo],
            freeDiskBytes: 0, effects: shortEffects)
        short.install(repo: v3)
        check("whisper-ui: new: short free disk refuses install with the plain sentence naming the size",
              short.status == "Not enough free space: needs about 3.1 GB"
                && short.installRepo == nil && installCalls.isEmpty)

        var noticeEffects = baseEffects()
        noticeEffects.runInstall = { repo, _ in installCalls.append(repo) }
        let noticeModel = WhisperPickerModel(
            catalog: WhisperModelCatalog.variants, activeRepo: turbo, installed: [turbo],
            freeDiskBytes: 1_000_000_000_000, effects: noticeEffects)
        noticeModel.install(repo: v3)
        check("whisper-ui: new: card shows This can take several minutes while installing",
              noticeModel.notice == "This can take several minutes",
              "notice=\(String(describing: noticeModel.notice)) installRepo=\(String(describing: noticeModel.installRepo))")

        // ── Use this: the injected select effect owns the switch (M1) ────────────────
        Settings.whisperModelRepo = turbo
        var selectCalls: [String] = []
        var restarts = 0
        var useEffects = baseEffects()
        useEffects.select = { repo, completion in
            selectCalls.append(repo)
            restarts += 1
            completion(.switched)
        }
        let useModel = WhisperPickerModel(
            catalog: WhisperModelCatalog.variants, activeRepo: turbo, installed: [turbo],
            freeDiskBytes: 1_000_000_000_000, effects: useEffects)
        useModel.useThis(repo: v2)
        check("whisper-ui: new: Use this calls the injected select effect once and restarts once",
              useModel.activeRepo == v2 && selectCalls == [v2] && restarts == 1,
              "active=\(useModel.activeRepo) selectCalls=\(selectCalls) restarts=\(restarts)")

        var pendingCompletion: ((WhisperModelSwitch.Result) -> Void)?
        var gateEffects = baseEffects()
        gateEffects.select = { _, completion in pendingCompletion = completion }
        let gateModel = WhisperPickerModel(
            catalog: WhisperModelCatalog.variants, activeRepo: turbo, installed: [turbo],
            freeDiskBytes: 1_000_000_000_000, effects: gateEffects)
        gateModel.useThis(repo: v2)
        let pendingOK = gateModel.status == WhisperPickerModel.restartingStatus
            && gateModel.activeRepo == turbo
        pendingCompletion?(.switched)
        let settledOK = gateModel.activeRepo == v2 && gateModel.status == nil
        check("whisper-ui: new: Use this shows the restart status while the select runs, then the new active row with no status",
              pendingOK && settledOK,
              "pending=\(pendingOK) active=\(gateModel.activeRepo) status=\(String(describing: gateModel.status))")

        let pickerSource = source("Sources/App/WhisperPickerModel.swift")
        check("whisper-ui: new: the production select effect is the one-argument WhisperModelSwitch.select(repo:) call",
              pickerSource.contains("WhisperModelSwitch.select(repo: repo)"),
              "one-arg call present=\(pickerSource.contains("WhisperModelSwitch.select(repo: repo)"))")

        let engineSource = source("Sources/App/InstallerEngine.swift")
        check("whisper-ui: new: InstallerEngine untouched",
              !engineSource.contains("cancelled")
                && !engineSource.contains("activeProcess")
                && !engineSource.contains("func cancel")
                && !engineSource.contains("checkCancelled"),
              "cancelled=\(engineSource.contains("cancelled")) activeProcess=\(engineSource.contains("activeProcess")) funcCancel=\(engineSource.contains("func cancel")) checkCancelled=\(engineSource.contains("checkCancelled"))")

        // ── active row / not-installed row action ─────────────────────────────────────
        check("whisper-ui: new: the active row offers no action",
              defaultRows.first { $0.repo == turbo }?.action == WhisperPickerModel.RowAction.none)
        check("whisper-ui: new: a not-installed repo offers Install, never Use this",
              defaultRows.first { $0.repo == v2 }?.action == .install)

        // ── install/cancel never touch the active choice ──────────────────────────────
        let finished = WhisperPickerModel(
            catalog: WhisperModelCatalog.variants, activeRepo: turbo, installed: [turbo],
            freeDiskBytes: 1_000_000_000_000, effects: baseEffects())
        finished.installRepo = v3
        finished.handleInstallOutcome(.succeeded)
        check("whisper-ui: new: a finished install does not change the active repo",
              finished.activeRepo == turbo && finished.installed.contains(v3)
                && finished.rows.first { $0.repo == turbo }?.state == .active)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-speech-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let choiceURL = scratch.appendingPathComponent("whisper-model")

        // S2: observe the choice-file EFFECT, not just the active repo.
        var s2Effects = baseEffects()
        s2Effects.select = { repo, completion in
            try? WhisperModelStore.writeChoice(repo: repo, to: choiceURL)
            completion(.switched)
        }
        let failedInstall = WhisperPickerModel(
            catalog: WhisperModelCatalog.variants, activeRepo: turbo, installed: [turbo],
            freeDiskBytes: 1_000_000_000_000, effects: s2Effects)
        failedInstall.useThis(repo: v2)
        let choiceAfterSwitch = (try? String(contentsOf: choiceURL, encoding: .utf8)) ?? ""
        failedInstall.installRepo = v3
        failedInstall.handleInstallOutcome(
            .failed(InstallerFailure(category: .transport, message: "MARKER_PROVIDER_BODY")))
        let choiceAfterFail = (try? String(contentsOf: choiceURL, encoding: .utf8)) ?? ""
        check("whisper-ui: new: a failed install leaves the choice file (written via the injected select effect) untouched",
              failedInstall.activeRepo == v2
                && choiceAfterSwitch == v2 + "\n"
                && choiceAfterFail == v2 + "\n"
                && !(failedInstall.failedReason ?? "").contains("MARKER_PROVIDER_BODY"),
              "active=\(failedInstall.activeRepo) afterSwitch=\(choiceAfterSwitch.debugDescription) afterFail=\(choiceAfterFail.debugDescription)")

        // M3 guard: a partial snapshot never reads as Installed.
        let partialCache = scratch.appendingPathComponent("partial-cache", isDirectory: true)
        makePartialSnapshot(cache: partialCache, repo: v3)
        check("whisper-ui: guard: a partial snapshot never reads as Installed",
              !WhisperModelStore.isInstalled(repo: v3, cacheDirectories: [partialCache]))

        // ── failure text is fixed app-authored category text ─────────────────────────
        let failureText = WhisperPickerModel.installFailureText(
            InstallerFailure(category: .transport, message: "MARKER_PROVIDER_BODY"))
        check("whisper-ui: new: install failure text never contains a provider response body marker",
              !failureText.contains("MARKER_PROVIDER_BODY") && !failureText.contains("body"),
              failureText)

        // ── guards ────────────────────────────────────────────────────────────────────
        let tabNames = SettingsTab.allCases.map(\.rawValue)
        let audioIndex = tabNames.firstIndex(of: "Audio")
        let speechIndex = tabNames.firstIndex(of: "Speech")
        check("whisper-ui: new: Speech tab right after Audio",
              audioIndex != nil && speechIndex == audioIndex.map { $0 + 1 },
              "tabs=\(tabNames)")
        let withoutSpeech = SettingsTab.allCases.filter { $0.rawValue != "Speech" }.map(\.rawValue)
        check("whisper-ui: guard: the other Settings tabs keep their order",
              withoutSpeech == ["Setup", "Hotkeys", "Sticky Skills", "Audio", "Appearance",
                                "Dictionary", "History", "Notes"])

        let whisperModelSource = source("Sources/SelfTest/WhisperModelSelfTest.swift")
        check("whisper-ui: guard: the existing whisper-model-selftest rows are unchanged",
              whisperModelSource.contains(
                "whisper-model: new: catalog offers exactly the four variants in the required order")
                && whisperModelSource.contains(
                    "whisper-model: new: select writes the file, changes the setting, and restarts once")
                && whisperModelSource.contains(
                    "whisper-model: guard: no stored value reads as the default turbo repo"))
    }

    // MARK: - render (only under VD_RENDER_OUT)

    private static func runRender(outDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)

        let fm = FileManager.default
        do { try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            check("render output directory", false, "cannot create \(outDir): \(error)")
            return
        }

        let turbo = WhisperModelCatalog.`default`.repo
        let v2 = "mlx-community/whisper-large-v2-mlx"
        let v3 = "mlx-community/whisper-large-v3-mlx"
        let model = WhisperPickerModel(
            catalog: WhisperModelCatalog.variants, activeRepo: turbo, installed: [turbo],
            freeDiskBytes: 1_000_000_000_000, effects: baseEffects())
        let view = WhisperSpeechSettingsView(width: 640, model: model)

        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: max(360, view.frame.height)),
            styleMask: [.borderless], backing: .buffered, defer: false)
        host.appearance = NSAppearance(named: .aqua)
        host.contentView?.addSubview(view)

        // 1. default active, light
        let lightRep = capture(view, to: outDir + "/whisper-speech-default-active-light.png",
                               name: "default active light")

        // 2. two installed, one installing (Installing..., no percent)
        model.installed = [turbo, v3]
        model.installRepo = v2
        view.render()
        capture(view, to: outDir + "/whisper-speech-two-installed-one-installing.png",
                name: "two installed one installing")

        // 3. a failed install
        model.installRepo = nil
        model.failedRepo = v2
        model.failedReason = "The download could not be completed."
        view.render()
        capture(view, to: outDir + "/whisper-speech-failed-install.png", name: "failed install")

        // 4. not enough disk space
        model.installed = [turbo]
        model.failedRepo = nil
        model.failedReason = nil
        model.freeDiskBytes = 0
        model.install(repo: v3)
        view.render()
        capture(view, to: outDir + "/whisper-speech-not-enough-space.png", name: "not enough space")

        // 5. default active, dark
        model.installed = [turbo]
        model.installRepo = nil
        model.failedRepo = nil
        model.failedReason = nil
        model.freeDiskBytes = 1_000_000_000_000
        model.status = nil
        host.appearance = NSAppearance(named: .darkAqua)
        view.render()
        let darkRep = capture(view, to: outDir + "/whisper-speech-default-active-dark.png",
                              name: "default active dark")

        // M4 pixel rows: page background luminance + header text contrast in both appearances.
        let headerField = SelfTestRenderCapture.allViews(in: view)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "WHISPER MODEL" }
        let headerRectInView = headerField.map {
            $0.convert(SelfTestRenderCapture.textRect(of: $0), to: view)
        }
        if let darkRep, let darkPixels = SelfTestRenderCapture.Pixels(darkRep, of: view) {
            let bg = darkPixels.rgb(x: 8, y: 1)
            let bgLum = SelfTestRenderCapture.luminance(bg)
            let headerContrast = headerRectInView.flatMap { darkPixels.textContrast(in: $0, of: view) } ?? 1
            check("whisper-ui: new: dark page background is dark and the header text contrast is at least 4.5",
                  bgLum < 0.35 && headerContrast >= 4.5,
                  "bgLum=\(String(format: "%.3f", bgLum)) headerContrast=\(String(format: "%.2f", headerContrast))")
        } else {
            check("whisper-ui: new: dark page background is dark and the header text contrast is at least 4.5",
                  false, "no dark capture pixels")
        }
        if let lightRep, let lightPixels = SelfTestRenderCapture.Pixels(lightRep, of: view) {
            let bg = lightPixels.rgb(x: 8, y: 1)
            let bgLum = SelfTestRenderCapture.luminance(bg)
            let headerContrast = headerRectInView.flatMap { lightPixels.textContrast(in: $0, of: view) } ?? 1
            check("whisper-ui: new: light page background is light and the header text contrast is at least 4.5",
                  bgLum > 0.65 && headerContrast >= 4.5,
                  "bgLum=\(String(format: "%.3f", bgLum)) headerContrast=\(String(format: "%.2f", headerContrast))")
        } else {
            check("whisper-ui: new: light page background is light and the header text contrast is at least 4.5",
                  false, "no light capture pixels")
        }

        // M3 footer rows: the footer line must be readable in both appearances too.
        let footerField = SelfTestRenderCapture.label("whisper-speech-footer", in: view)
        let footerRectInView = footerField.map {
            $0.convert(SelfTestRenderCapture.textRect(of: $0), to: view)
        }
        if let darkRep, let darkPixels = SelfTestRenderCapture.Pixels(darkRep, of: view) {
            let footerContrast = footerRectInView.flatMap { darkPixels.textContrast(in: $0, of: view) } ?? 1
            check("whisper-ui: new: footer readable dark",
                  footerContrast >= 4.5,
                  "footerContrast=\(String(format: "%.2f", footerContrast))")
        } else {
            check("whisper-ui: new: footer readable dark", false, "no dark capture pixels")
        }
        if let lightRep, let lightPixels = SelfTestRenderCapture.Pixels(lightRep, of: view) {
            let footerContrast = footerRectInView.flatMap { lightPixels.textContrast(in: $0, of: view) } ?? 1
            check("whisper-ui: new: footer readable light",
                  footerContrast >= 4.5,
                  "footerContrast=\(String(format: "%.2f", footerContrast))")
        } else {
            check("whisper-ui: new: footer readable light", false, "no light capture pixels")
        }

        // Every capture must exist on disk, decode as an image, and be non-empty; the light/dark pair
        // must be genuinely different pixels.
        let files = ["whisper-speech-default-active-light.png",
                     "whisper-speech-two-installed-one-installing.png",
                     "whisper-speech-failed-install.png",
                     "whisper-speech-not-enough-space.png",
                     "whisper-speech-default-active-dark.png"]
        var bytes: [Data?] = []
        for file in files {
            let data = fileBytes(outDir + "/" + file)
            let ok = data != nil && !(data!.isEmpty) && NSBitmapImageRep(data: data!) != nil
            check("\(file) exists, is non-empty, and reads back as an image", ok,
                  "\(data?.count ?? 0) bytes")
            bytes.append(data)
        }
        check("the light and dark default captures differ",
              bytes[0] != nil && bytes[4] != nil && bytes[0] != bytes[4])
        var pairwiseDistinct = false
        for i in bytes.indices {
            for j in bytes.indices where j > i {
                if bytes[i] != nil && bytes[j] != nil && bytes[i] != bytes[j] { pairwiseDistinct = true }
            }
        }
        check("at least two captures differ pairwise", pairwiseDistinct)
    }

    // MARK: - helpers

    private static func baseEffects() -> WhisperPickerModel.Effects {
        WhisperPickerModel.Effects(
            installed: { _ in false },
            freeDiskBytes: { 1_000_000_000_000 },
            write: { _ in },
            restart: {},
            select: { _, completion in completion(.notOffered) },
            runInstall: { _, _ in })
    }

    private static func capture(_ view: NSView, to path: String, name: String) -> NSBitmapImageRep? {
        applyBackdrop(to: view)
        return SelfTestRenderCapture.capture(view, card: nil, to: path, name: name) { n, ok, detail in
            check(n, ok, detail)
        }
    }

    private static func applyBackdrop(to view: NSView) {
        view.wantsLayer = true
        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private static func makePartialSnapshot(cache: URL, repo: String) {
        let folder = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let repoDir = cache.appendingPathComponent(folder, isDirectory: true)
        let snapshot = repoDir.appendingPathComponent("snapshots/abc123", isDirectory: true)
        try? FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: repoDir.appendingPathComponent("refs", isDirectory: true), withIntermediateDirectories: true)
        try? "abc123\n".write(to: repoDir.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        try? Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        // weights intentionally missing -> incomplete snapshot
    }

    private static func fileBytes(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func source(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
