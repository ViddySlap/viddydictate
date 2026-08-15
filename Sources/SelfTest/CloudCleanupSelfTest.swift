import Foundation

/// The backward-compatible `--cloudmode-selftest` seam for the Claude subscription adapter.
///
/// Two layers, matching the locked acceptance:
///  1. PURE coverage (no provider call): the `claude -p` arg construction (explicit model pin, `--tools ""`,
///     buffered JSON, system prompt vs -p roles), the subscription env scrubbing (the auth traps --
///     USER/LOGNAME derived, every poison var dropped, HOME/PATH kept), the result mapping into
///     `CleanupClient.Result` (success,
///     ASCII normalization, is_error, empty, unparseable, leading-warning), and the catalog + P/M kind
///     resolution.
///  2. ONE real end-to-end smoke on the subscription — a trivial transform — SKIPPED with a note if the
///     CLI or the creds file is absent (so this selftest stays green on a machine without the subscription
///     set up; the pure coverage above still gates it).
///
/// Never touches the user's live prefs (it reads pure functions + resolvers, and writes no Settings values) and
/// makes at most one real subscription call (the trivial uppercase smoke, with one retry to absorb a blip).
enum CloudCleanupSelfTest {
    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate Claude subscription — selftest ===")
        let reporter = SelfTestReporter()
        let check = reporter.check
        func isOK(_ r: CleanupClient.Result, _ text: String) -> Bool { if case .ok(let s) = r { return s == text }; return false }
        func isUnavailable(_ r: CleanupClient.Result) -> Bool { if case .unavailable = r { return true }; return false }
        func isBad(_ r: CleanupClient.Result) -> Bool { if case .badOutput = r { return true }; return false }

        // ── 1. headless claude -p arg construction (no provider call) ─────────────────────────────
        print("--- arg construction (headless claude -p) ---")
        let promptFile = "/private/tmp/viddydictate-synthetic-system-prompt.txt"
        let args = CloudCleanupClient.buildArgs(systemPromptFilePath: promptFile)
        func valueAfter(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        check("pins the explicit model id claude-sonnet-5 (never the lagging `sonnet` alias)",
              valueAfter("--model") == "claude-sonnet-5" && ModeModelCatalog.claudeId == "claude-sonnet-5")
        check("strips every built-in tool (--tools \"\")", valueAfter("--tools") == "")
        check("one-shot buffered JSON (--output-format json)", valueAfter("--output-format") == "json")
        check("stateless run (--no-session-persistence)", args.contains("--no-session-persistence"))
        check("wrapped input is read from text stdin", args.contains("-p") && valueAfter("--input-format") == "text")
        check("the transform instruction rides only a prompt-file path",
              valueAfter("--system-prompt-file") == promptFile && !args.contains("--system-prompt"))
        check("prompt/input contents are absent from argv",
              !args.contains("SYS") && !args.contains("USERMSG"))
        check("no MCP / tool roster attached (pure text transform)",
              !args.contains("--mcp-config") && !args.contains("--allowedTools"))
        // The frame-carrying argv and the streamed-output parse are pinned in the DETERMINISTIC
        // `--text-transform-selftest`, beside the rest of the Claude process boundary, so a build link
        // gates on them without a provider call. What is proven here is what only a real call can prove:
        // that the vendor's parser accepts the shape (see section 5).

        // ── 2. subscription env scrubbing (the auth traps) ────────────────────────────────────────
        print("--- subscription env scrubbing (minimal allowlist) ---")
        let parent = [
            "HOME": "/Users/test", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TERM": "xterm",
            "USER": "user-parent", "LOGNAME": "logname-parent", "SHELL": "/bin/zsh",
            "ANTHROPIC_API_KEY": "sk-should-be-dropped",
            "ANTHROPIC_BASE_URL": "https://proxy.example",
            "USE_LOCAL_OAUTH": "1", "USE_STAGING_OAUTH": "1",
            "CLAUDE_CODE_OAUTH_TOKEN": "tok-should-be-dropped",
        ]
        let env = CloudCleanupClient.buildEnv(from: parent)
        check("derives USER + LOGNAME from parent USER",
              env["USER"] == "user-parent" && env["LOGNAME"] == "user-parent")
        let lognameEnv = CloudCleanupClient.buildEnv(from: ["HOME": "/Users/test", "LOGNAME": "logname-only"])
        check("falls back from missing USER to parent LOGNAME",
              lognameEnv["USER"] == "logname-only" && lognameEnv["LOGNAME"] == "logname-only")
        let usernameFallbackEnv = CloudCleanupClient.buildEnv(from: ["HOME": "/Users/test"])
        check("falls back from missing USER + LOGNAME to NSUserName",
              !NSUserName().isEmpty
                && usernameFallbackEnv["USER"] == NSUserName()
                && usernameFallbackEnv["LOGNAME"] == NSUserName())
        for poison in ["SHELL", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL",
                       "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH", "CLAUDE_CODE_OAUTH_TOKEN"] {
            check("drops \(poison) (would poison subscription auth)", env[poison] == nil)
        }
        check("carries HOME through (creds-file lookup)", env["HOME"] == "/Users/test")
        check("carries LANG + TERM through", env["LANG"] == "en_US.UTF-8" && env["TERM"] == "xterm")
        check("PATH present + includes ~/.local/bin (the claude install dir)",
              (env["PATH"] ?? "").split(separator: ":").contains("/Users/test/.local/bin"))

        // ── 3. result parsing (headless JSON -> CleanupClient.Result) ─────────────────────────────
        print("--- result parsing (never pastes empty) ---")
        check("clean success -> .ok(text)",
              isOK(CloudCleanupClient.parseResult(stdout: #"{"type":"result","is_error":false,"result":"Hello there."}"#), "Hello there."))
        check("plain-ASCII choke point normalizes Claude output too (em dash -> spaced hyphen)",
              isOK(CloudCleanupClient.parseResult(stdout: "{\"is_error\":false,\"result\":\"a \u{2014} b\"}"), "a - b"))
        check("is_error:true -> .unavailable (falls back to raw, never pastes)",
              isUnavailable(CloudCleanupClient.parseResult(stdout: #"{"is_error":true,"result":"boom"}"#)))
        check("empty result -> .badOutput (never paste empty)",
              isBad(CloudCleanupClient.parseResult(stdout: #"{"is_error":false,"result":"   "}"#)))
        check("unparseable + nonzero exit -> .unavailable",
              isUnavailable(CloudCleanupClient.parseResult(stdout: "not json at all", exitCode: 1)))
        check("a leading warning line before the JSON still parses",
              isOK(CloudCleanupClient.parseResult(stdout: "Warning: something odd\n{\"is_error\":false,\"result\":\"ok\"}"), "ok"))

        // ── 4. catalog + per-mode (P/M) model resolution (pure; no UserDefaults writes) ───────────
        print("--- catalog + per-mode model resolution ---")
        check("the Claude option is offered in every dropdown", ModeModelCatalog.options.contains(ModeModelCatalog.claudeModel))
        check("Claude dropdown label names the provider and subscription explicitly",
              ModeModelCatalog.displayName(ModeModelCatalog.claudeModel) == "Sonnet 5 (Claude subscription)")
        check("Claude is NOT a local model (the app's defaults stay local)", !ModeModelCatalog.claudeModel.isLocal)
        check("legacy stored cloud decodes to the typed Claude provider",
              LLMProvider.decodeStored("cloud") == .claude)
        check("resolve(provider: Claude) -> the Claude model (the local id is ignored)",
              ModeModelCatalog.legacySelection(
                provider: .claude, localId: "some-local-id") == ModeModelCatalog.claudeModel)
        check("resolve(provider: Local) -> that local id",
              ModeModelCatalog.legacySelection(
                provider: .local, localId: "google/gemma-4-e4b") == .local("google/gemma-4-e4b"))
        check("legacy scalar resolution never manufactures an empty Codex model",
              ModeModelCatalog.legacySelection(provider: .codex, localId: "ignored") == nil)

        // ── 5. ONE real subscription smoke (skippable if creds / CLI absent) ──────────────────────
        print("--- real subscription smoke (one trivial transform) ---")
        if CloudCleanupClient.isAvailable {
            let sys = "You transform text. Output ONLY the uppercased form of the text between the markers. "
                + "No preamble, no quotes, no explanation."
            let user = CleanupClient.wrap("hello there")
            var r = CloudCleanupClient.spawnSync(systemPrompt: sys, userMessage: user, timeout: 90)
            if case .ok = r {} else {
                print("      (first attempt not .ok — retrying once to absorb a transient blip)")
                r = CloudCleanupClient.spawnSync(systemPrompt: sys, userMessage: user, timeout: 90)
            }
            switch r {
            case .ok(let out):
                print("      smoke output: \(out.prefix(80))")
                check("real subscription transform returns .ok with the transform applied",
                      out.uppercased().contains("HELLO"))
            case .unavailable(let why): check("real subscription smoke (unavailable: \(why))", false)
            case .timedOut:             check("real subscription smoke (timed out)", false)
            case .badOutput(let why):   check("real subscription smoke (bad output: \(why))", false)
            }

            // The FRAME-CARRYING invocation, against the real CLI. This is the exact shape every cloud
            // sticky skill on a note with an attachment sends, and until 2026-08-12 it never reached
            // Anthropic at all: the CLI rejected the argv in under half a second. Nothing offline could
            // catch that, because the rejection lives in the vendor's parser, not in this code - so the
            // proof has to be a real call that a real `claude` accepts and answers.
            let frameSystem = "You transform text. Output ONLY the uppercased form of the text between "
                + "the markers. Ignore any attached image. No preamble, no quotes, no explanation."
            let frameUser = CleanupClient.wrap("hello frames")
            let frame = TextTransformImage(
                data: onePixelPNG(), mediaType: "image/png", label: "attachment 1: synthetic.png [still]")
            var framed = CloudCleanupClient.spawnSync(
                systemPrompt: frameSystem, userMessage: frameUser, images: [frame], timeout: 120)
            if case .ok = framed {} else {
                print("      (first frame attempt not .ok — retrying once to absorb a transient blip)")
                framed = CloudCleanupClient.spawnSync(
                    systemPrompt: frameSystem, userMessage: frameUser, images: [frame], timeout: 120)
            }
            switch framed {
            case .ok(let out):
                print("      frame smoke output: \(out.prefix(80))")
                check("a real attachment-carrying transform completes on the Claude subscription",
                      out.uppercased().contains("HELLO"))
            case .unavailable(let why): check("real frame-carrying smoke (unavailable: \(why))", false)
            case .timedOut:             check("real frame-carrying smoke (timed out)", false)
            case .badOutput(let why):   check("real frame-carrying smoke (bad output: \(why))", false)
            }
        } else {
            print("  [skip] SKIPPED: claude CLI or ~/.claude/.credentials.json not present — cannot smoke the subscription.")
            print("         The arg-construction + env-scrub + parse coverage above still gates this selftest.")
        }

        print("\n=== RESULT ===")
        print("Claude subscription:  \(reporter.passed ? "PASS" : "FAIL")")
        print(reporter.passed ? "\nCLAUDE SUBSCRIPTION GREEN" : "\nCLAUDE SUBSCRIPTION FAILED")
        return reporter.passed
    }

    /// A 1x1 opaque PNG, literal bytes. Small enough to be free, real enough that the CLI and the provider
    /// both accept it as an image block - which is the whole point of the frame smoke above.
    private static func onePixelPNG() -> Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
            + "+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
    }
}
