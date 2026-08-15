import Darwin
import Foundation

/// Pure/scratch-only C1 coverage. It injects a fake containment runner and synthetic canaries; no
/// installed Codex process, dedicated production home, credential, preference, provider, or network is
/// consulted.
enum CodexProviderSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate production Codex provider — synthetic selftest ===")
        let reporter = SelfTestReporter()

        checkConnectionContract(reporter.record)
        checkSmokeDiagnostics(reporter.record)
        checkPrivateContainedTransport(reporter.record)
        checkFailClosedMapping(reporter.record)
        checkProductionDefaults(reporter.record)

        print(reporter.passed ? "[codex-provider-selftest] PASS" : "[codex-provider-selftest] FAIL")
        return reporter.passed
    }

    private static func checkConnectionContract(_ check: (String, Bool) -> Void) {
        print("--- dedicated-home status and device-auth contract ---")
        check("exact ChatGPT subscription status is connected",
              CodexProviderRuntime.parseConnectionStateForTest(
                status: 0, stdout: "Logged in using ChatGPT\n") == .connected)
        check("exact missing-login status is disconnected",
              CodexProviderRuntime.parseConnectionStateForTest(
                status: 1, stdout: "", stderr: "Not logged in\n") == .disconnected)
        let apiKey = CodexProviderRuntime.parseConnectionStateForTest(
            status: 0, stdout: "Logged in using an API key\n")
        check("API-key authentication is rejected rather than treated as connected",
              unavailable(apiKey)?.contains("API-key") == true)
        check("device login can only invoke the subscription OAuth flag",
              CodexProviderRuntime.deviceLoginArguments == ["login", "--device-auth"])

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddydictate-codex-c1-env-\(UUID().uuidString)", isDirectory: true)
        let paths = CodexIsolationFoundation.scratchPaths(root: root)
        let env = CodexProviderRuntime.deviceLoginEnvironment(paths: paths)
        check("device-login environment has no API-key/token fallback",
              env["OPENAI_API_KEY"] == nil && env["CODEX_API_KEY"] == nil
                && env["CODEX_ACCESS_TOKEN"] == nil && env["CODEX_HOME"] == paths.home.path)

        checkDeviceAuthorizationParsing(check)
    }

    /// The predecessor of this block asserted against a hand-written one-line string
    /// ("Open https://... and enter ABCD-EFGH"): plain ASCII, no colour escapes, code groups of exactly
    /// four. It passed while production could not parse a single real code, because codex-cli colourises
    /// the block and now issues 4-then-5 codes. The primary fixture below is therefore a VERBATIM
    /// capture of real `codex login --device-auth` output (0.146.0-alpha.3.1, TERM=dumb,
    /// stdin=/dev/null), escapes and all. Recapture it, do not hand-edit it, when the vendor changes.
    private static func checkDeviceAuthorizationParsing(_ check: (String, Bool) -> Void) {
        let esc = "\u{1b}"
        let liveCapture = """

        Welcome to Codex [v\(esc)[90m0.146.0-alpha.3.1\(esc)[0m]
        \(esc)[90mOpenAI's command-line coding agent\(esc)[0m

        Follow these steps to sign in with ChatGPT using device code authorization:

        1. Open this link in your browser and sign in to your account
           \(esc)[94mhttps://auth.openai.com/codex/device\(esc)[0m

        2. Enter this one-time code \(esc)[90m(expires in 15 minutes)\(esc)[0m
           \(esc)[94mY8OL-V15MK\(esc)[0m

        \(esc)[90mContinue only if you started this login in Codex. If a website or another person gave you this code, cancel.\(esc)[0m

        """
        let live = CodexProviderRuntime.parseDeviceAuthorizationInfo(Data(liveCapture.utf8))
        check("real colourised vendor device-auth output yields the allowlisted URL",
              live?.verificationURL?.host == "auth.openai.com")
        check("real colourised vendor device-auth output yields the one-time code",
              live?.userCode == "Y8OL-V15MK")

        // Each factor in isolation, so a future regression says WHICH half broke.
        check("a colour escape before the code does not defeat the code match",
              CodexProviderRuntime.parseDeviceAuthorizationInfo(
                Data("   \(esc)[94mABCD-EFGH\(esc)[0m\n".utf8))?.userCode == "ABCD-EFGH")
        check("a code whose groups are not both four characters is still matched",
              CodexProviderRuntime.parseDeviceAuthorizationInfo(
                Data("   ABCD-EFGHI\n".utf8))?.userCode == "ABCD-EFGHI")
        check("escape stripping leaves escape-free text untouched",
              CodexProviderRuntime.stripANSIEscapes("plain ABCD-EFGH text") == "plain ABCD-EFGH text")

        // Bounds that must survive the widened shape.
        check("unrelated URLs are not offered by the Connect flow",
              CodexProviderRuntime.parseDeviceAuthorizationInfo(
                Data("Open https://example.com and enter ABCD-EFGH".utf8))?.verificationURL == nil)
        // Both negatives carry a valid URL on purpose, so the parse returns a non-nil result and the
        // assertion is really about `userCode` rather than passing because everything was nil.
        let bannerOnly = CodexProviderRuntime.parseDeviceAuthorizationInfo(Data("""
        Welcome to Codex [v0.146.0-alpha.3.1]
        https://auth.openai.com/codex/device
        """.utf8))
        check("the vendor version banner is not mistaken for a one-time code",
              bannerOnly?.verificationURL != nil && bannerOnly?.userCode == nil)
        let longToken = CodexProviderRuntime.parseDeviceAuthorizationInfo(Data("""
        trace ABCD-EFGH-IJKLMNOPQ
        https://auth.openai.com/codex/device
        """.utf8))
        check("a fragment of a longer hyphenated token is not offered as a code",
              longToken?.verificationURL != nil && longToken?.userCode == nil)
        check("output carrying neither a URL nor a code yields no instructions at all",
              CodexProviderRuntime.parseDeviceAuthorizationInfo(
                Data("Welcome to Codex\nOpenAI's command-line coding agent\n".utf8)) == nil)
    }

    private static func checkSmokeDiagnostics(_ check: (String, Bool) -> Void) {
        print("--- provider smoke connection diagnostics ---")
        let helper = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ViddyDictate.app/Contents/Helpers/CodexProviderSmoke")
        let run = CloudCleanupClient.runProcessForTest(
            executable: helper.path, arguments: ["--diagnostics-selftest"], timeout: 5)
        let output = run.map { String(decoding: $0.stdout + $0.stderr, as: UTF8.self) } ?? ""
        let completed = run.map {
            !$0.timedOut && !$0.terminatedBySignal && $0.exitCode == 0
                && CloudCleanupClient.processGroupExitWasClean(
                    leaderReaped: $0.leaderReaped,
                    residualProcessGroup: $0.residualProcessGroup)
        } ?? false
        check("provider smoke connected state emits no failure lines",
              completed && output.contains(
                "[codex-provider-smoke-selftest][PASS] connected produces no failure lines"))
        check("provider smoke disconnected state emits only the generic failure",
              completed && output.contains(
                "[codex-provider-smoke-selftest][PASS] disconnected produces the generic line only"))
        check("provider smoke unavailable state includes its boundary cause",
              completed && output.contains(
                "[codex-provider-smoke-selftest][PASS] unavailable preserves the generic line and emits the boundary cause"))
        check("provider smoke rejected runtime outcome includes its exact cause",
              completed && output.contains(
                "[codex-provider-smoke-selftest][PASS] rejected runtime outcome includes exact classification cause"))
        check("provider smoke preserves explicit opaque model/effort pair inputs",
              completed && output.contains(
                "[codex-provider-smoke-selftest][PASS] explicit opaque pair inputs are preserved exactly"))
        check("provider smoke all-route mode derives every distinct canonical shipped pair",
              completed && output.contains(
                "[codex-provider-smoke-selftest][PASS] all-route mode derives every distinct canonical shipped pair"))
        check("provider smoke refuses ambiguous all-route plus explicit-pair input",
              completed && output.contains(
                "[codex-provider-smoke-selftest][PASS] all-route and explicit-pair modes cannot be mixed"))
    }

    private static func checkPrivateContainedTransport(
        _ check: (String, Bool) -> Void
    ) {
        print("--- generated profile + stdin-only contained transport ---")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddydictate-codex-c1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let runner = root.appendingPathComponent("fake-containment-runner")
            let script = """
            #!/bin/sh
            home=""
            image=""
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--home" ]; then home="$argument"; fi
              if [ "$previous" = "--image" ]; then image="$argument"; fi
              previous="$argument"
            done
            [ -n "$home" ] || exit 3
            /usr/bin/printf '%s\n' "$@" > "$home/captured-argv"
            if [ -n "$image" ]; then
              /bin/cat "$image" > "$home/captured-image"
              /usr/bin/stat -f '%Lp' "$image" > "$home/captured-image-mode"
            fi
            /bin/cat > "$home/captured-stdin"
            /usr/bin/printf '%s\n' \
              '{"type":"thread.started","thread_id":"synthetic"}' \
              '{"type":"turn.started"}' \
              '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"result\\":\\"synthetic-ok\\"}"}}' \
              '{"type":"turn.completed"}'
            """
            try Data(script.utf8).write(to: runner)
            _ = chmod(runner.path, 0o700)

            let paths = CodexIsolationFoundation.scratchPaths(root: root)
            let promptCanary = "SYNTHETIC_DEVELOPER_\(UUID().uuidString)"
            let inputCanary = "SYNTHETIC_INPUT_\(UUID().uuidString)"
            let imageBytes = Data([0x89, 0x50, 0x4e, 0x47])
            let request = CodexRuntimeRequest(
                model: "gpt-c1-fixture",
                effort: "medium",
                developerInstructions: promptCanary,
                userMessage: "<<<NOTES>>>\n\(inputCanary)\n<<<END_NOTES>>>",
                envelopeVersion: "viddydictate-c1-fixture-v1",
                timeout: 5,
                images: [CodexRuntimeImage(
                    data: imageBytes, mediaType: "image/png", label: "fixture.png [still]")])
            let outcome = CodexProviderRuntime.executeForTest(
                request, paths: paths, runnerPath: runner.path)
            let success: CodexRuntimeSuccess?
            if case .success(let value) = outcome { success = value } else { success = nil }
            check("contained provider returns one strict schema-valid result",
                  success?.result == "synthetic-ok")

            let argvURL = paths.home.appendingPathComponent("captured-argv")
            let stdinURL = paths.home.appendingPathComponent("captured-stdin")
            let argv = try String(contentsOf: argvURL, encoding: .utf8)
            let stdin = try String(contentsOf: stdinURL, encoding: .utf8)
            check("input and effective developer prompt are absent from runner argv",
                  !argv.contains(inputCanary) && !argv.contains(promptCanary))
            check("model and effort ride only the hashed profile, not runner argv",
                  !argv.contains("gpt-c1-fixture") && !argv.contains("medium"))
            check("the route wrapper and app-owned image label stay inside the fixed untrusted stdin fence",
                  stdin == "<<<TRANSCRIPT>>>\n\(request.userMessage)\n\n"
                    + "ATTACHMENT FRAME 1: fixture.png [still]\n<<<END_TRANSCRIPT>>>\n")
            let capturedImage = try Data(contentsOf: paths.home.appendingPathComponent("captured-image"))
            let capturedMode = try String(
                contentsOf: paths.home.appendingPathComponent("captured-image-mode"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            check("Codex image bytes ride one bounded app-staged file in the same runner call",
                  argv.contains("--image\nvd-input-image-01.png")
                  && capturedImage == imageBytes && capturedMode == "400")
            check("Codex app-staged image is removed after the contained call",
                  !FileManager.default.fileExists(
                    atPath: paths.cwd.appendingPathComponent("vd-input-image-01.png").path))

            let argvLines = argv.split(separator: "\n").map(String.init)
            let profileName = value(after: "--profile", in: argvLines)
            let profileURL = profileName.map {
                paths.home.appendingPathComponent("\($0).config.toml")
            }
            let profileText = profileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            check("runner receives only a complete content-hashed profile identity",
                  profileName == success.map { "route-\($0.profileHash)" })
            check("canonical profile owns exact model, effort, prompt, and envelope bytes",
                  profileText.contains("model = \"gpt-c1-fixture\"")
                    && profileText.contains("model_reasoning_effort = \"medium\"")
                    && profileText.contains("developer_instructions = \"\(promptCanary)\"")
                    && profileText.contains("viddydictate-c1-fixture-v1"))
            if let profileURL {
                var st = stat()
                let modeOK = lstat(profileURL.path, &st) == 0 && (st.st_mode & 0o777) == 0o400
                check("generated content-hashed profile is immutable mode 0400", modeOK)
            } else {
                check("generated content-hashed profile is immutable mode 0400", false)
            }
        } catch {
            check("synthetic contained transport fixture setup", false)
        }
    }

    private static func checkFailClosedMapping(_ check: (String, Bool) -> Void) {
        print("--- strict JSONL/schema/exit failure mapping ---")
        let valid = """
        {"type":"thread.started","thread_id":"synthetic"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"{\\"result\\":\\"clean\\"}"}}
        {"type":"turn.completed"}
        """
        let tool = valid.replacingOccurrences(
            of: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{\\\"result\\\":\\\"clean\\\"}\"}}",
            with: "{\"type\":\"item.completed\",\"item\":{\"type\":\"todo_list\"}}")
        let partial = valid.replacingOccurrences(of: "{\"type\":\"turn.completed\"}", with: "")
        check("tool/bookkeeping JSONL is rejected",
              isRejected(CodexProviderRuntime.classifyCapturedForTest(
                status: 0, stdout: Data(tool.utf8))))
        check("partial JSONL is rejected",
              isRejected(CodexProviderRuntime.classifyCapturedForTest(
                status: 0, stdout: Data(partial.utf8))))
        check("nonzero contained exit never accepts buffered output",
              isUnavailable(CodexProviderRuntime.classifyCapturedForTest(
                status: 9, stdout: Data(valid.utf8))))
        if case .timedOut = CodexProviderRuntime.classifyCapturedForTest(
            status: 124, stdout: Data(valid.utf8)) {
            check("runner watchdog timeout discards every partial/final buffer", true)
        } else {
            check("runner watchdog timeout discards every partial/final buffer", false)
        }
    }

    private static func checkProductionDefaults(_ check: (String, Bool) -> Void) {
        let installed = [LLMRouteID.cleanupL1, .cleanupL2, .cleanupL3, .promptPrep, .email,
                         .custom("fixture"), .searchLocalSynth, .searchGeminiSynth]
        check("production installs only complete explicit Codex route defaults",
              installed.allSatisfy {
                  guard let bundle = LLMProviderDefaults.testedBundle(for: .codex, route: $0) else {
                      return false
                  }
                  return !bundle.modelID.isEmpty && bundle.effort != nil
                    && bundle.basePromptHash?.count == 64
                    && bundle.envelopeVersion == LLMProviderDefaults.ratifiedCodexEnvelopeVersion
              })
        let rescueRoutes: [LLMRouteID] = [.cleanupL3, .promptPrep, .email]
        check("I1 sealed texts generate exact content-hashed developer_instructions profiles",
              rescueRoutes.allSatisfy { route in
                  guard let bundle = LLMProviderDefaults.testedBundle(for: .codex, route: route),
                        let effort = bundle.effort,
                        let text = CodexRatifiedPromptDefaults.sealedDeveloperInstructions(for: route),
                        let variant = CodexRatifiedPromptDefaults.variant(for: route),
                        let profile = try? CodexIsolationFoundation.routeProfile(
                            developerInstructions: text, model: bundle.modelID, effort: effort,
                            envelopeVersion: bundle.envelopeVersion ?? "") else { return false }
                  let profileText = String(decoding: profile.bytes, as: UTF8.self)
                  return CodexIsolationFoundation.sha256Hex(Data(text.utf8)) == variant.contentHash
                    && profile.name == "route-\(profile.hash)"
                    && profileText.contains(
                        "developer_instructions = \(CodexIsolationFoundation.tomlString(text))")
                    && !profileText.contains("AGENTS.md")
                    && !profileText.contains("model_instructions_file")
              })
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func unavailable(_ state: CodexConnectionState) -> String? {
        if case .unavailable(let reason) = state { return reason }
        return nil
    }

    private static func isRejected(_ outcome: CodexRuntimeOutcome) -> Bool {
        if case .rejected = outcome { return true }
        return false
    }

    private static func isUnavailable(_ outcome: CodexRuntimeOutcome) -> Bool {
        switch outcome {
        case .unavailable, .processFailure: return true
        default: return false
        }
    }
}
