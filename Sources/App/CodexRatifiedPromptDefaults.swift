import Foundation

/// The three RESCUE-GATE prompt variants ratified on 2026-07-14. The identity hash covers the
/// exact developer-instruction bytes in the sealed rescue screen, including its frozen glossary
/// snapshot. Production rebuilds the same recipe with the live glossary so Dictionary edits remain
/// dynamic; the stable base and exact ratified constraint suffix stay byte-pinned here.
struct CodexRatifiedPromptVariant: Equatable {
    let id: String
    let contentHash: String
    let basePrompt: String
    let constraint: String

    var promptWithoutGlossary: String {
        developerInstructions(glossarySuffix: "")
    }

    func developerInstructions(glossarySuffix: String) -> String {
        basePrompt + glossarySuffix
            + "\n\nAdditional constraints for this transformation:\n"
            + constraint
    }
}

enum CodexRatifiedPromptDefaults {
    static let cleanupL3 = CodexRatifiedPromptVariant(
        id: "qualifier-lock",
        contentHash: "724ce8dfdc9c9f3872a3f0ffcc31feaf7aef375ae753beaeb2fa67809f6f42f7",
        basePrompt: summarizeCleanupPrompt,
        constraint: "Preserve all meaningful qualifiers, uncertainty, scope, contrasts, examples, and questions. "
            + "Do not turn tentative language into certainty, narrow or broaden a category, strengthen a plan, "
            + "answer a question, or replace a specific distinction with an inferred one. Clarity may change "
            + "order and wording, but not commitment strength or factual scope.")

    static let promptPrep = CodexRatifiedPromptVariant(
        id: "minimal-edit",
        contentHash: "a94d90e7e05480f266766f7a1313de668106dc6318a658ec9c253090fcad74aa",
        basePrompt: tightenCleanupPrompt,
        constraint: "Make the smallest edits needed to produce a grammatical, readable, standalone prompt: "
            + "remove disfluency, collapse exact redundancy, and repair punctuation or run-ons. Keep "
            + "already-clear wording unchanged. Do not introduce new framing, restate the goal, change the "
            + "speaker's voice, or make an implicit request more elaborate.")

    static let email = CodexRatifiedPromptVariant(
        id: "final-format-audit",
        contentHash: "df664e1016fc18d892ef345de0ec0adcbd5329874fa66690e590e798874cc521",
        basePrompt: defaultEmailSystemPrompt,
        constraint: "Before returning the email, silently audit all of these conditions: the greeting follows "
            + "the required rule; every distinct content unit is present and independently paragraphed; no fact "
            + "or implication was added; the body is plain text with no markdown; and the final two lines are "
            + "exactly the required sign-off. Repair every failed condition, then return only the final email.")

    static func variant(for route: LLMRouteID) -> CodexRatifiedPromptVariant? {
        LLMProviderDefaults.ratifiedCodexPromptVariant(for: route)
    }

    // MARK: - Test-only sealed fixture (do not use in production)

    /// Exact glossary snapshot sealed alongside rescue-screen.json. It is test material only; production
    /// always supplies `CorrectionDictionary.shared.contextGlossarySuffix()` instead.
    static let sealedGlossaryEntries = [
        CorrectionEntry(heard: "session closed", intended: "session close"),
        CorrectionEntry(heard: "quen", intended: "qwen"),
        CorrectionEntry(heard: "quinn", intended: "qwen"),
        CorrectionEntry(heard: "post grass", intended: "Postgres"),
        CorrectionEntry(heard: "type script", intended: "TypeScript"),
        CorrectionEntry(heard: "Gemma for", intended: "Gemma4"),
        CorrectionEntry(heard: "QEN", intended: "qwen"),
        CorrectionEntry(heard: "video dictate", intended: "Viddydictate"),
        CorrectionEntry(heard: "view model", intended: "ViewModel"),
        CorrectionEntry(heard: "xima OS", intended: "Zima os"),
    ]

    static func sealedDeveloperInstructions(for route: LLMRouteID) -> String? {
        variant(for: route)?.developerInstructions(
            glossarySuffix: CorrectionDictionary.contextGlossarySuffix(sealedGlossaryEntries))
    }
}
