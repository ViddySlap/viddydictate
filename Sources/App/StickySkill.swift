import Foundation

/// A Sticky Skill: a repeatable, user-authored job run over a WHOLE sticky note (title, body and
/// attachments). Note to Handoff is the first one.
///
/// This descriptor is deliberately PARALLEL to `CustomMode`, not merged into it. A custom mode is a
/// hotkey-namespace citizen: it owns a chord, an input taxonomy (dictation / selection / both), and a
/// landing, and it is listed on the Hotkeys page. A sticky skill has none of those - its input is always
/// the whole note, it is invoked from the note's tab menu rather than a chord, and it lands through the
/// typed output slot below. Adding those fields to `CustomMode` would also have broken every existing
/// user's `custom-modes.json`, because `CustomMode` has synthesized Codable and a non-optional new field
/// fails decoding outright.
///
/// WHAT A SKILL OWNS vs WHAT IT POINTS AT
/// --------------------------------------
/// A skill owns its identity, its display name, its output mode, and its request ceiling. Its TASK PROMPT
/// and its LLM ROUTE are owned by the `CustomMode` named by `customModeID`. That indirection is not
/// incidental - it is how the shipped built-in ADOPTS the user's existing custom-mode row in place (see
/// `StickySkillRegistry`), and it is why a skill's route lives in the `custom:` route namespace that
/// `ModelsPowerSettingsStore.syncCustomRoutes` already keeps alive. A skill that minted its own route id
/// outside that namespace would have its route row pruned the next time `CustomModeStore` loaded.
struct StickySkill: Codable, Equatable {
    /// Stable skill identity (a UUID string). Never the display name.
    var id: String
    /// The skill's human noun: the tab-menu item, the Settings row title, the failure toast subject.
    var name: String
    /// The `CustomMode` that owns this skill's task prompt and LLM route. For the shipped built-in this is
    /// the user's already-ratified row and MUST NOT be re-keyed; `StickySkillRegistry.canonicalized` enforces it.
    var customModeID: String
    /// Where this skill's result lands. The typed slot; S2 pairs each case with its handler.
    var outputMode: StickySkillOutputMode
    /// This skill's own request ceiling, per provider class. Whole-note jobs are an order of magnitude
    /// bigger than a dictation cleanup, so the budget belongs to the caller (see `CustomModeTimeoutBudget`).
    var timeout: CustomModeTimeoutBudget

    /// The shipped built-in cannot be deleted (locked decision 5). Derived from the id rather than stored,
    /// so a hand-edited `sticky-skills.json` can neither make a user skill undeletable nor make the
    /// built-in deletable.
    var isBuiltIn: Bool { id == StickySkillRegistry.builtInSkillID }

    /// The route this skill actually runs on. It is the BACKING MODE's route, not a route of its own -
    /// one line, so "the skill inherits the adopted row's ratified bundle" is impossible to misread.
    var routeID: LLMRouteID { .custom(customModeID) }

    /// The whole-note default ceiling, measured in chain 1 on a 12.4 KB note: local runs peaked at 42.4 s
    /// under contention, cloud at 85.5 s, so each side is roughly 2x its slowest observed run. Still hard
    /// ceilings - a wedged run fails, it does not hang.
    static let wholeNoteDefaultTimeout = CustomModeTimeoutBudget(local: 90, cloud: 180)

    init(id: String, name: String, customModeID: String,
         outputMode: StickySkillOutputMode = .newNote,
         timeout: CustomModeTimeoutBudget = StickySkill.wholeNoteDefaultTimeout) {
        self.id = id
        self.name = name
        self.customModeID = customModeID
        self.outputMode = outputMode
        self.timeout = timeout
    }

    /// A blank template for the Settings tab's "+ Add new sticky skill". A new skill backs onto a custom
    /// mode of the same id, which is what keeps its route inside the `custom:` namespace.
    static func blank(id: String) -> StickySkill {
        StickySkill(id: id, name: "", customModeID: id)
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !customModeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Codable
    //
    // Written by hand rather than synthesized, on purpose. `CustomMode`'s synthesized Codable is exactly
    // why adding a field to it is a breaking change: one absent key fails the whole decode and every
    // stored row disappears. Only `id` is required here; every other key is `decodeIfPresent` with a
    // documented default, so a future field is additive and a row written by an older build still loads.
    // An unrecognized `outputMode` degrades to `.newNote` instead of throwing, so one bad row cannot take
    // the rest of the user's skills down with it.

    private enum CodingKeys: String, CodingKey {
        case id, name, customModeID, outputMode, timeout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        // A skill's backing mode defaults to its own id: that is the convention a newly added skill
        // follows, so an id-only row is a well-formed skill rather than a routeless one.
        customModeID = try c.decodeIfPresent(String.self, forKey: .customModeID) ?? id
        let rawOutput = try c.decodeIfPresent(String.self, forKey: .outputMode)
        outputMode = rawOutput.flatMap(StickySkillOutputMode.init(rawValue:)) ?? .newNote
        timeout = try c.decodeIfPresent(CustomModeTimeoutBudget.self, forKey: .timeout)
            ?? StickySkill.wholeNoteDefaultTimeout
    }
}

// MARK: - The typed output slot

/// Where a sticky skill's result goes. The v1 set is locked: New note (default), Append to the source
/// note, Copy to clipboard. Overwriting the source body is OUT, and so is anything that writes files or
/// runs commands outside ViddyDictate.
///
/// This is the DECLARATIVE half of the typed slot only. S2 adds the `StickySkillOutputHandler` protocol
/// and the one switch that maps each case to its handler, mirroring the `CustomLanding -> OneShotLanding`
/// idiom, so that a fourth destination later is one case plus one type plus one switch arm.
enum StickySkillOutputMode: String, Codable, CaseIterable {
    case newNote
    case appendToSource
    case copyToClipboard

    var label: String {
        switch self {
        case .newNote:         return "New note"
        case .appendToSource:  return "Append to the source note"
        case .copyToClipboard: return "Copy to clipboard"
        }
    }
}

// MARK: - The note-menu projection

/// The ONLY Sticky Skill shape allowed to cross into the web island. The menu needs an opaque id to invoke
/// and a display name to render; task prompts, backing-mode ids/routes, output modes and timeout budgets stay
/// native. Keeping this as a dedicated two-field value makes that boundary reviewable and mutation-testable.
struct StickySkillMenuItem: Equatable {
    let id: String
    let displayName: String

    /// `JSONSerialization` accepts dictionaries rather than Swift structs. Keep the wire conversion here so
    /// the controller cannot accidentally serialize the full `StickySkill` descriptor later.
    var payload: [String: String] { ["id": id, "displayName": displayName] }
}

enum StickySkillMenuProjection {
    static func items(from skills: [StickySkill]) -> [StickySkillMenuItem] {
        skills.compactMap { skill in
            let trimmed = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // A normal user skill cannot be saved blank through Settings. If a hand-edited row is blank,
            // omit it instead of exposing an unlabelled action. The built-in remains reachable with its
            // shipped label even if its descriptor was hand-edited outside the app.
            let displayName = trimmed.isEmpty && skill.isBuiltIn
                ? StickySkillRegistry.builtInName
                : trimmed
            guard !displayName.isEmpty else { return nil }
            return StickySkillMenuItem(id: skill.id, displayName: displayName)
        }
    }
}

// MARK: - The registry (skillID -> customModeID)

/// The one authority that answers "which custom mode does this skill run through". It replaces the single
/// hardcoded `NoteToHandoffPrompt.customModeID` constant, which could only ever answer that question for
/// one skill.
///
/// THE ADOPTED ROW - read before changing anything here
/// ----------------------------------------------------
/// `noteToHandoffCustomModeID` is a row that ALREADY EXISTS in the user's live `custom-modes.json`. That single
/// row is simultaneously three things:
///   1. the mode behind his right-Option+period selection hotkey, which he uses daily,
///   2. the de facto Note to Handoff mode the whole-note tab action runs, and
///   3. the owner of a ratified Claude/Codex/local route bundle in `models-power.json`, under the route
///      key `custom:3A41E54C-1E85-4E4F-8684-9CD1D82949B4` (ratified 2026-07-07 and 2026-07-14).
///
/// So the built-in skill ADOPTS that row by pointing at its existing UUID. It is never renamed, replaced,
/// re-keyed or regenerated. "Migrating the legacy custom mode into a new Sticky Skill" by minting a fresh
/// UUID would silently unbind his hotkey AND orphan the ratified route bundle, and neither failure shows
/// up as an error - the hotkey just stops doing anything and the route silently falls back to a default.
///
/// `canonicalized` is what makes that structural rather than advisory: whatever a stored (or hand-edited)
/// file says, the built-in's `customModeID` is forced back to the adopted UUID on every load.
enum StickySkillRegistry {
    /// THE ADOPTED ROW. Do not change this literal. See the type comment above.
    static let noteToHandoffCustomModeID = "3A41E54C-1E85-4E4F-8684-9CD1D82949B4"

    /// The built-in skill's own identity IS the adopted row's identity. Giving the skill a second, freshly
    /// minted id would create two identities for one thing, which is the first step of the re-keying
    /// mistake this whole type exists to prevent.
    static let builtInSkillID = noteToHandoffCustomModeID

    /// The name already on the note tab menu's button, kept byte-identical so nothing the user sees is renamed.
    static let builtInName = "Note to Handoff"

    /// The shipped built-in descriptor. Seeded when `sticky-skills.json` has no row for it, and used as
    /// the fallback when the file is missing or unreadable, so Note to Handoff can never disappear.
    static var builtIn: StickySkill {
        StickySkill(id: builtInSkillID, name: builtInName,
                    customModeID: noteToHandoffCustomModeID,
                    outputMode: .newNote, timeout: StickySkill.wholeNoteDefaultTimeout)
    }

    /// The backing row a fresh install did not have before L7. Its identity and shape match the historical
    /// row the built-in adopted: right-Option+period, selection input, and in-place landing. Its legacy model
    /// field seeds the tested Claude custom-route bundle, whose availability ladder can still reach Codex or
    /// Local on a machine without Claude. `CustomModeStore` installs this exact row only when the adopted id
    /// is absent; an existing user's prompt, chord, model, landing, and route always win.
    static var builtInBackingMode: CustomMode {
        let route = LLMRouteID.custom(noteToHandoffCustomModeID)
        return CustomMode(
            id: noteToHandoffCustomModeID,
            name: "Sticky Note to Handoff Prompt",
            chord: .regular(keyCode: 47, label: "."),
            prompt: NoteToHandoffPrompt.defaultTaskPrompt,
            input: .selection,
            model: LLMProviderDefaults.testedBundle(for: .claude, route: route)!,
            landing: .inPlace)
    }

    /// Add the first-run row without ever treating a present row as repairable default data. Presence of
    /// the adopted id is the whole condition: even a user's blank or heavily customized row is theirs.
    static func seedingBuiltInBackingModeIfMissing(_ modes: [CustomMode]) -> [CustomMode] {
        guard !modes.contains(where: { $0.id == noteToHandoffCustomModeID }) else { return modes }
        return modes + [builtInBackingMode]
    }

    /// THE REGISTRY LOOKUP. Which custom mode owns this skill's prompt and route; nil when the skill is
    /// not stored. The built-in resolves through the same path as every other skill rather than through a
    /// special case - `canonicalized` is the single place the adoption invariant is enforced.
    static func customModeID(forSkill skillID: String, in skills: [StickySkill]) -> String? {
        skills.first { $0.id == skillID }?.customModeID
    }

    /// THE SKILL LOOKUP the run path uses (S3). Same rule as `builtInCustomModeID`, one level up: a stored
    /// skill wins, and the built-in falls back to the shipped descriptor so a missing, unreadable or
    /// hand-emptied `sticky-skills.json` degrades Note to Handoff to today's behaviour instead of breaking
    /// the tab action. A user skill that is genuinely gone returns nil and the run fails closed.
    static func skill(_ skillID: String, in skills: [StickySkill]) -> StickySkill? {
        skills.first { $0.id == skillID } ?? (skillID == builtInSkillID ? builtIn : nil)
    }

    /// A user-created sticky skill owns a backing `CustomMode` only as its prompt/route record. It has no
    /// chord half, so that implementation row must not leak back onto the Hotkeys page. The adopted
    /// built-in is the deliberate exception: its backing row is also the user's existing right-Option+period
    /// selection hotkey, and hiding it would regress one of the two locked triggers.
    ///
    /// THE EXEMPTION IS STRUCTURAL, NOT A CONSEQUENCE OF WHAT THE FILE SAYS (S6, measured in the real app).
    /// The membership test above reads `customModeID` off STORED rows, so a row that is not the built-in but
    /// points at the ADOPTED id puts that id into the implementation-only set - and the adopted row then
    /// disappears from `chordSnapshot`, which is the live tap's whole view of custom chords. Driving exactly
    /// that file state through the running app, right-Option+period stopped dispatching with no error
    /// anywhere, and because nothing matched the chord any more the bare `.` was no longer swallowed and
    /// typed a stray character over the user's selection instead. `StickySkillSettingsOperations.add` cannot
    /// mint such a row (it uses one id for both), but a hand-edited or half-written `sticky-skills.json` can,
    /// and the failure is silent - which is precisely how THE LANDMINE says this hotkey dies.
    ///
    /// So the adopted id is removed from the set unconditionally: it is a HOTKEY row first and a skill's
    /// backing row second, and is therefore never implementation-only, whatever any stored row claims. This
    /// mirrors `canonicalized`, which forces the built-in's link rather than trusting the file to hold it.
    static func hotkeyVisibleModes(_ modes: [CustomMode], skills: [StickySkill]) -> [CustomMode] {
        var stickyOnlyModeIDs = Set(skills.lazy.filter { !$0.isBuiltIn }.map(\.customModeID))
        stickyOnlyModeIDs.remove(noteToHandoffCustomModeID)
        return modes.filter { !stickyOnlyModeIDs.contains($0.id) }
    }

    /// The extra prompt rules the SHIPPED skill adds for itself, appended between the stored task prompt
    /// and the shared data fence (S3).
    ///
    /// This is where "the built-in is special" is allowed to live, and the only place. Before S3 the
    /// built-in's attachment-mapping rules were welded into the same string as the injection guard, so any
    /// second skill would have inherited instructions to emit `**applicable attachments**` lines it was
    /// never asked for. A user-authored skill gets an empty addendum: its stored prompt plus the fence.
    static func promptAddendum(for skill: StickySkill) -> String {
        skill.isBuiltIn ? NoteToHandoffPrompt.addendum : ""
    }

    /// What a created note's title is suffixed with. The built-in keeps its short, established "Handoff"
    /// suffix; every other skill is named by itself, truncated by `StickySkillPrompt.outputTitle` so the
    /// 20-character tab-title cap still leaves the source title readable.
    static func outputTitleSuffix(for skill: StickySkill) -> String {
        skill.isBuiltIn ? NoteToHandoffPrompt.outputTitleSuffix : skill.name
    }

    /// The live answer for the built-in. Falls back to the adopted UUID when the store holds nothing
    /// usable, so a missing or corrupt skills file degrades to today's behavior instead of breaking
    /// Note to Handoff.
    static var builtInCustomModeID: String {
        skill(builtInSkillID, in: StickySkillStore.shared.skills)?.customModeID
            ?? noteToHandoffCustomModeID
    }

    /// Enforce the two structural invariants on a decoded skill list:
    ///  1. the built-in is always present, and first;
    ///  2. the built-in points at the adopted custom-mode row, whatever the file happened to say.
    ///
    /// Every other field of a stored built-in row (its name, output mode, timeout) is the user's and is
    /// preserved - only the identity link is forced.
    static func canonicalized(_ skills: [StickySkill]) -> [StickySkill] {
        var out = skills
        if let i = out.firstIndex(where: { $0.id == builtInSkillID }) {
            out[i].customModeID = noteToHandoffCustomModeID
            let adopted = out.remove(at: i)
            out.insert(adopted, at: 0)
        } else {
            out.insert(builtIn, at: 0)
        }
        return out
    }
}
