import Foundation

/// The pure decision model behind the Settings "Speech" page (selectable Whisper versions, part 2 of 3).
///
/// It turns (catalog, active repo, installed set, in-flight install state, free disk bytes) into rows,
/// and owns the three actions with every effect injected. No AppKit: the view only renders rows and
/// forwards one action per row; every behaviour is tested on this type with recorded/no-op effects.
final class WhisperPickerModel {
    enum RowState: Equatable {
        case active
        case installed
        case notInstalled
        case installing
        case failed(String)
    }

    enum RowAction: Equatable {
        case none, useThis, install
    }

    struct Row: Equatable {
        let repo: String
        let name: String
        let sizeText: String
        let state: RowState
        let isDefault: Bool
        let action: RowAction
    }

    enum InstallOutcome: Equatable {
        case succeeded
        case failed(InstallerFailure)
    }

    struct Effects {
        var installed: (String) -> Bool
        var freeDiskBytes: () -> Int64
        var write: (String) throws -> Void
        var restart: () -> Void
        var select: (String, @escaping (WhisperModelSwitch.Result) -> Void) -> Void
        var runInstall: (String, @escaping (InstallOutcome) -> Void) -> Void
    }

    let catalog: [WhisperModelCatalog.Variant]
    var activeRepo: String
    var installed: Set<String>
    var installRepo: String?
    var failedRepo: String?
    var failedReason: String?
    var status: String?
    var freeDiskBytes: Int64
    var effects: Effects
    /// Called on the main thread whenever an asynchronous state change needs a re-render.
    var onUpdate: (() -> Void)?

    static let installMarginBytes: Int64 = 300_000_000
    static let restartingStatus = "Restarting the speech engine, this takes a few seconds"
    static let installingStatus = "This can take several minutes"

    /// The single source of row state text, shared by the model's pure rows and the view, so the
    /// pure arm can assert exactly what the view renders.
    static func stateText(_ state: RowState) -> String {
        switch state {
        case .active: return "Active"
        case .installed: return "Installed"
        case .notInstalled: return "Not installed"
        case .installing: return "Installing..."
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    init(catalog: [WhisperModelCatalog.Variant] = WhisperModelCatalog.variants,
         activeRepo: String = Settings.whisperModelRepo,
         installed: Set<String> = [],
         freeDiskBytes: Int64 = WhisperPickerModel.availableDiskBytes(),
         effects: Effects = .production()) {
        self.catalog = catalog
        self.activeRepo = activeRepo
        self.installed = installed
        self.freeDiskBytes = freeDiskBytes
        self.effects = effects
    }

    // Row precedence: active repo -> installing -> failed -> installed -> not installed.
    var rows: [Row] {
        catalog.map { variant in
            let state: RowState
            let action: RowAction
            if variant.repo == activeRepo {
                state = .active; action = .none
            } else if installRepo == variant.repo {
                state = .installing; action = .none
            } else if failedRepo == variant.repo {
                state = .failed(failedReason ?? "The install failed."); action = .install
            } else if installed.contains(variant.repo) {
                state = .installed; action = .useThis
            } else {
                state = .notInstalled; action = .install
            }
            return Row(repo: variant.repo, name: variant.displayName,
                       sizeText: Self.sizeText(variant.approximateSizeBytes),
                       state: state,
                       isDefault: variant.repo == WhisperModelCatalog.default.repo,
                       action: action)
        }
    }

    var notice: String? { installRepo != nil ? Self.installingStatus : status }

    func perform(_ action: RowAction, repo: String) {
        switch action {
        case .none: break
        case .useThis: useThis(repo: repo)
        case .install: install(repo: repo)
        }
    }

    func useThis(repo: String) {
        status = Self.restartingStatus
        effects.select(repo) { [weak self] result in
            guard let self else { return }
            switch result {
            case .switched:
                self.activeRepo = repo
                self.installed.insert(repo)
                self.status = nil
            case .notOffered, .notInstalled, .failed:
                self.status = Self.useStatus(result)
            }
            self.onUpdate?()
        }
    }

    func install(repo: String) {
        guard let variant = WhisperModelCatalog.variant(forRepo: repo) else {
            status = Self.useStatus(.notOffered)
            onUpdate?()
            return
        }
        if let message = Self.insufficientFreeSpaceMessage(for: variant, freeDiskBytes: freeDiskBytes) {
            status = message
            onUpdate?()
            return
        }
        installRepo = repo
        failedRepo = nil
        failedReason = nil
        status = nil
        effects.runInstall(repo) { [weak self] outcome in
            self?.handleInstallOutcome(outcome)
        }
        onUpdate?()
    }

    func handleInstallOutcome(_ outcome: InstallOutcome) {
        switch outcome {
        case .succeeded:
            if let repo = installRepo { installed.insert(repo) }
            installRepo = nil; failedRepo = nil; failedReason = nil
        case .failed(let failure):
            failedRepo = installRepo
            failedReason = Self.installFailureText(failure)
            installRepo = nil
        }
        onUpdate?()
    }

    static func sizeText(_ bytes: Int64) -> String {
        String(format: "about %.1f GB", Double(bytes) / 1_000_000_000)
    }

    static func insufficientFreeSpaceMessage(for variant: WhisperModelCatalog.Variant,
                                             freeDiskBytes: Int64,
                                             marginBytes: Int64 = installMarginBytes) -> String? {
        guard freeDiskBytes < variant.approximateSizeBytes + marginBytes else { return nil }
        return "Not enough free space: needs \(sizeText(variant.approximateSizeBytes))"
    }

    // Fixed app-authored categories ONLY — never any vendor/Hugging Face response body text.
    static func installFailureText(_ failure: InstallerFailure) -> String {
        switch failure.category {
        case .invalidPlan: return "This model cannot be installed."
        case .process: return "The install did not finish."
        case .transport: return "The download could not be completed."
        case .server: return "The download server returned an error."
        case .client: return "The download was refused."
        case .checksumMismatch: return "The download did not verify."
        }
    }

    static func useStatus(_ result: WhisperModelSwitch.Result) -> String {
        switch result {
        case .switched: return restartingStatus
        case .notOffered: return "That model is not offered by this build."
        case .notInstalled: return "That model is not installed."
        case .failed: return "The switch could not be saved."
        }
    }

    static func availableDiskBytes(for url: URL = AppPaths.applicationSupportDirectory()) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

extension WhisperPickerModel.Effects {
    // Production wiring: reuses WhisperModelSwitch.select(repo:)'s exact real effects, and reuses the
    // existing InstallerEngine for a single repo by building a descriptor with the daemon's own "stt-venv"
    // (whose python already has huggingface_hub). NO new download code path.
    static func production() -> WhisperPickerModel.Effects {
        WhisperPickerModel.Effects(
            installed: { WhisperModelStore.isInstalled(repo: $0) },
            freeDiskBytes: { WhisperPickerModel.availableDiskBytes() },
            write: { try WhisperModelStore.writeChoice(repo: $0) },
            restart: { _ = WhisperdAgentLoader.forCurrentUser().loadAndStart(restartIfLoaded: true) },
            select: { repo, completion in
                DispatchQueue.global(qos: .utility).async {
                    let result = WhisperModelSwitch.select(repo: repo)
                    DispatchQueue.main.async { completion(result) }
                }
            },
            runInstall: { repo, completion in
                guard let variant = WhisperModelCatalog.variant(forRepo: repo) else {
                    completion(.failed(InstallerFailure(category: .invalidPlan, message: "unknown repository")))
                    return
                }
                let descriptor = InstallerComponentDescriptor(
                    id: "whisper-model:\(variant.id)",
                    title: variant.displayName,
                    detail: "The \(variant.displayName) speech model",
                    virtualEnvironmentRelativePath: "stt-venv",
                    modelArtifacts: [InstallerModelArtifact(repository: repo)])
                let engine = InstallerEngine()
                DispatchQueue.global(qos: .utility).async {
                    let result = engine.install(descriptor)
                    DispatchQueue.main.async {
                        switch result.state {
                        case .installed: completion(.succeeded)
                        case .failed(let failure, _): completion(.failed(failure))
                        }
                    }
                }
            })
    }
}
