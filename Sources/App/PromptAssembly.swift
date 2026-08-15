import Foundation

/// One piece of the assembled prompt, as the prompt workstation draws it.
///
/// `scaffold` is PRESENTATION: text the app itself puts around what the user wrote. It is never
/// stored in a mode's prompt and never travels back through Save. `editable` is the mode's own
/// stored task prompt — the only piece Save writes. `transcript` is the placeholder standing exactly
/// where the dictation is injected at run time.
enum PromptAssemblySegment: Equatable {
    case scaffold(String)
    case editable(String)
    case transcript(String)

    var text: String {
        switch self {
        case .scaffold(let s), .editable(let s), .transcript(let s): return s
        }
    }
}

/// The two messages a custom-mode run actually sends, each decomposed into display segments.
struct PromptAssemblyLayout: Equatable {
    let system: [PromptAssemblySegment]
    let user: [PromptAssemblySegment]
}

/// Decomposes the prompt a custom mode really sends into the segments the workstation displays.
///
/// The point of this type is that the panel must NOT carry its own copy of the marker format. The
/// lead and trail around each editable region are DERIVED: a sentinel is pushed through the real
/// assembly functions (`CustomModeClient.systemPrompt`, `CleanupClient.wrap`) and their output is
/// split on it. Whatever those functions emit is what the panel shows; if either grows a preamble or
/// its markers change, the display follows with no edit here. That matters because the panel tells
/// the user the composition is literally what gets sent — a hand-written mock-up that drifted would
/// be worse than showing nothing at all.
enum PromptAssembly {
    /// The placeholder drawn between the markers. It stands where the dictation lands; it is display
    /// text only and is never sent (a real run substitutes the transcript at that exact spot).
    static let defaultTranscriptPlaceholder = "(your dictation is inserted here)"
    static let defaultWholeNotePlaceholder = "(the current sticky note body is inserted here)"

    /// Object-replacement-character bookends: not text a prompt or a transcript plausibly contains,
    /// and invisible rather than misleading if one ever leaked into a rendered string.
    static let editableSentinel = "\u{FFFC}VIDDYDICTATE-TASK-PROMPT\u{FFFC}"
    static let transcriptSentinel = "\u{FFFC}VIDDYDICTATE-TRANSCRIPT\u{FFFC}"

    /// The layout for a custom mode's shared task prompt, or nil when the assembly cannot be
    /// decomposed unambiguously (a sentinel that vanished, or came back more than once). nil means
    /// "fall back to the plain editor": the panel never invents a scaffold it could not derive.
    static func customMode(
        taskPrompt: String,
        transcriptPlaceholder: String = defaultTranscriptPlaceholder,
        systemAssembly: (String) -> String = CustomModeClient.systemPrompt(taskPrompt:),
        userAssembly: (String) -> String = CleanupClient.wrap
    ) -> PromptAssemblyLayout? {
        guard let sys = split(systemAssembly(editableSentinel), on: editableSentinel),
              let usr = split(userAssembly(transcriptSentinel), on: transcriptSentinel) else { return nil }
        var system: [PromptAssemblySegment] = []
        if !sys.lead.isEmpty { system.append(.scaffold(sys.lead)) }
        system.append(.editable(taskPrompt))
        if !sys.trail.isEmpty { system.append(.scaffold(sys.trail)) }
        var user: [PromptAssemblySegment] = []
        if !usr.lead.isEmpty { user.append(.scaffold(usr.lead)) }
        user.append(.transcript(transcriptPlaceholder))
        if !usr.trail.isEmpty { user.append(.scaffold(usr.trail)) }
        return PromptAssemblyLayout(system: system, user: user)
    }

    /// The Sticky Skills workstation is derived from the SAME assembly as a real whole-note run: stored
    /// task prompt, built-in-only addendum, app-owned guard last, then the title/attachment/body payload
    /// inside `CleanupClient.wrap`'s outer fence. The placeholder stands only for the changing note body;
    /// the surrounding title and attachment catalog labels are the production functions' own bytes.
    static func stickySkill(
        taskPrompt: String,
        skill: StickySkill,
        noteBodyPlaceholder: String = defaultWholeNotePlaceholder
    ) -> PromptAssemblyLayout? {
        customMode(
            taskPrompt: taskPrompt,
            transcriptPlaceholder: noteBodyPlaceholder,
            systemAssembly: { editable in
                CustomModeClient.systemPrompt(taskPrompt: StickySkillPrompt.taskPrompt(
                    basePrompt: editable,
                    addendum: StickySkillRegistry.promptAddendum(for: skill)))
            },
            userAssembly: { body in
                CleanupClient.wrap(StickySkillPrompt.sourceText(
                    title: "(the current sticky note title is inserted here)",
                    body: body,
                    attachments: []))
            })
    }

    /// Concatenate segments back into the message text they claim to display. The workstation's
    /// contract is that this equals what the request builder sends, so the gates assert exactly that.
    static func rendered(_ segments: [PromptAssemblySegment]) -> String {
        segments.map(\.text).joined()
    }

    private static func split(_ assembled: String, on sentinel: String) -> (lead: String, trail: String)? {
        let parts = assembled.components(separatedBy: sentinel)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}
