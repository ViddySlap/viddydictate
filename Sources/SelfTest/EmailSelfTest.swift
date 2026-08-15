import Foundation

/// The headless `--email-selftest` seam for Option+M email mode (mirrors `CleanupSelfTest`).
///
/// Two layers:
///  1. **Unit coverage** of the email-specific pure logic — the locked prompt's load-bearing rules
///     are present, the `Notes:` user-message fence is built correctly, the reasoning-channel stripper
///     handles closed/unclosed <think> blocks, and the shared normalizer strips markdown backticks
///     while still mapping typographic punctuation. No network.
///  2. **The end-to-end output test** — a few corpus inputs run through the REAL compiled `EmailClient`
///     -> LM Studio (gemma-4-e4b) -> finished email, then checked for the email's required SHAPE:
///     non-empty, a `Hi ...,` greeting, the exact `Thanks,` / `[Your name]` sign-off, and pure ASCII
///     (no em/en dashes, no backticks, no smart quotes).
///
/// Exits 0 only when every unit check passes AND every corpus output clears the shape gate.
enum EmailSelfTest {

    // MARK: corpus fixtures (verbatim from the signed-off email bench corpus)

    struct Fixture { let id: String; let input: String; let expectGreetingPrefix: String }

    static let fixtures: [Fixture] = [
        Fixture(id: "01-single-named",
            input: "ok so need to ping sarah about the homepage mockups, basically they're done finally, i uploaded them to the shared drive in the design folder, want her to take a look and flag anything before i move into building it out, just need her sign off basically",
            expectGreetingPrefix: "Hi "),
        Fixture(id: "02-single-question",
            input: "let dana know i cant make the tuesday call, something came up, ask if we can push it to thursday same time or whatever works for her later that week",
            expectGreetingPrefix: "Hi "),
        Fixture(id: "23-multi-recipient",
            input: "ok need to get this out the door, the proofs for the lobby signage are approved, vendor can move to production, final files are in the shared drive folder called Lobby_v4, run time they quoted was ten business days so that puts delivery early july. also remind whoever that the install has to happen after hours, building wont allow it during the day.",
            expectGreetingPrefix: "Hi "),
    ]

    // MARK: entry point

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate Email (Option+M) — selftest ===")
        print("model=\(Settings.emailModel)  endpoint=\(Settings.emailEndpoint.absoluteString)")
        print("temp=\(Settings.emailTemperature)  maxTokens=\(Settings.emailMaxTokens)  timeout=\(Settings.emailTimeout)s\n")

        let unitOK = runUnitTests()
        let (outputOK, results) = runOutputTests()

        print("\n=== RESULT ===")
        print("unit tests:   \(unitOK ? "PASS" : "FAIL")")
        print("output shape: \(outputOK ? "PASS (every corpus email cleared the shape gate)" : "FAIL (a corpus email failed the shape gate)")")
        for r in results {
            print("  [\(r.id)] \(String(format: "%.2fs", r.latency)) \(r.failures.isEmpty ? "clean ✓" : "FAIL ❌ — " + r.failures.joined(separator: " | "))")
        }
        let green = unitOK && outputOK
        print(green ? "\nGREEN BAR CLEARED ✅" : "\nGREEN BAR NOT CLEARED ❌")
        return green
    }

    // MARK: unit coverage (no network)

    private static func runUnitTests() -> Bool {
        print("--- unit coverage (no network) ---")
        let reporter = SelfTestReporter()
        let check = reporter.check

        // The locked prompt's load-bearing rules survive into Settings (default, no user override).
        let p = Settings.emailSystemPrompt
        check("prompt non-empty", !p.isEmpty)
        check("prompt carries the signature placeholder", p.contains("[Your name]"))
        check("prompt carries the greeting rule", p.contains("Hi <FirstName>,") && p.contains("Hi all,"))
        check("prompt carries the brevity headline", p.contains("BREVITY IS THE MOST IMPORTANT QUALITY"))
        check("prompt carries strict faithfulness", p.contains("STRICT FAITHFULNESS"))
        check("prompt forbids markdown", p.contains("no markdown"))
        check("prompt is the SYSTEM part only (no Notes seam)", !p.contains("<<<NOTES>>>"))

        // The user-message fence: system + user reconstitutes the locked prompt with the selection in.
        let wrapped = EmailClient.wrap("hello world")
        check("wrap builds the Notes fence", wrapped == "Notes:\n<<<NOTES>>>\nhello world\n<<<END NOTES>>>")

        // Reasoning-channel stripper: closed, multiple, and unclosed <think> blocks.
        check("strip closed think block", CleanupClient.stripReasoning("<think>plan</think>Hi Sarah,") == "Hi Sarah,")
        check("strip multiple think blocks", CleanupClient.stripReasoning("<think>a</think>X<think>b</think>Y") == "XY")
        check("strip unclosed think tail", CleanupClient.stripReasoning("Hi all,\n<think>never closed") == "Hi all,\n")
        check("no think tag leaves text intact", CleanupClient.stripReasoning("Hi Dana,") == "Hi Dana,")

        // Shared normalizer now strips markdown backticks while still mapping typographic punctuation.
        check("normalizer strips backticks", CleanupClient.asciiPunctuationNormalized("use `checkout-v2` now") == "use checkout-v2 now")
        check("normalizer maps typographic punctuation",
            CleanupClient.asciiPunctuationNormalized("a\u{2014}b \u{201C}c\u{201D} e\u{2019}s") == "a - b \"c\" e's")

        // Input resolution shared with Option+P (selection preferred, clipboard fallback, nil when blank).
        check("input prefers selection", CleanupLogic.promptPrepInput(selection: "notes", clipboard: "clip") == "notes")
        check("input falls back to clipboard", CleanupLogic.promptPrepInput(selection: nil, clipboard: "clip") == "clip")
        check("input nil when both blank", CleanupLogic.promptPrepInput(selection: "  ", clipboard: "") == nil)

        // Dual-mode Option+M gate: > 2 dictated words is a real dictation-email; <= 2 is incidental
        // noise during a selection transform and falls back to the selection path.
        check("dictation gate accepts 3 words", CleanupLogic.isDictationEmail(wordCount: 3))
        check("dictation gate accepts a long transcript", CleanupLogic.isDictationEmail(wordCount: 18))
        check("dictation gate rejects 2 words (incidental)", !CleanupLogic.isDictationEmail(wordCount: 2))
        check("dictation gate rejects an empty transcript", !CleanupLogic.isDictationEmail(wordCount: 0))

        // The shape detectors validate themselves (so a real-output FAIL means the model, not the gate).
        check("detect missing greeting", !shapeFailures(email: "The mockups are ready.\n\nThanks,\n[Your name]", greetingPrefix: "Hi ").isEmpty)
        check("detect wrong signoff", shapeFailures(email: "Hi Sarah,\n\nReady.\n\nBest,\nAlex", greetingPrefix: "Hi ").contains { $0.hasPrefix("signoff") })
        check("detect non-ascii", shapeFailures(email: "Hi all,\n\nReady \u{2014} done.\n\nThanks,\n[Your name]", greetingPrefix: "Hi ").contains { $0.hasPrefix("non-ascii") })
        check("well-formed email passes the gate", shapeFailures(email: "Hi Sarah,\n\nThe mockups are ready.\n\nThanks,\n[Your name]", greetingPrefix: "Hi ").isEmpty)

        print("  -> unit: \(reporter.passed ? "PASS" : "FAIL")\n")
        return reporter.passed
    }

    // MARK: end-to-end output test

    struct OutputResult { let id: String; let latency: TimeInterval; let failures: [String] }

    private static func runOutputTests() -> (Bool, [OutputResult]) {
        print("--- end-to-end output test (real EmailClient -> LM Studio gemma-4-e4b) ---")
        var results: [OutputResult] = []
        var allClear = true
        for f in fixtures {
            let (res, wall) = EmailClient.emailSync(f.input, timeout: 90)
            var email = ""
            var failures: [String] = []
            switch res {
            case .ok(let e): email = e
            case .unavailable(let w): failures = ["service-unavailable: \(w)"]
            case .timedOut: failures = ["service-timeout"]
            case .badOutput(let w): failures = ["bad-output: \(w)"]
            }
            if !email.isEmpty { failures += shapeFailures(email: email, greetingPrefix: f.expectGreetingPrefix) }
            let r = OutputResult(id: f.id, latency: wall, failures: failures)
            results.append(r)
            if !failures.isEmpty { allClear = false }

            print("\n  [\(f.id)]  \(String(format: "%.2fs", wall))  \(failures.isEmpty ? "clean ✓" : "FAIL ❌")")
            print("    input : \(snippet(f.input))")
            print("    email : \(snippet(email.replacingOccurrences(of: "\n", with: " ⏎ ")))")
            if !failures.isEmpty { print("    failures: \(failures.joined(separator: " | "))") }
        }
        return (allClear, results)
    }

    // MARK: shape gate

    /// The email's required shape: non-empty, a `Hi ...,` greeting on the first line, the exact two-line
    /// `Thanks,` / `[Your name]` sign-off at the end, and pure ASCII (the normalizer's hard guarantee —
    /// any non-ASCII char, em/en dash, smart quote, or backtick is a fail).
    static func shapeFailures(email: String, greetingPrefix: String) -> [String] {
        var out: [String] = []
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ["empty-output"] }

        let lines = trimmed.components(separatedBy: "\n")
        if let first = lines.first {
            if !first.hasPrefix(greetingPrefix) { out.append("greeting: first line '\(snippet(first, 40))' lacks '\(greetingPrefix)' prefix") }
            if !first.hasSuffix(",") { out.append("greeting: first line does not end with a comma") }
        }

        if !trimmed.hasSuffix("Thanks,\n[Your name]") { out.append("signoff: does not end with the locked 'Thanks,' / '[Your name]'") }

        for scalar in trimmed.unicodeScalars where scalar.value > 127 {
            out.append("non-ascii: U+\(String(format: "%04X", scalar.value))")
            break
        }
        if trimmed.contains("`") { out.append("non-ascii: residual backtick") }

        return out
    }

    private static func snippet(_ s: String, _ n: Int = 200) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count <= n ? t : String(t.prefix(n)) + " …"
    }
}
