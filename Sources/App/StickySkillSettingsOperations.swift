import Foundation

enum StickySkillSettingsError: Error, Equatable, LocalizedError {
    case blankName
    case missingSkill(String)
    case missingBackingMode(String)

    var errorDescription: String? {
        switch self {
        case .blankName:
            return "A sticky skill needs a name."
        case .missingSkill(let id):
            return "Sticky skill \(id) no longer exists."
        case .missingBackingMode(let id):
            return "Sticky skill \(id) has no task prompt or route record."
        }
    }
}

/// The persistence gestures behind the Sticky Skills Settings tab.
///
/// A user-created skill spans TWO stores by design: `StickySkillStore` owns its name/output/timeout, while
/// `CustomModeStore` owns its task prompt and `custom:` route. These helpers keep the ordering and rollback
/// in one production seam so the AppKit actions cannot each invent a different half-created state.
enum StickySkillSettingsOperations {
    static let newSkillName = "New sticky skill"

    @discardableResult
    static func add(skillStore: StickySkillStore, modeStore: CustomModeStore) throws -> StickySkill {
        let id = StickySkillStore.newId()
        var skill = StickySkill.blank(id: id)
        skill.name = newSkillName
        var mode = CustomMode.blank(id: id)
        mode.name = newSkillName

        // Mode first: its upsert creates the route row. If the skill write fails, delete the just-created
        // mode again so no implementation-only row leaks onto Hotkeys or survives as an orphan.
        try modeStore.upsert(mode)
        do {
            try skillStore.upsert(skill)
        } catch {
            try? modeStore.delete(id: id)
            throw error
        }
        return skill
    }

    static func rename(id: String, to rawName: String,
                       skillStore: StickySkillStore, modeStore: CustomModeStore) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StickySkillSettingsError.blankName }
        guard let original = skillStore.skill(id: id) else {
            throw StickySkillSettingsError.missingSkill(id)
        }
        var candidate = original
        candidate.name = name
        try skillStore.upsert(candidate)

        // The adopted built-in's backing mode is ALSO the live hotkey row. Its existing name is part of
        // that independent surface and the LANDMINE says to adopt it in place, never rewrite it. A user
        // skill's private backing mode may follow the skill name because it is hidden from Hotkeys.
        guard !candidate.isBuiltIn else { return }
        guard var mode = modeStore.mode(id: candidate.customModeID) else {
            try? skillStore.upsert(original)
            throw StickySkillSettingsError.missingBackingMode(candidate.customModeID)
        }
        mode.name = name
        do { try modeStore.upsert(mode) }
        catch {
            try? skillStore.upsert(original)
            throw error
        }
    }

    static func setOutputMode(id: String, outputMode: StickySkillOutputMode,
                              skillStore: StickySkillStore) throws {
        guard var skill = skillStore.skill(id: id) else {
            throw StickySkillSettingsError.missingSkill(id)
        }
        skill.outputMode = outputMode
        try skillStore.upsert(skill)
    }

    static func setTaskPrompt(id: String, prompt: String,
                              skillStore: StickySkillStore, modeStore: CustomModeStore) throws {
        guard let skill = skillStore.skill(id: id) else {
            throw StickySkillSettingsError.missingSkill(id)
        }
        guard var mode = modeStore.mode(id: skill.customModeID) else {
            throw StickySkillSettingsError.missingBackingMode(skill.customModeID)
        }
        mode.prompt = prompt
        try modeStore.upsert(mode)
    }

    static func remove(id: String,
                       skillStore: StickySkillStore, modeStore: CustomModeStore) throws {
        guard let skill = skillStore.skill(id: id) else { return }
        // Store-level refusal remains the authority for the built-in; do not duplicate it here.
        try skillStore.delete(id: id)

        // Only a one-to-one user backing row belongs to this deletion. A hand-edited skill that points at
        // some other mode does not confer ownership of that other mode.
        guard !skill.isBuiltIn, skill.id == skill.customModeID,
              modeStore.mode(id: skill.customModeID) != nil else { return }
        do { try modeStore.delete(id: skill.customModeID) }
        catch {
            try? skillStore.upsert(skill)
            throw error
        }
    }
}
