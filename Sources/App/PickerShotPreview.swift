import Cocoa

/// `--shot-local-picker`: the two-popup app-first Local picker on screen for the UI-screenshot lane.
///
/// The flag is a plain launch flag handled by `CommandLine.arguments.contains` in `main.swift`, NOT a
/// `SelfTestManifestFlag`. It builds ONE window titled exactly `ViddyDictate Picker Preview` around the
/// real `ModelsPowerSettingsView` (the shipped Settings routing grid), fed an in-memory fixture catalog so
/// no provider detection, catalog fetch, network, engine/helper process, UserDefaults write, keychain
/// access, history read, or recording read happens. The window closes with the last window and the app
/// also exits by itself after `autoExitSeconds`.
enum PickerShotPreview {
    static let windowTitle = "ViddyDictate Picker Preview"
    static let autoExitSeconds: TimeInterval = 120

    /// The route the preview pins to an Ollama model. `LLMRouteID.email` is a non-cleanup route, so its
    /// Local picker is rendered inline by `addModelEffortControls` — the exact two-popup shape the lane is
    /// photographing — through the same `addLocalModelControls` path the shipped Settings window uses.
    static let pinnedRoute: LLMRouteID = .email

    static let lmsAlphaID = "shot-picker/lms-alpha-30b"
    static let lmsSharedID = "shot-picker/lms-shared-8b"
    static let ollamaCoderID = "shot-picker-ollama-coder:30b"
    static let ollamaSharedID = "shot-picker-ollama-shared-8b"

    static let lmsAlphaLabel = "Alpha 30B (18.56 GB)"
    static let lmsSharedLabel = "Shared 8B (4.92 GB)"
    static let ollamaCoderLabel = "shot-picker-ollama-coder:30b (19.00 GB)"
    static let ollamaSharedLabel = "shot-picker-ollama-shared-8b (5.20 GB)"

    /// LM Studio with two models and Ollama with two models: the fixed fixture the preview shows.
    static var fixtureCatalog: [LMStudioModelOption] {
        [
            LMStudioModelOption(modelID: lmsAlphaID, label: lmsAlphaLabel, sizeBytes: 18_560_000_000),
            LMStudioModelOption(modelID: lmsSharedID, label: lmsSharedLabel, sizeBytes: 4_920_000_000),
            LMStudioModelOption(modelID: ollamaCoderID, label: ollamaCoderLabel,
                                sizeBytes: 19_000_000_000, backend: .ollama),
            LMStudioModelOption(modelID: ollamaSharedID, label: ollamaSharedLabel,
                                sizeBytes: 5_200_000_000, backend: .ollama),
        ]
    }

    /// The one-app fixture: LM Studio only, pinned to an LM Studio model, so the preview is the flat
    /// pre-Ollama picker with one model popup and no app popup.
    static var lmStudioOnlyCatalog: [LMStudioModelOption] {
        [
            LMStudioModelOption(modelID: lmsAlphaID, label: lmsAlphaLabel, sizeBytes: 18_560_000_000),
            LMStudioModelOption(modelID: lmsSharedID, label: lmsSharedLabel, sizeBytes: 4_920_000_000),
        ]
    }

    static let pinnedRef = LocalModelRef(backend: .ollama, modelID: ollamaCoderID)
    static let pinnedBundle = LLMProviderBundle.local(ref: pinnedRef)
    static let lmStudioPin = LLMProviderBundle.local(lmsAlphaID)

    /// Build the preview window from a catalog + pin, using scratch stores under `scratchRoot`. The real
    /// `ModelsPowerSettingsView` is built with injected stores and an injected `localCatalogLoader`, then
    /// its production `refreshAvailableLocalModels()` path is driven (spinning the run loop until the
    /// injected catalog is in the picker), exactly as the shipped Settings window loads it.
    static func makePreviewWindow(catalog: [LMStudioModelOption], pinned: LLMProviderBundle,
                                  scratchRoot: URL, width: CGFloat = 640) -> NSWindow? {
        let fm = FileManager.default
        do { try fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true) }
        catch { return nil }

        let routing = ModelsPowerSettingsStore(
            url: scratchRoot.appendingPathComponent("models-power.json"),
            localCapacity: { _ in nil },
            preferredLocalBackend: { nil })
        let custom = CustomModeStore(url: scratchRoot.appendingPathComponent("custom-modes.json"),
                                     routingStore: routing)
        let skills = StickySkillStore(url: scratchRoot.appendingPathComponent("sticky-skills.json"))
        let outcome = CodexUpdateOutcomeStore(url: scratchRoot.appendingPathComponent("codex-outcome.json"))

        do { try routing.setSelectedBundle(pinned, for: pinnedRoute) }
        catch { return nil }

        let view = ModelsPowerSettingsView(
            width: width,
            settingsStore: routing,
            customStore: custom,
            stickySkillStore: skills,
            codexOutcomeStore: outcome,
            codexCatalogLoader: { nil },
            localCatalogLoader: { catalog })

        view.refreshAvailableLocalModels()
        waitForCatalog(view, catalog: catalog, pinned: pinned)
        disableCloudAutoCheck(in: view)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = windowTitle
        window.contentView = view
        window.isReleasedWhenClosed = false
        return window
    }

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PickerShotPreviewDelegate()
        app.delegate = delegate

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddydictate-picker-shot-\(UUID().uuidString)", isDirectory: true)
        guard let window = makePreviewWindow(catalog: fixtureCatalog, pinned: pinnedBundle,
                                             scratchRoot: root) else {
            FileHandle.standardError.write(
                Data("[viddydictate] --shot-local-picker: could not build the preview window\n".utf8))
            exit(1)
        }
        delegate.window = window
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        _ = Timer.scheduledTimer(withTimeInterval: autoExitSeconds, repeats: false) { _ in
            NSApplication.shared.terminate(nil)
        }

        app.run()
        exit(0)
    }

    // MARK: - catalog load

    /// Spin the run loop until the pinned app's rows from the injected catalog are in the model popup, so
    /// the window is already showing the fixture when the lane photographs it. Bounded: a view that never
    /// rebuilds fails the popup checks instead of hanging the process.
    private static func waitForCatalog(_ view: ModelsPowerSettingsView,
                                       catalog: [LMStudioModelOption],
                                       pinned: LLMProviderBundle) {
        let options = LocalModelPickerItems.routingGridOptions(catalog: catalog, pinned: pinned)
        guard let shown = LocalModelPickerItems.shownApp(options: options, selected: pinned.localRef) else {
            return
        }
        let wanted = Set(catalog.filter { $0.backend == shown }
            .map { LocalModelPickerItems.itemIdentifier(for: $0.ref) })
        let popupID = "model|\(pinnedRoute.rawValue)"
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let ids = findPopup(popupID, in: view)?.itemArray.compactMap { $0.identifier?.rawValue } ?? []
            if wanted.isSubset(of: Set(ids)) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private static func findPopup(_ id: String, in root: NSView) -> NSPopUpButton? {
        if root.identifier?.rawValue == id, let popup = root as? NSPopUpButton { return popup }
        for child in root.subviews {
            if let found = findPopup(id, in: child) { return found }
        }
        return nil
    }

    /// The real `ModelsPowerSettingsView` hosts the shipped `cloud-update-auto-check` checkbox, whose action
    /// writes `Settings.cloudUpdateAutoCheck` through `UserDefaults.standard`. A preview must never let a
    /// click change the user's real settings, so disable that one control after the view is built. The two
    /// picker popups (app and model) are deliberately left enabled and working against the scratch stores.
    private static func disableCloudAutoCheck(in root: NSView) {
        if root.identifier?.rawValue == "cloud-update-auto-check", let button = root as? NSButton {
            button.isEnabled = false
        }
        for child in root.subviews {
            disableCloudAutoCheck(in: child)
        }
    }
}

private final class PickerShotPreviewDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
