import Foundation

enum StickySkillStoreError: Error, Equatable {
    /// The shipped built-in is not deletable (locked decision 5). Refused in the store rather than only in
    /// the UI, so no future caller can delete it by taking a different path to the same data.
    case builtInIsNotDeletable(id: String)
}

/// The ONE persistent store for Sticky Skills. App-local JSON beside the app's other stores
/// (`custom-modes.json`, `history.json`, `dictionary.json`), so a skill survives restarts and rebuilds
/// without living in Swift. Modeled on `CustomModeStore`, including its injectable `url`/`writer` seam so
/// the headless selftest drives a scratch file and never touches the user's real data.
///
/// Writes are synchronous atomic (the set is tiny and edited interactively), so a create/edit/delete is on
/// disk the instant it returns. Reads/mutations happen on the main thread (the Settings UI plus the note
/// tab-menu dispatch, both main-thread), so no locking is needed.
///
/// IT DELIBERATELY DOES NOT SYNC ROUTING ROWS, and that is the single most important difference from
/// `CustomModeStore`. `ModelsPowerSettingsStore.syncCustomRoutes` PRUNES every `custom:` route whose id is
/// absent from the selections it is handed (ModelsPowerSettings.swift, the `!active.contains(raw)` loop).
/// A second store calling it with only its own ids would therefore delete the custom modes' route rows -
/// including the ratified bundle behind the adopted Note to Handoff row. Route ownership stays with
/// `CustomModeStore`, and a skill reaches its route through its backing mode (`StickySkill.routeID`).
final class StickySkillStore {
    static let shared = StickySkillStore()

    /// Posted after any create / edit / delete so the Settings tab and the note tab-menu projection refresh.
    static let didChange = Notification.Name("VDStickySkillsDidChange")

    private(set) var skills: [StickySkill] = []
    private let url: URL
    private let writer: (Data, URL) throws -> Void

    /// Default store: app-local JSON beside the other stores. Injectable `url` for selftests.
    init(url: URL? = nil,
         writer: @escaping (Data, URL) throws -> Void = ModelsPowerSettingsStore.atomicWriter) {
        if let url = url {
            self.url = url
        } else {
            self.url = AppPaths.ensureApplicationSupportDirectory()
                .appendingPathComponent("sticky-skills.json")
        }
        self.writer = writer
        load()
    }

    // MARK: persistence

    func load() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // First run: seed the built-in and write it, so the shipped skill is a visible, editable row
            // from the start rather than an invisible compiled-in special case.
            skills = StickySkillRegistry.canonicalized([])
            do { try writer(try encodedData(skills), url) }
            catch {
                UserDataWriteFailureCenter.report(
                    subsystem: "sticky skills", operation: "seed", url: url, error: error)
            }
            return
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            // Keep the built-in usable in memory, but never write over a file we could not read.
            skills = StickySkillRegistry.canonicalized([])
            UserDataWriteFailureCenter.report(
                subsystem: "sticky skills", operation: "load", url: url, error: error)
            return
        }
        let decoded: [StickySkill]
        do {
            decoded = try JSONDecoder().decode([StickySkill].self, from: data)
        } catch {
            // Same rule: a file we cannot parse is not a file we are entitled to overwrite. The user still
            // gets a working Note to Handoff, and the unparseable bytes stay on disk for recovery.
            skills = StickySkillRegistry.canonicalized([])
            UserDataWriteFailureCenter.report(
                subsystem: "sticky skills", operation: "load", url: url, error: error)
            return
        }
        // Silent canonicalization, following the precedent already in `CustomModeStore.load()`: rewrite the
        // whole tiny store only when the bytes actually differ. This is where a hand-edited or re-keyed
        // built-in row is repaired back onto the adopted custom mode.
        skills = StickySkillRegistry.canonicalized(decoded)
        do {
            let canonical = try encodedData(skills)
            if canonical != data { try writer(canonical, url) }
        } catch {
            UserDataWriteFailureCenter.report(
                subsystem: "sticky skills", operation: "migrate", url: url, error: error)
        }
    }

    private func persist(_ candidate: [StickySkill], operation: String) throws {
        do {
            try writer(try encodedData(candidate), url)
        } catch {
            UserDataWriteFailureCenter.report(
                subsystem: "sticky skills", operation: operation, url: url, error: error)
            throw error
        }
    }

    private func encodedData(_ value: [StickySkill]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(value)
    }

    // MARK: CRUD

    /// Create a new skill or replace the existing one with the same id. Persists + notifies. The candidate
    /// is canonicalized first, so an upsert can never re-key the built-in or drop it out of the list.
    func upsert(_ skill: StickySkill) throws {
        var candidate = skills
        if let i = candidate.firstIndex(where: { $0.id == skill.id }) {
            candidate[i] = skill
        } else {
            candidate.append(skill)
        }
        candidate = StickySkillRegistry.canonicalized(candidate)
        try persist(candidate, operation: "save")
        skills = candidate
        notify()
    }

    /// Delete a skill by id. No-op if absent; THROWS for the built-in. Persists + notifies.
    func delete(id: String) throws {
        guard id != StickySkillRegistry.builtInSkillID else {
            throw StickySkillStoreError.builtInIsNotDeletable(id: id)
        }
        var candidate = skills
        let before = candidate.count
        candidate.removeAll { $0.id == id }
        guard candidate.count != before else { return }
        try persist(candidate, operation: "delete")
        skills = candidate
        notify()
    }

    func skill(id: String) -> StickySkill? { skills.first { $0.id == id } }

    /// The custom mode this skill's prompt and route live on. The registry lookup that replaced the
    /// hardcoded `NoteToHandoffPrompt.customModeID`.
    func customModeID(forSkill id: String) -> String? {
        StickySkillRegistry.customModeID(forSkill: id, in: skills)
    }

    private func notify() {
        NotificationCenter.default.post(name: StickySkillStore.didChange, object: nil)
    }

    static func newId() -> String { UUID().uuidString }
}
