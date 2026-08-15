import Foundation

/// The ONE persistent store for user-defined custom modes (glossary "Custom mode"). App-local JSON
/// beside the app's other stores (`history.json`, `clipboard-history.json`, `dictionary.json`), so a
/// custom mode survives restarts and rebuilds without living in Swift. Injectable `url` so the headless
/// `--custommode-selftest` drives a scratch file and never touches the user's real modes.
///
/// Writes are synchronous atomic (the set is tiny and edited interactively), so a create/edit/delete is
/// on disk the instant it returns — the round-trip test can reopen a fresh store on the same path and
/// see the change with no race. Reads/mutations happen on the main thread (the Settings UI + the tap
/// dispatch, both main-thread), so no locking is needed.
final class CustomModeStore {
    static let shared = CustomModeStore()

    /// Posted after any create / edit / delete so the Hotkeys page + the live tap's chord snapshot refresh.
    static let didChange = Notification.Name("VDCustomModesDidChange")

    private(set) var modes: [CustomMode] = []
    private let url: URL
    private let routingStore: ModelsPowerSettingsStore?
    private let writer: (Data, URL) throws -> Void

    /// Default store: app-local JSON beside the other stores. Injectable `url` for selftests.
    init(url: URL? = nil, routingStore: ModelsPowerSettingsStore? = nil,
         writer: @escaping (Data, URL) throws -> Void = ModelsPowerSettingsStore.atomicWriter) {
        if let url = url {
            self.url = url
            self.routingStore = routingStore
        } else {
            let dir = AppPaths.ensureApplicationSupportDirectory()
            self.url = dir.appendingPathComponent("custom-modes.json")
            self.routingStore = routingStore ?? Settings.modelsPower
        }
        self.writer = writer
        load()
    }

    // MARK: persistence

    func load() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A fresh install still needs the backing prompt/route record for the shipped Sticky Skill.
            // Seed the exact adopted id. Never ask StickySkillStore to sync routes: this store already owns
            // the complete custom-mode selection set and is therefore the only safe pruning authority.
            modes = StickySkillRegistry.seedingBuiltInBackingModeIfMissing([])
            do { try writer(try encodedData(modes), url) }
            catch {
                UserDataWriteFailureCenter.report(
                    subsystem: "custom modes", operation: "seed", url: url, error: error)
            }
            syncRoutingRows()
            return
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            UserDataWriteFailureCenter.report(
                subsystem: "custom modes", operation: "load", url: url, error: error)
            return
        }
        let decoded: [CustomMode]
        do {
            decoded = try JSONDecoder().decode([CustomMode].self, from: data)
        } catch {
            UserDataWriteFailureCenter.report(
                subsystem: "custom modes", operation: "load", url: url, error: error)
            return
        }
        modes = StickySkillRegistry.seedingBuiltInBackingModeIfMissing(decoded)
        // A1 migration: legacy model `{kind:"cloud", id:...}` decodes as a typed Claude bundle. Rewrite the
        // whole tiny store canonically only when bytes differ; mode ids, chords, prompts, Local choices,
        // Claude model ids, input, and landing all come from the decoded values unchanged.
        do {
            let canonical = try encodedData(modes)
            if canonical != data { try writer(canonical, url) }
        } catch {
            UserDataWriteFailureCenter.report(
                subsystem: "custom modes", operation: "migrate", url: url, error: error)
        }
        syncRoutingRows()
    }

    private func persist(_ candidate: [CustomMode], operation: String) throws {
        do {
            try writer(try encodedData(candidate), url)
        } catch {
            UserDataWriteFailureCenter.report(
                subsystem: "custom modes", operation: operation, url: url, error: error)
            throw error
        }
    }

    private func encodedData(_ value: [CustomMode]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(value)
    }

    private func syncRoutingRows() {
        guard let routingStore = routingStore else { return }
        var selections: [LLMRouteID: LLMProviderBundle] = [:]
        for mode in modes { selections[mode.routeID] = mode.model }
        do { try routingStore.syncCustomRoutes(selections) }
        catch { Log.write("custom modes: routing sync failed (already surfaced)") }
    }

    // MARK: CRUD

    /// Create a new mode or replace the existing one with the same id. Persists + notifies.
    func upsert(_ mode: CustomMode) throws {
        var candidate = modes
        if let i = candidate.firstIndex(where: { $0.id == mode.id }) {
            candidate[i] = mode
        } else {
            candidate.append(mode)
        }
        try persist(candidate, operation: "save")
        modes = candidate
        syncRoutingRows()
        notify()
    }

    /// Delete a mode by id. No-op if absent. Persists + notifies.
    func delete(id: String) throws {
        var candidate = modes
        let before = candidate.count
        candidate.removeAll { $0.id == id }
        guard candidate.count != before else { return }
        try persist(candidate, operation: "delete")
        modes = candidate
        syncRoutingRows()
        notify()
    }

    func mode(id: String) -> CustomMode? { modes.first { $0.id == id } }

    // MARK: chord resolution (the live tap + the controller dispatch)

    /// The custom mode bound to a regular keycode (the keyDown chord path). nil when none.
    func mode(forKeyCode keyCode: Int64) -> CustomMode? {
        modes.first { !$0.chord.isModifier && $0.chord.code == keyCode }
    }

    /// The custom mode bound to a modifier mask (the flagsChanged chord path). nil when none.
    func mode(forModifierMask mask: Int64) -> CustomMode? {
        modes.first { $0.chord.isModifier && $0.chord.code == mask }
    }

    /// The chord snapshot the live tap matches against (id + spec), refreshed on every change. Only
    /// dispatchable modes (bound chord + non-blank prompt) are included, so a half-built row is inert.
    func chordSnapshot(stickySkills: [StickySkill] = StickySkillStore.shared.skills)
        -> [(id: String, spec: KeySpec)] {
        StickySkillRegistry.hotkeyVisibleModes(modes, skills: stickySkills)
            .compactMap { $0.isDispatchable ? (id: $0.id, spec: $0.chord) : nil }
    }

    private func notify() {
        NotificationCenter.default.post(name: CustomModeStore.didChange, object: nil)
    }

    static func newId() -> String { UUID().uuidString }
}
