import Foundation

// VDASK-7: the Option+P review gate, pure. The registry calls `AskBackSelectionGate.asks` with the frozen
// prompt-prep provider and the selected text; these rows pin the four conditions and the 49/50-word boundary
// the design sets (the same threshold as a dictation take, with no length downgrade for Option+P).
// Every fixture is synthetic text invented here.
enum AskBackOneShotSelfTest {
    static func checks() -> [(String, Bool)] {
        func words(_ n: Int) -> String {
            (1...n).map { "selected\($0)" }.joined(separator: " ")
        }
        let at49 = words(49)
        let at50 = words(50)
        return [
            ("oneshot gate: 50 selected words asks under Tighten on Claude with ask-back on",
             AskBackSelectionGate.asks(input: at50, level: .tighten, provider: .claude, enabled: true)),
            ("oneshot gate: 49 selected words does not ask",
             !AskBackSelectionGate.asks(input: at49, level: .tighten, provider: .claude, enabled: true)),
            ("oneshot gate: Summarize asks too",
             AskBackSelectionGate.asks(input: at50, level: .summarize, provider: .claude, enabled: true)),
            ("oneshot gate: Cleanup never asks",
             !AskBackSelectionGate.asks(input: at50, level: .cleanup, provider: .claude, enabled: true)),
            ("oneshot gate: a local route never asks",
             !AskBackSelectionGate.asks(input: at50, level: .summarize, provider: .local, enabled: true)),
            ("oneshot gate: Codex asks",
             AskBackSelectionGate.asks(input: at50, level: .tighten, provider: .codex, enabled: true)),
            ("oneshot gate: ask-back off never asks",
             !AskBackSelectionGate.asks(input: at50, level: .summarize, provider: .claude, enabled: false)),
            ("oneshot gate: whitespace splitting counts the same words as a take (newlines and tabs)",
             !AskBackSelectionGate.asks(input: (1...49).map { "w\($0)" }.joined(separator: "\n\t "),
                                        level: .summarize, provider: .codex, enabled: true)
                && AskBackSelectionGate.asks(input: (1...50).map { "w\($0)" }.joined(separator: "\n\t "),
                                             level: .summarize, provider: .codex, enabled: true)),
            ("oneshot gate: an empty selection never asks",
             !AskBackSelectionGate.asks(input: "", level: .summarize, provider: .claude, enabled: true)),
        ]
    }

    static func run() -> Bool {
        print("--- ask-back Option+P gate: the selected-text review conditions ---")
        let check = SelfTestReporter()
        for (name, ok) in checks() { check.check(name, ok) }
        print(check.summaryLine(prefix: "[askback-oneshot-selftest]"))
        return check.passed
    }
}
