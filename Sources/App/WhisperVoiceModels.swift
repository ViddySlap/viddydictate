import Foundation

enum WhisperVoiceModels {
    static let turboRepo = WhisperModelCatalog.default.repo

    struct State: Equatable {
        var ticked: Set<String>
        var active: String

        static let defaultState = State(
            ticked: [WhisperModelCatalog.default.repo],
            active: WhisperModelCatalog.default.repo)

        init(ticked: Set<String> = [WhisperModelCatalog.default.repo],
             active: String = WhisperModelCatalog.default.repo) {
            self.ticked = ticked
            self.active = active
            normalize()
        }

        private static func firstTicked(in order: [String], among set: Set<String>) -> String? {
            order.first { set.contains($0) }
        }

        private mutating func normalize() {
            if ticked.isEmpty { ticked = [WhisperModelCatalog.default.repo] }
            if !ticked.contains(active) {
                active = Self.firstTicked(in: WhisperModelCatalog.variants.map(\.repo), among: ticked)
                    ?? WhisperModelCatalog.default.repo
            }
        }

        // unticking the active variant moves active to the first remaining ticked one
        // (in catalog order), OR is refused when it is the only ticked one.
        // Returns false exactly when the change was refused (selection unchanged).
        @discardableResult
        mutating func setTicked(_ repo: String, _ on: Bool) -> Bool {
            if on {
                ticked.insert(repo)
                normalize()
                return true
            }
            if repo == active {
                let remaining = ticked.subtracting([repo])
                guard let next = Self.firstTicked(in: WhisperModelCatalog.variants.map(\.repo),
                                                  among: remaining) else { return false }
                active = next
            }
            ticked.remove(repo)
            normalize()
            return true
        }

        @discardableResult
        mutating func setActive(_ repo: String) -> Bool {
            guard ticked.contains(repo) else { return false }
            active = repo
            return true
        }
    }

    struct Row: Equatable {
        let repo: String
        let name: String
        let sizeBytes: UInt64
        let ticked: Bool
        let active: Bool
        let installed: Bool
    }

    static func rows(state: State, installed: (String) -> Bool) -> [Row] {
        WhisperModelCatalog.variants.map { v in
            Row(repo: v.repo, name: v.displayName,
                sizeBytes: UInt64(v.approximateSizeBytes),
                ticked: state.ticked.contains(v.repo),
                active: state.active == v.repo,
                installed: installed(v.repo))
        }
    }

    // The group's extra download bytes: every TICKED variant that is NOT already
    // installed AND is NOT the default turbo repo (the mandatory core already charges
    // Turbo's measured size), summed by catalog approximateSizeBytes.
    static func extraDownloadBytes(state: State, installed: (String) -> Bool) -> UInt64 {
        WhisperModelCatalog.variants.reduce(0) { sum, v in
            guard state.ticked.contains(v.repo),
                  v.repo != WhisperModelCatalog.default.repo,
                  !installed(v.repo) else { return sum }
            return sum + UInt64(v.approximateSizeBytes)
        }
    }

    // Extra model-download descriptors, in catalog order, built EXACTLY the way
    // WhisperPickerModel.Effects.production().runInstall builds one: id "whisper-model:<variant.id>",
    // virtualEnvironmentRelativePath "stt-venv", modelArtifacts [InstallerModelArtifact(repository: repo)].
    // The ACTIVE non-default variant's descriptor carries writeWhisperChoiceOnSuccess == its repo.
    //
    // The ACTIVE non-default repo always produces a descriptor. When it still needs its download, that
    // is the download descriptor as before. When it is already installed, it produces an empty
    // descriptor - no packages, no model artifacts, no local steps, no virtual-environment path and
    // downloadBytes 0 - whose only job is the choice write. Installed NON-active variants are skipped,
    // so an installed repo still adds zero bytes to the totals.
    static func descriptors(state: State, installed: (String) -> Bool) -> [InstallerComponentDescriptor] {
        WhisperModelCatalog.variants.compactMap { v in
            guard state.ticked.contains(v.repo),
                  v.repo != WhisperModelCatalog.default.repo else { return nil }
            let isActive = state.active == v.repo
            if installed(v.repo) {
                guard isActive else { return nil }
                return InstallerComponentDescriptor(
                    id: "whisper-model:\(v.id)",
                    title: v.displayName,
                    detail: "The \(v.displayName) speech model",
                    downloadBytes: 0,
                    writeWhisperChoiceOnSuccess: v.repo)
            }
            return InstallerComponentDescriptor(
                id: "whisper-model:\(v.id)",
                title: v.displayName,
                detail: "The \(v.displayName) speech model",
                virtualEnvironmentRelativePath: "stt-venv",
                modelArtifacts: [InstallerModelArtifact(repository: v.repo)],
                downloadBytes: v.approximateSizeBytes,
                writeWhisperChoiceOnSuccess: isActive ? v.repo : nil)
        }
    }
}
