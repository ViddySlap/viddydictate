import Foundation
import Darwin

/// The Claude subscription transform adapter: a headless `claude -p` one-shot that runs a mode's
/// transform on the configured Claude Max subscription (never the paid API), using the proven
/// subscription environment (`subscriptionEnv()` + `runHeadlessClaude`) and argument shape. It is the
/// Claude counterpart of `CleanupClient` / `EmailClient`: same `CleanupClient.Result`
/// contract, same plain-ASCII choke point, same "failure never pastes empty" invariant — so every mode's
/// land/raw-fallback wiring in `OneShotRegistry` is identical for Local, Claude, and Codex.
///
/// Why shell the CLI instead of the paid API: with the claude.ai Max OAuth creds present on disk
/// (`~/.claude/.credentials.json`, subscriptionType=max), a headless `claude -p` authenticates from that
/// file and the turn counts against the plan's rate limits, NOT per-token API billing. The auth is
/// FRAGILE in three verified ways (memory `project-headless-claude-auth`), all defended here in one place:
///   - a minimal ALLOWLIST env (`HOME PATH TMPDIR LANG LC_ALL TERM`) -- inherited `ANTHROPIC_BASE_URL` /
///     `USE_*_OAUTH` / `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` would silently point auth elsewhere
///     (401, or a billed API call). USER/LOGNAME are now added explicitly. This reverses the 2026-07-01
///     trap fix, when stripping USER forced deterministic credentials-file auth and avoided a stale or
///     unreadable Keychain lookup. Claude CLI >= 2.1.214 now fails instantly with "OAuth session expired
///     and could not be refreshed" without USER, even with a fresh valid creds file (A/B-verified on this
///     exact argv 2026-07-19). This matches the proven `subscriptionEnv()` behavior;
///   - the explicit model id `claude-sonnet-5` (the `sonnet` ALIAS lags the binary's registry, resolving
///     to an older model — memory `reference-claude-headless-model-effort`);
///   - `--tools ""` strips every built-in tool (no Read/Bash/WebSearch) and no MCP roster is attached. L11
///     may add app-owned attachment frames to the same user turn, but never adds a tool surface.
///
/// Privacy: only the dictation or selected text for the requested transform is sent to Anthropic.
/// No workspace context or tool surface is attached. The transcript is never logged to a new place;
/// only character counts and timings ride the app log, exactly like the local clients.
///
/// The pure pieces (`buildArgs` / `buildEnv` / `parseResult`) are factored out so the headless selftest
/// proves arg construction + env scrubbing + result mapping WITHOUT a real provider call; `spawnSync` does
/// the one real subscription smoke. User text is delivered on stdin and the effective system prompt is
/// held only in a mode-0600 ephemeral file whose path (never contents) rides argv.
///
/// Compatibility type name retained because the sealed bakeoff source inventory references this file;
/// all behavior and diagnostics below are explicitly Claude-specific.
enum CloudCleanupClient {

    /// The generous safety ceiling for a Claude one-shot: CLI boot (~2-5s) + a long-selection transform on
    /// the subscription. Well above the >= 60s the spec floors, and far above any local timeout.
    static let defaultTimeout: TimeInterval = 90

    /// A SEPARATE, GENEROUS clock bounding the three pipe drains in `runProcess`, deliberately NOT the
    /// caller's `timeout`/`grace`. Those bound the KILL; this bounds the DRAIN, and the two fail for
    /// different reasons. It is one shared budget across all three waits, not three of them.
    ///
    /// WHY 10s IS GENEROUS, measured 2026-08-19 by `vdd-D2` over 35 real `runProcess` runs across 13
    /// shapes, timing each wait individually. The drain WAIT is microseconds in every legitimate case,
    /// because the reader threads start at spawn and run concurrently with the whole wait/TERM/KILL/reap
    /// sequence -- by the time control reaches the waits, EOF has almost always already arrived. Worst
    /// legitimate drain observed: 0.000004s. Two REAL `claude` subscription transforms, one of them
    /// attachment-carrying: 0.000000s and 0.000003s. Output size is irrelevant -- 256 MiB of stdout still
    /// waits ~0.000001s, because the bytes were consumed while the child was alive. Nor do the hostile
    /// legitimate shapes cost the drain anything: a 3.6s trickle producer, an 8 MiB stdin the child never
    /// reads while it lingers 2s, and a SIGTERM-ignoring same-group pipe holder that must be escalated to
    /// group SIGKILL all wait ~0.000002s, because their cost is charged to the reap loop ABOVE the drains.
    ///
    /// So this bound sits ~2.5 million times above the worst measured legitimate drain. It exists only for
    /// the pathological shape `runProcess`'s doc comment describes -- a descendant that `setsid`s out of
    /// the group while holding the pipe, which no kill can reach and no EOF will ever end.
    static let drainDeadline: TimeInterval = 10

    /// The minimal env the child inherits. Everything else is dropped by construction -- this allowlist,
    /// plus derived USER/LOGNAME, is the fix for the auth traps (no `ANTHROPIC_*`, no `USE_*_OAUTH`).
    /// Mirrors the proven `subscriptionEnv()` behavior.
    static let envAllowlist = ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "TERM"]

    // MARK: - availability

    /// The file-backed Claude Code credential location. Direct catalog transport still needs this path;
    /// connection state itself is owned by `LLMProviderDetection` through `claude auth status --json`,
    /// because Claude Code may instead keep the credential in the login Keychain.
    static var credentialsPath: String { "\(NSHomeDirectory())/.claude/.credentials.json" }

    /// Locate the `claude` CLI. A LaunchAgent-run app has a minimal PATH, so we probe the known install
    /// locations by absolute path (native installer, Homebrew, /usr/local, the managed local install)
    /// rather than trusting PATH. nil = not installed.
    static func resolveBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// True when a Claude subscription transform can be attempted. The CLI owns the credential stores
    /// and method vocabulary, so this consumes the same status authority as preflight and Settings.
    static var isAvailable: Bool {
        LLMProviderDetection.observeClaude().state.canRun
    }

    // MARK: - pure pieces (unit-testable without a Claude call)

    /// The `claude -p` args for a one-shot transform. `-p` reads the already-wrapped user content from
    /// stdin (`--input-format text`). The transform instruction is read through the installed CLI's
    /// supported `--system-prompt-file` option, so neither data class appears in the process argv.
    ///
    /// THE OUTPUT FORMAT IS NOT INDEPENDENT OF THE INPUT FORMAT, and this is the fix for the reported defect:
    /// reproduced on 2026-08-12. A note carrying an attachment makes `runTransformProcess` switch the input
    /// to `stream-json` so the frames and the wrapped text can ride one user turn; the output format stayed
    /// `json`, and the CLI rejects that pair while PARSING ARGV, before any model work:
    ///
    ///     Error: --input-format=stream-json requires output-format=stream-json.
    ///
    /// That is exactly 70 bytes on stderr with exit 1 in well under a second, which is the
    /// `claude: no parseable JSON (exit 1, stderrBytes=70)` line every cloud sticky-skill run on a note with
    /// an attachment produced. It never reached Anthropic, which is why the same route, model and note
    /// succeeded from the selection hotkey (that path never carries images, so it never left `text`).
    /// `--verbose` is the CLI's own second requirement for `-p` plus `stream-json` output, and omitting it
    /// fails the same way (74 bytes) rather than degrading.
    ///
    /// `model` defaults to the compatibility Claude pin (`claude-sonnet-5`) so existing callers remain
    /// byte-identical. Explicit route bundles may pass their own hard-pinned
    /// Claude id (e.g. `claude-haiku-4-5-20251001`) here instead. `effort` is the headless CLI's `--effort`
    /// (`low`/`medium`/`high`/...); it is OMITTED when nil or empty, so the default (no `--effort`) preserves
    /// the prior behavior exactly and only the policy paths pass a level. Always an EXPLICIT model id, never
    /// an alias (the `sonnet`/`haiku` aliases lag the binary's registry — see file header).
    static func buildArgs(systemPromptFilePath: String,
                          model: String = ModeModelCatalog.claudeId, effort: String? = nil,
                          inputFormat: String = "text") -> [String] {
        let streaming = inputFormat == streamingInputFormat
        var args = [
            "-p",
            "--input-format", inputFormat,   // wrapped user content arrives on stdin
            // buffered JSON for text; the CLI-mandated matching pair when frames ride stdin
            "--output-format", streaming ? streamingInputFormat : "json",
        ]
        if streaming { args.append("--verbose") }  // the CLI's own requirement for -p + stream-json output
        args += [
            "--no-session-persistence",      // stateless, no saved session
            "--tools", "",                   // strip EVERY built-in tool: pure text transform, no tool loop
            "--system-prompt-file", systemPromptFilePath,
            "--model", model,                // explicit id (the `sonnet`/`haiku` aliases lag — see file header)
        ]
        if let effort = effort, !effort.isEmpty { args += ["--effort", effort] }
        return args
    }

    /// The one input format that carries attachment frames, and the only one whose name must also appear as
    /// the output format. Named once so the two cannot drift apart again.
    static let streamingInputFormat = "stream-json"

    /// Claude Code's streaming-input envelope allows labeled image blocks and the already-wrapped text
    /// to enter one user turn. This is used only when L11 has extracted attachment frames.
    static func multimodalInputData(userMessage: String,
                                    images: [TextTransformImage]) -> Data? {
        var content: [[String: Any]] = [["type": "text", "text": userMessage]]
        for image in images {
            content.append(["type": "text", "text": "ATTACHMENT FRAME: \(image.label)"])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType,
                    "data": image.data.base64EncodedString(),
                ],
            ])
        }
        let envelope: [String: Any] = [
            "type": "user",
            "session_id": "",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull(),
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Build the child env from a parent env by ALLOWLIST -- the auth fix. USER and LOGNAME are derived
    /// explicitly; poison vars (`SHELL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `USE_*_OAUTH`,
    /// `CLAUDE_CODE_OAUTH_TOKEN`) are excluded by construction. PATH is additionally ensured to carry the
    /// standard user bin dirs (a LaunchAgent-run app may have a bare PATH) so any helper the CLI spawns
    /// resolves; the binary itself is always invoked by absolute path. Pure (parent env in -> env out) so
    /// the selftest asserts it.
    static func buildEnv(from parent: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for k in envAllowlist where parent[k] != nil { env[k] = parent[k] }
        let user = parent["USER"] ?? parent["LOGNAME"] ?? NSUserName()
        if !user.isEmpty {
            env["USER"] = user
            env["LOGNAME"] = user
        }
        let home = parent["HOME"] ?? NSHomeDirectory()
        let needed = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var path = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        for dir in needed where !path.contains(dir) { path.append(dir) }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// Map a headless `claude -p --output-format json` stdout into a `CleanupClient.Result`. Mirrors
    /// `escalate.mjs` `parseResult`: `is_error:true` and no/empty `result` both become non-`.ok` outcomes
    /// (which the registry lands as "leave the text untouched + toast" — the house invariant). Claude output
    /// is run through the SAME `CleanupClient.asciiPunctuationNormalized` plain-ASCII choke point as every
    /// local client. Pure.
    /// The one place Claude stderr content reaches the log. The shared renderer selects only a
    /// diagnostic-looking line, redacts request-shaped content, and caps the ASCII output.
    static func diagnosticStderrHead(_ stderrText: String,
                                     sensitiveValues: [String] = []) -> String {
        let head = ProviderStderrDiagnostic.render(stderrText, sensitiveValues: sensitiveValues)
        return head.isEmpty ? "" : " stderrHead=\(head)"
    }

    static func parseResult(stdout: String, exitCode: Int32 = 0, stderrText: String = "",
                            sensitiveValues: [String] = []) -> CleanupClient.Result {
        guard let json = resultObject(stdout) else {
            Log.write("claude: no parseable JSON (exit \(exitCode), "
                + "stderrBytes=\(stderrText.utf8.count))"
                + diagnosticStderrHead(stderrText, sensitiveValues: sensitiveValues))
            return .unavailable(exitCode != 0 ? "claude exited \(exitCode)" : "no result from Claude")
        }
        if (json["is_error"] as? Bool) == true {
            let why = (json["result"] as? String) ?? (json["subtype"] as? String) ?? "unknown"
            // Provider error text can echo the request. Keep it out of both this log and the Result
            // reason, because existing landing sites log that reason again.
            Log.write("claude: provider error payload chars=\(why.count)")
            return .unavailable("Claude returned an error")
        }
        let raw = (json["result"] as? String) ?? ""
        let cleaned = CleanupClient.asciiPunctuationNormalized(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            Log.write("claude: produced empty output")
            return .badOutput("empty output")
        }
        return .ok(cleaned)
    }

    /// The object a headless run reports its OUTCOME in, whichever output format produced `stdout`.
    ///
    /// `--output-format json` prints exactly one object, so the whole string parses. The streaming pair a
    /// frame-carrying run is now required to use prints one object PER LINE - a session banner, a rate-limit
    /// event, each assistant message, and finally the same `is_error`/`result` object under
    /// `type: "result"`. Taking the FIRST object there would read the banner, find no `result` key, and
    /// report a blank transform on a run that actually succeeded; taking the whole string parses nothing at
    /// all. So the outcome is selected by name from the last line that carries it, and only then do the two
    /// legacy shapes apply. Pure.
    private static func resultObject(_ s: String) -> [String: Any]? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] { return obj }
        for line in trimmed.split(separator: "\n").reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "result" else { continue }
            return obj
        }
        // A leading warning line before a single buffered object.
        guard let brace = trimmed.firstIndex(of: "{") else { return nil }
        let tail = String(trimmed[brace...])
        return (try? JSONSerialization.jsonObject(with: Data(tail.utf8))) as? [String: Any]
    }

    // MARK: - the spawn

    struct ProcessRunResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
        let terminatedBySignal: Bool
        let leaderReaped: Bool
        let escalatedToSIGKILL: Bool
        let hadResidualProcessGroup: Bool
        let residualProcessGroup: Bool
        /// Drain evidence, added alongside the reaping evidence above rather than folded into it: the
        /// two answer different questions. `leaderReaped`/`residualProcessGroup` say whether the process
        /// TREE went away; these say whether its OUTPUT STREAMS closed. The escaped-pipe-holder shape is
        /// precisely the case where the first pair reads perfectly clean and this one does not.
        ///
        /// Ported from `CodexModelCatalogProcess`, which already reports `drainsComplete`/`stdoutEOF`/
        /// `stderrEOF` for the same reason. The one addition is `stdinWriterComplete`: that transport
        /// closes stdin synchronously, while this one writes it from a third background thread, so the
        /// writer is a drain here and needs its own flag.
        let drainsComplete: Bool
        let stdinWriterComplete: Bool
        let stdoutEOF: Bool
        let stderrEOF: Bool
    }

    private enum SpawnError: Error {
        case promptFile
        case process(String)
    }

    /// Run one Claude transform synchronously (blocks the calling thread — call OFF the main thread). Fails
    /// closed to a non-`.ok` `Result` on every error path (CLI missing, creds absent, launch failure,
    /// timeout, error JSON, empty output), so the registry never pastes empty. Both pipes are drained
    /// concurrently to avoid a stderr-buffer deadlock.
    static func spawnSync(systemPrompt: String, userMessage: String,
                          images: [TextTransformImage] = [],
                          model: String = ModeModelCatalog.claudeId, effort: String? = nil,
                          timeout: TimeInterval) -> CleanupClient.Result {
        guard let bin = resolveBinary() else {
            Log.write("claude: CLI not found (~/.local/bin, homebrew, /usr/local/bin, ~/.claude/local)")
            return .unavailable("claude CLI not found")
        }
        let connection = LLMProviderDetection.observeClaude(binary: bin).state
        guard connection.canRun else {
            Log.write("claude: auth status does not permit a subscription transform")
            switch connection {
            case .available:
                return .unavailable("Claude auth status was inconsistent")
            case .disconnected:
                return .unavailable("not signed in to the Claude subscription")
            case .unavailable(let reason):
                return .unavailable(reason)
            }
        }

        let t0 = Date()
        let run: ProcessRunResult
        do {
            run = try runTransformProcess(executable: bin, systemPrompt: systemPrompt,
                                          userMessage: userMessage, images: images,
                                          model: model, effort: effort,
                                          timeout: timeout,
                                          environment: buildEnv(from: ProcessInfo.processInfo.environment))
        } catch {
            Log.write("claude: launch failed (classified process setup error)")
            return .unavailable("launch failed")
        }

        // LEAK EVIDENCE FIRST, OUTCOME AFTER. Every branch of the cascade below returns, and two of them
        // return before `processGroupExitWasClean` is ever consulted -- so until this line existed, a
        // genuine residual process group on the timeout path was invisible in the log and the comment
        // under it described an intent the early return made unreachable. Hoisting the evidence above the
        // cascade makes it unskippable while leaving the cascade, and every outcome it returns, exactly
        // as it was: this logs, it does not decide.
        logResidualProcessGroup(run)

        // A drain that hit its deadline means an output stream never closed, so this run produced nothing
        // usable however cleanly the process tree went away. Checked BEFORE the timeout mapping because it
        // is the more specific fact and deserves the log line; both are non-`.ok` and land the same raw
        // fallback. `.timedOut` rather than `.unavailable` is deliberate: the provider was reachable and
        // very likely answered, and only `.unavailable` would bar the user's same-provider retry -- which
        // is exactly the retry that works here, because the next spawn gets a fresh pipe.
        guard run.drainsComplete else {
            logTeardown("output streams never closed within the \(Int(drainDeadline))s drain deadline "
                + "- discarding output and falling back", run)
            return .timedOut
        }

        // A watchdog group kill is a timeout however the CLI exits. Preserve the existing `.timedOut`
        // mapping for an abnormal signal, while treating a residual descendant as a fail-closed error.
        // The evidence rides this line too, because a timeout that tore down cleanly and a timeout that
        // left a pipe holder behind are the same sentence otherwise -- and the second is the bug.
        if run.timedOut || run.terminatedBySignal {
            logTeardown("timed out / killed after \(Int(timeout))s", run)
            return .timedOut
        }
        guard processGroupExitWasClean(leaderReaped: run.leaderReaped,
                                       residualProcessGroup: run.residualProcessGroup) else {
            // No log line here: `logResidualProcessGroup` above already emitted it, on this path and on
            // the two that return before ever reaching this check.
            return .unavailable("Claude process did not exit cleanly")
        }
        if run.hadResidualProcessGroup {
            Log.write("claude: cleaned transient process-group helper after leader exit")
        }
        let stdout = String(decoding: run.stdout, as: UTF8.self)
        // The whole stderr keeps the byte count exact and lets the safe renderer inspect the head.
        let stderrText = String(decoding: run.stderr, as: UTF8.self)
        let dt = Date().timeIntervalSince(t0)
        let result = parseResult(
            stdout: stdout, exitCode: run.exitCode, stderrText: stderrText,
            sensitiveValues: [systemPrompt, userMessage])
        if case .ok(let out) = result {
            let eff = (effort?.isEmpty == false) ? " effort=\(effort!)" : ""
            Log.write("claude OK [\(model)\(eff)] \(userMessage.count)->\(out.count) chars in \(String(format: "%.2f", dt))s")
        }
        return result
    }

    /// Deterministic test seam: exercise the exact prompt-file/stdin/process-group transport against a
    /// synthetic executable, without probing credentials or making a provider call.
    static func spawnSyncForTest(executable: String, systemPrompt: String, userMessage: String,
                                 model: String = ModeModelCatalog.claudeId, effort: String? = nil,
                                 timeout: TimeInterval = 5,
                                 environment: [String: String] = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]) -> CleanupClient.Result {
        do {
            let run = try runTransformProcess(executable: executable, systemPrompt: systemPrompt,
                                              userMessage: userMessage, model: model, effort: effort,
                                              timeout: timeout, environment: environment)
            // Same three shapes, same evidence, same order as `spawnSync` above -- deliberately, because
            // this seam is what a deterministic selftest can actually drive, so it is only a proxy for
            // the production path while it says what the production path says.
            logResidualProcessGroup(run)
            guard run.drainsComplete else {
                logTeardown("output streams never closed within the \(Int(drainDeadline))s drain deadline "
                    + "- discarding output and falling back", run)
                return .timedOut
            }
            if run.timedOut || run.terminatedBySignal {
                logTeardown("timed out / killed after \(Int(timeout))s", run)
                return .timedOut
            }
            guard processGroupExitWasClean(leaderReaped: run.leaderReaped,
                                           residualProcessGroup: run.residualProcessGroup) else {
                return .unavailable("test process did not exit cleanly")
            }
            return parseResult(stdout: String(decoding: run.stdout, as: UTF8.self),
                               exitCode: run.exitCode,
                               stderrText: String(decoding: run.stderr, as: UTF8.self),
                               sensitiveValues: [systemPrompt, userMessage])
        } catch {
            return .unavailable("test launch failed")
        }
    }

    /// Deterministic watchdog seam used by the focused A2 process-group fixture.
    static func runProcessForTest(executable: String, arguments: [String], timeout: TimeInterval,
                                  grace: TimeInterval = 0.25) -> ProcessRunResult? {
        try? runProcess(executable: executable, arguments: arguments, stdin: Data(),
                        environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
                        timeout: timeout, grace: grace)
    }

    /// A short-lived helper observed after the leader exits is acceptable only when the bounded cleanup
    /// actually clears the group. An unreaped leader or a final surviving descendant still fails closed.
    static func processGroupExitWasClean(leaderReaped: Bool, residualProcessGroup: Bool) -> Bool {
        leaderReaped && !residualProcessGroup
    }

    /// The DRAIN half of the same fail-closed contract, deliberately a sibling of the predicate above
    /// rather than folded into it: they judge different evidence. That one asks whether the process TREE
    /// went away; this one asks whether its OUTPUT STREAMS closed. The escaped-pipe-holder shape is
    /// exactly the case where the first reads perfectly clean and this one does not, which is why one
    /// cannot stand in for the other.
    ///
    /// ALL THREE must finish. A stream still open at the deadline has delivered nothing trustworthy, and
    /// a half-delivered transform landing mid-sentence in a focused document is worse than no transform,
    /// so any unfinished drain is a hard failure however clean the teardown looked.
    static func drainsWereComplete(stdinWriterComplete: Bool, stdoutEOF: Bool, stderrEOF: Bool) -> Bool {
        stdinWriterComplete && stdoutEOF && stderrEOF
    }

    /// Every teardown fact this run produced, rendered once, so a non-`.ok` outcome carries the SAME
    /// evidence whichever branch returned it. Reap evidence and drain evidence together by design: that
    /// pair is what separates "killed cleanly and drained" from "killed, but something escaped still
    /// holding a pipe", and in exactly that case either half read on its own looks fine. Pure, and it
    /// renders flags only -- never a byte of the transform, so it is safe on the privacy-checked log.
    static func teardownEvidence(_ run: ProcessRunResult) -> String {
        "leaderReaped=\(run.leaderReaped), residual=\(run.residualProcessGroup), "
            + "transientHelper=\(run.hadResidualProcessGroup), sigkill=\(run.escalatedToSIGKILL), "
            + "drainsComplete=\(run.drainsComplete), stdinWriter=\(run.stdinWriterComplete), "
            + "stdoutEOF=\(run.stdoutEOF), stderrEOF=\(run.stderrEOF)"
    }

    /// The single place a non-`.ok` teardown is described, shared by `spawnSync` and its deterministic
    /// seam so a selftest driving the seam pins production's own rendering rather than a copy of it.
    /// Logs and nothing else: it returns no value and every caller keeps the outcome it already chose.
    private static func logTeardown(_ reason: String, _ run: ProcessRunResult) {
        Log.write("claude: \(reason) - \(teardownEvidence(run))")
    }

    /// A residual process group is a LEAK, and it has to be visible however the run ended. Callers put
    /// this ABOVE their outcome cascade rather than inside it: two branches of that cascade return before
    /// `processGroupExitWasClean` is ever consulted, which is precisely how a genuine leak on the timeout
    /// path used to produce no log line at all. Self-suppressing on the same predicate the cascade uses,
    /// so a clean teardown still adds nothing.
    private static func logResidualProcessGroup(_ run: ProcessRunResult) {
        guard !processGroupExitWasClean(leaderReaped: run.leaderReaped,
                                        residualProcessGroup: run.residualProcessGroup) else { return }
        logTeardown("process group did not exit cleanly", run)
    }

    private static func runTransformProcess(executable: String, systemPrompt: String,
                                            userMessage: String,
                                            images: [TextTransformImage] = [],
                                            model: String, effort: String?,
                                            timeout: TimeInterval,
                                            environment: [String: String]) throws -> ProcessRunResult {
        let promptDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-claude-\(UUID().uuidString)", isDirectory: true)
        let promptFile = promptDir.appendingPathComponent("system-prompt.txt")
        do {
            try FileManager.default.createDirectory(at: promptDir, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            _ = chmod(promptDir.path, 0o700)
            guard FileManager.default.createFile(atPath: promptFile.path,
                                                 contents: Data(systemPrompt.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw SpawnError.promptFile
            }
            _ = chmod(promptFile.path, 0o600)
        } catch {
            try? FileManager.default.removeItem(at: promptDir)
            throw SpawnError.promptFile
        }
        defer { try? FileManager.default.removeItem(at: promptDir) }

        let inputFormat = images.isEmpty ? "text" : "stream-json"
        guard let stdin = images.isEmpty
                ? Data(userMessage.utf8)
                : multimodalInputData(userMessage: userMessage, images: images) else {
            throw SpawnError.process("multimodal input")
        }
        let args = buildArgs(systemPromptFilePath: promptFile.path, model: model, effort: effort,
                             inputFormat: inputFormat)
        return try runProcess(executable: executable, arguments: args, stdin: stdin,
                              environment: environment, timeout: timeout, grace: 2)
    }

    /// Spawn one child into its OWN process group, bound by `timeout`, then tear the whole group down.
    ///
    /// WHAT IS PROVEN, and how. Measured 2026-08-19 by driving this function against hostile fixtures and
    /// judging survivorship with `ps` AFTER the host process had exited, so the verdict never came from
    /// `leaderReaped` / `residualProcessGroup` (full method + numbers:
    /// `Projects/viddydictate/wiki/reference/process-group-reaping.md` in Ben's vault). Every case that
    /// stays inside the group is cleaned, with nothing surviving: clean exit (24 ms); timeout with a
    /// cooperative leader (352 ms); timeout with a leader that IGNORES SIGTERM, escalated to group SIGKILL
    /// (834 ms); timeout with leader AND descendant both ignoring SIGTERM (812 ms); and a clean leader exit
    /// leaving a SIGTERM-ignoring same-group pipe holder, where `hadResidualProcessGroup` fires, the group
    /// is killed, and stdout is still delivered intact (116 ms). The real `claude` CLI behaves: driven
    /// through `spawnSync` and killed at a 9 s timeout while fully booted, 27 distinct processes were
    /// tracked in the spawned children's groups -- the CLI, its `security` keychain helpers, its node MCP
    /// servers, `private-fs`, a `sh -c ps aux | grep` and its children -- every one of them inside the
    /// leader's group, and every one gone afterwards.
    ///
    /// THE ONE THING THAT DEFEATS THE KILL is a descendant that leaves the process group (`setsid`) while
    /// still holding stdout or stderr. `kill(-pid, ...)` cannot reach it by construction, and
    /// `processGroupIsEmpty` then reports the group EMPTY so the teardown reads perfectly clean while the
    /// pipe is still held. Reproduced deterministically and pinned with `sample`: this thread parked in
    /// `semaphore_wait_trap` under `runProcess`, both reader threads in `read()` under
    /// `readDataToEndOfFile`, identical across samples 12 s apart at 0% CPU, with the escaped descendant
    /// alive at ppid 1. No `claude` invocation has been observed doing this, but a user-scope MCP server
    /// or hook that daemonises would.
    ///
    /// `timeout` and `grace` bound the KILL; they do not bound the DRAIN, so the drain carries its own
    /// separate `drainDeadline` (see that constant for the measurement behind the number). The kill can
    /// no longer be defeated into an unbounded park: the drains now expire, the run is reported
    /// `drainsComplete: false` with nothing usable in `stdout`, and `spawnSync` fails closed to the raw
    /// fallback. Permanent gate: `--text-transform-selftest --cloud-drain-deadlock-repro`, whose
    /// `escaped` case is exactly this shape and was red until the drains were bounded.
    ///
    /// THE `ECHILD` BRANCH (`waited < 0` in the loops below leaves `reaped` false) IS NOT REACHABLE HERE.
    /// It needs a competing reaper, and there is none: nothing in this app touches SIGCHLD, launchd hands a
    /// LaunchAgent SIG_DFL (measured), and a `Foundation.Process` running concurrently does not steal this
    /// child (measured). Forced with SIGCHLD set to SIG_IGN it degrades classification, not cleanup: a
    /// successful run is reported `timedOut=true, leaderReaped=false` with its stdout still captured and the
    /// group still empty. Fails closed, so it is a wrong reason rather than a leak.
    private static func runProcess(executable: String, arguments: [String], stdin: Data,
                                   environment: [String: String], timeout: TimeInterval,
                                   grace: TimeInterval) throws -> ProcessRunResult {
        let input = Pipe(), output = Pipe(), error = Pipe()
        let inputRead = input.fileHandleForReading.fileDescriptor
        let inputWrite = input.fileHandleForWriting.fileDescriptor
        let outputRead = output.fileHandleForReading.fileDescriptor
        let outputWrite = output.fileHandleForWriting.fileDescriptor
        let errorRead = error.fileHandleForReading.fileDescriptor
        let errorWrite = error.fileHandleForWriting.fileDescriptor
        _ = fcntl(inputWrite, F_SETNOSIGPIPE, 1)

        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0,
              posix_spawn_file_actions_init(&actions) == 0 else {
            throw SpawnError.process("spawn init")
        }
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, inputRead, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputWrite, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorWrite, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, inputWrite) == 0,
              posix_spawn_file_actions_addclose(&actions, outputRead) == 0,
              posix_spawn_file_actions_addclose(&actions, errorRead) == 0 else {
            throw SpawnError.process("spawn config")
        }

        var pid: pid_t = 0
        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let spawnStatus = withCStringArray(argv) { argvPointers in
            withCStringArray(envp) { envPointers in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointers, envPointers)
            }
        }
        guard spawnStatus == 0 else { throw SpawnError.process("spawn \(spawnStatus)") }
        _ = setpgid(pid, pid) // harmless if the atomic spawn attribute already won the race

        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        error.fileHandleForWriting.closeFile()

        // The drains write into a LOCKED capture rather than into captured locals. Once the waits below
        // can expire, an abandoned reader thread is still parked in `read()` and will assign its result
        // whenever the pipe finally closes -- possibly never, possibly long after this frame has read it.
        // Unsynchronised, that is a genuine data race on `Data`, not merely a stale read. Same reason
        // `CodexModelCatalogProcess` accumulates its drains under `stderrLock`/`outputCondition`.
        let capture = DrainCapture()
        let writerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
            writerDone.signal()
        }
        let outputDone = DispatchSemaphore(value: 0), errorDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            capture.setStdout(output.fileHandleForReading.readDataToEndOfFile())
            outputDone.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            capture.setStderr(error.fileHandleForReading.readDataToEndOfFile())
            errorDone.signal()
        }

        var status: Int32 = 0
        var reaped = false
        var timedOut = false
        var escalatedToSIGKILL = false
        let deadline = Date().addingTimeInterval(max(0.01, timeout))
        while Date() < deadline {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; break }
            if waited < 0 && errno != EINTR { break }
            usleep(20_000)
        }

        if !reaped {
            timedOut = true
            _ = kill(-pid, SIGTERM)
            let graceDeadline = Date().addingTimeInterval(max(0, grace))
            while Date() < graceDeadline {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { reaped = true }
                if processGroupIsEmpty(pid) && reaped { break }
                usleep(20_000)
            }
            if !processGroupIsEmpty(pid) {
                escalatedToSIGKILL = true
                _ = kill(-pid, SIGKILL)
            }
            if !reaped {
                while true {
                    let waited = waitpid(pid, &status, 0)
                    if waited == pid { reaped = true; break }
                    if waited < 0 && errno != EINTR { break }
                }
            }
        }

        // A CLI may briefly leave a same-group helper behind after its leader exits. Clean the group so
        // pipe drains finish and the next transform never inherits an orphan. `hadResidual` records that
        // first observation for diagnostics; `residual` is the fail-closed post-cleanup invariant.
        let hadResidual = !processGroupIsEmpty(pid)
        var residual = hadResidual
        if residual {
            _ = kill(-pid, SIGTERM)
            usleep(50_000)
            if !processGroupIsEmpty(pid) {
                escalatedToSIGKILL = true
                _ = kill(-pid, SIGKILL)
            }
            for _ in 0..<25 where !processGroupIsEmpty(pid) { usleep(20_000) }
            residual = !processGroupIsEmpty(pid)
        }

        // BOUND THE DRAINS. Everything above bounds the KILL; until now nothing bounded these, so a
        // descendant holding the pipe outside the group parked this thread permanently. ONE shared
        // absolute deadline across all three waits, never three independent budgets -- three would let
        // the worst case reach 3x the bound and would make the number mean something other than what it
        // says. Each wait records its own EOF, exactly as the Codex transport does, so a partial failure
        // is diagnosable rather than a single opaque flag.
        let drainLimit = DispatchTime.now() + drainDeadline
        let stdinWriterComplete = writerDone.wait(timeout: drainLimit) == .success
        let stdoutEOF = outputDone.wait(timeout: drainLimit) == .success
        let stderrEOF = errorDone.wait(timeout: drainLimit) == .success
        let drainsComplete = drainsWereComplete(stdinWriterComplete: stdinWriterComplete,
                                                stdoutEOF: stdoutEOF, stderrEOF: stderrEOF)

        // NEVER HAND BACK A PARTIAL STREAM. A truncated transform landing mid-sentence in a focused
        // document is worse than no transform, so a stream that never reached EOF yields nothing and the
        // caller fails closed to the raw fallback. With `readDataToEndOfFile` an unfinished read has
        // produced no bytes at all yet, so today this discards nothing; it is written explicitly so the
        // guarantee survives any future move to an incremental reader.
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return ProcessRunResult(exitCode: exitCode,
                                stdout: stdoutEOF ? capture.stdout : Data(),
                                stderr: stderrEOF ? capture.stderr : Data(),
                                timedOut: timedOut, terminatedBySignal: signal != 0,
                                leaderReaped: reaped, escalatedToSIGKILL: escalatedToSIGKILL,
                                hadResidualProcessGroup: hadResidual,
                                residualProcessGroup: residual,
                                drainsComplete: drainsComplete,
                                stdinWriterComplete: stdinWriterComplete,
                                stdoutEOF: stdoutEOF, stderrEOF: stderrEOF)
    }

    /// The two reader threads' landing site. A reader abandoned at the drain deadline is still parked in
    /// `read()` and may assign here at any later time, so every access is locked and the late write simply
    /// lands somewhere nobody reads again.
    private final class DrainCapture {
        private let lock = NSLock()
        private var capturedStdout = Data()
        private var capturedStderr = Data()

        func setStdout(_ data: Data) { lock.lock(); capturedStdout = data; lock.unlock() }
        func setStderr(_ data: Data) { lock.lock(); capturedStderr = data; lock.unlock() }
        var stdout: Data { lock.lock(); defer { lock.unlock() }; return capturedStdout }
        var stderr: Data { lock.lock(); defer { lock.unlock() }; return capturedStderr }
    }

    private static func processGroupIsEmpty(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(-pid, 0) != 0 && errno == ESRCH
    }

    private static func withCStringArray<R>(_ strings: [String],
                                            _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    // MARK: - async entry (mirrors CleanupClient.cleanup / EmailClient.email)

    /// Run a Claude transform, calling back with a `CleanupClient.Result` on a background queue (the
    /// registry hops to main before landing). The caller supplies the augmented system prompt and the
    /// mode-appropriately-wrapped user message, exactly as it would for the local clients. `model`/`effort`
    /// default to the per-mode Sonnet 5 pin (existing callers unchanged); explicit route bundles pass their
    /// own hard-pinned Claude arm.
    static func transform(systemPrompt: String, userMessage: String,
                          images: [TextTransformImage] = [],
                          model: String = ModeModelCatalog.claudeId, effort: String? = nil,
                          timeout: TimeInterval = defaultTimeout,
                          completion: @escaping (CleanupClient.Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(spawnSync(systemPrompt: systemPrompt, userMessage: userMessage,
                                 images: images,
                                 model: model, effort: effort, timeout: timeout))
        }
    }
}
