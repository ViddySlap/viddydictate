import Foundation

/// Synthetic coverage for installed Local model discovery. No LM Studio process, model files,
/// preferences, or network service are consulted.
enum LMStudioModelCatalogSelfTest {
    static func run() -> Bool {
        print("=== LM Studio installed-model catalog fixture selftest ===")
        let reporter = SelfTestReporter()

        let fixture = """
        [
          {
            "type": "llm",
            "modelKey": "vendor/alpha-model",
            "displayName": "Alpha Model",
            "sizeBytes": 4250000000
          },
          {
            "type": "embedding",
            "modelKey": "vendor/embed-model",
            "displayName": "Embedding Model"
          },
          {
            "type": "vlm",
            "modelKey": "vendor/large-vlm",
            "displayName": "Large Vision",
            "sizeBytes": 8000000000,
            "vision": null
          },
          {
            "type": "vlm",
            "modelKey": "vendor/small-vlm",
            "displayName": "Small Vision",
            "sizeBytes": 3000000000,
            "vision": null
          },
          {
            "type": "llm",
            "modelKey": "vendor/beta-model",
            "displayName": "   "
          },
          {
            "type": "llm",
            "modelKey": "vendor/gamma-model",
            "displayName": "Gamma Model",
            "sizeBytes": "unknown"
          },
          {
            "type": "llm",
            "modelKey": "vendor/delta-model",
            "displayName": "Delta Model",
            "sizeBytes": -1
          },
          {
            "type": "llm",
            "modelKey": "vendor/alpha-model",
            "displayName": "Duplicate Alpha"
          },
          {
            "type": "llm",
            "modelKey": "   ",
            "displayName": "No Identifier"
          }
        ]
        """
        let parsed = LMStudioModelCatalog.parse(Data(fixture.utf8))
        reporter.record(
            "lms ls parser preserves reported LLM order while filtering embeddings, blanks, and duplicates",
            parsed == [
                LMStudioModelOption(modelID: "vendor/alpha-model", label: "Alpha Model (4.25 GB)"),
                LMStudioModelOption(modelID: "vendor/beta-model", label: "beta-model"),
                LMStudioModelOption(modelID: "vendor/gamma-model", label: "Gamma Model"),
                LMStudioModelOption(modelID: "vendor/delta-model", label: "Delta Model"),
            ])
        reporter.record(
            "missing, unparseable, or invalid size metadata keeps today's model label and row",
            parsed?.dropFirst().map(\.label) == ["beta-model", "Gamma Model", "Delta Model"])
        reporter.record(
            "discovered installed models replace rather than merge the hardcoded fallback",
            LMStudioModelCatalog.pickerOptions(discovered: parsed) == parsed)

        let fallbackIDs = LMStudioModelCatalog.pickerOptions(discovered: nil).map(\.modelID)
        reporter.record(
            "unavailable discovery falls back to the existing non-empty local model catalog",
            !fallbackIDs.isEmpty
                && fallbackIDs == ModeModelCatalog.localModels.map(\.modelID))
        reporter.record(
            "an empty live response also keeps the Local dropdown non-empty",
            LMStudioModelCatalog.pickerOptions(discovered: []).map(\.modelID) == fallbackIDs)
        reporter.record(
            "malformed provider JSON is unavailable rather than an empty authoritative catalog",
            LMStudioModelCatalog.parse(Data("{not-json".utf8)) == nil)
        reporter.record(
            "production discovery lists all installed LLMs rather than the loaded working set",
            ModelResidency.availableModelArguments == ["ls", "--llm", "--json"])
        reporter.record(
            "smallest vision helper is selected by on-disk size when the provider types rows vlm",
            LMStudioModelCatalog.smallestVisionModel(
                in: LMStudioModelCatalog.parseInstalled(Data(fixture.utf8)))?.modelID
                == "vendor/small-vlm")

        // REGRESSION PIN. The shape below is the real `lms ls --llm --json` on the target
        // machine, measured 2026-08-02: EVERY installed model is typed `llm` and vision capability is
        // answered by the boolean `vision` field. The original hand-authored fixture above asserted the
        // opposite world (`type: "vlm"` with `"vision": null`), so a `type == "vlm"`-only selector passed
        // the suite while selecting nothing in production — Note to Handoff's local sanity pass could
        // never run once. Either marker must be sufficient, and this fixture is the one that proves it.
        let liveShapedFixture = """
        [
          {"type":"llm","modelKey":"qwen/qwen3.6-35b-a3b","displayName":"Qwen3.6 35B",
           "sizeBytes":20430000000,"vision":true},
          {"type":"llm","modelKey":"qwen2.5-coder-7b-instruct","displayName":"Qwen2.5 Coder 7B",
           "sizeBytes":4680000000,"vision":false},
          {"type":"llm","modelKey":"google_gemma-3-4b-it-qat","displayName":"Gemma 3 4B",
           "sizeBytes":3230000000,"vision":true},
          {"type":"llm","modelKey":"qwen/qwen3-vl-2b","displayName":"Qwen3 VL 2B",
           "sizeBytes":2660000000,"vision":true},
          {"type":"llm","modelKey":"llama-3.2-1b-instruct","displayName":"Llama 3.2 1B",
           "sizeBytes":710000000,"vision":false},
          {"type":"embedding","modelKey":"text-embedding-bge-m3","displayName":"BGE M3",
           "sizeBytes":630000000,"vision":null}
        ]
        """
        let liveShaped = LMStudioModelCatalog.parseInstalled(Data(liveShapedFixture.utf8))
        reporter.record(
            "vision-capable rows are found when the provider types them llm and flags vision=true",
            LMStudioModelCatalog.smallestVisionModel(in: liveShaped)?.modelID == "qwen/qwen3-vl-2b")
        reporter.record(
            "a vision=false llm is never selected as the vision helper even when it is the smallest",
            liveShaped?.first { $0.modelID == "llama-3.2-1b-instruct" }?.isVisionCapable == false)
        reporter.record(
            "an absent or null vision field is unanswered, so a vlm-typed row still counts as capable",
            LMStudioModelCatalog.parseInstalled(Data(fixture.utf8))?
                .first { $0.modelID == "vendor/small-vlm" }?.isVisionCapable == true
                && LMStudioModelCatalog.parseInstalled(Data(fixture.utf8))?
                    .first { $0.modelID == "vendor/alpha-model" }?.isVisionCapable == false)
        reporter.record(
            "the vision-capable filter never disturbs the Local picker, which stays llm-typed rows only",
            LMStudioModelCatalog.parse(Data(liveShapedFixture.utf8))?.map(\.modelID) == [
                "qwen/qwen3.6-35b-a3b", "qwen2.5-coder-7b-instruct",
                "google_gemma-3-4b-it-qat", "qwen/qwen3-vl-2b", "llama-3.2-1b-instruct",
            ])

        checkResidencyWatchdog(reporter)

        print(reporter.passed
            ? "[lmstudio-model-catalog-selftest] PASS"
            : "[lmstudio-model-catalog-selftest] FAIL")
        return reporter.passed
    }

    /// L3: the watchdog under every `lms` call this catalog rides on.
    ///
    /// The shape being replaced was a lone `proc.terminate()` (SIGTERM to the leader only, no
    /// escalation) followed by a BLOCKING `readDataToEndOfFile()`. Each fixture below is one of the two
    /// ways that shape hung forever. Synthetic executables only: no LM Studio, no model, no network.
    private static func checkResidencyWatchdog(_ reporter: SelfTestReporter) {
        print("--- lms watchdog: SIGTERM/grace/SIGKILL + process group ---")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-residency-watchdog-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true))
                != nil else {
            reporter.record("residency watchdog fixture setup", false)
            return
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        func script(_ name: String, _ body: String) -> String? {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.createFile(
                atPath: url.path, contents: Data("#!/bin/sh\n\(body)\n".utf8),
                attributes: [.posixPermissions: 0o700]) else { return nil }
            return url.path
        }

        // Baseline: a well-behaved CLI still returns its text and its exit status.
        if let ok = script("ok.sh", "printf 'IDENTIFIER some-model\\n'; exit 0") {
            let run = ModelResidency.runBoundedForTest(executable: ok, arguments: [], timeout: 5)
            reporter.record(
                "a normal lms call returns its output, exit code, and no watchdog action",
                String(decoding: run?.output ?? Data(), as: UTF8.self).contains("some-model")
                    && run?.exitedNormally == true && run?.exitCode == 0
                    && run?.timedOut == false && run?.escalatedToSIGKILL == false
                    && run?.outputTruncated == false)
        }
        if let fails = script("fail.sh", "exit 3") {
            let run = ModelResidency.runBoundedForTest(executable: fails, arguments: [], timeout: 5)
            reporter.record("a non-zero exit is reported, not swallowed",
                            run?.exitedNormally == true && run?.exitCode == 3)
        }

        // Hang 1: a CLI that IGNORES SIGTERM. `proc.terminate()` alone never ends this, so the old
        // runner blocked its caller forever. The escalation must end it, bounded.
        if let stubborn = script("stubborn.sh",
                                 "trap '' TERM\nprintf 'partial\\n'\nwhile :; do sleep 1; done") {
            let t0 = Date()
            let run = ModelResidency.runBoundedForTest(
                executable: stubborn, arguments: [], timeout: 0.6, grace: 0.5)
            let elapsed = Date().timeIntervalSince(t0)
            reporter.record(
                "a SIGTERM-ignoring lms is escalated to SIGKILL and the caller is released",
                run?.timedOut == true && run?.escalatedToSIGKILL == true
                    && run?.exitedNormally == false
                    && run?.residualProcessGroup == false
                    && elapsed < 8,
                String(format: "%.2fs, sigkill=%@", elapsed,
                       run?.escalatedToSIGKILL == true ? "true" : "false"))
        }

        // Hang 2: the leader exits promptly but leaves a descendant holding the inherited pipe write
        // end. The old runner waited on EOF, not on the process, so this blocked forever even though
        // nothing was wrong with the leader. The bounded drain must return, and — the load-bearing part
        // — the surviving process must NOT be killed, because `lms server start` exists to leave a
        // long-running server behind and killing that group would take LM Studio down.
        if let daemonizer = script("daemonize.sh",
                                   "sleep 30 &\nprintf 'started\\n'\nexit 0") {
            let t0 = Date()
            let run = ModelResidency.runBoundedForTest(
                executable: daemonizer, arguments: [], timeout: 5, grace: 0.4)
            let elapsed = Date().timeIntervalSince(t0)
            reporter.record(
                "a descendant holding the pipe open cannot wedge the caller, and is left running",
                run != nil && run?.timedOut == false && run?.escalatedToSIGKILL == false
                    && run?.residualProcessGroup == true
                    && String(decoding: run?.output ?? Data(), as: UTF8.self).contains("started")
                    && elapsed < 4,
                String(format: "%.2fs, residual=%@", elapsed,
                       run?.residualProcessGroup == true ? "true" : "false"))
        }

        // A merged-stderr call is what `runLMS` uses; a discarded one is what the JSON catalog uses,
        // so an LM Studio diagnostic can never corrupt otherwise-valid JSON.
        if let noisy = script("noisy.sh", "printf 'DIAGNOSTIC\\n' >&2; printf '[]\\n'; exit 0") {
            let merged = ModelResidency.runBoundedForTest(
                executable: noisy, arguments: [], timeout: 5, standardError: .merge)
            let discarded = ModelResidency.runBoundedForTest(
                executable: noisy, arguments: [], timeout: 5, standardError: .discard)
            reporter.record(
                "stderr merges for the text runner and is discarded for the JSON runner",
                String(decoding: merged?.output ?? Data(), as: UTF8.self).contains("DIAGNOSTIC")
                    && String(decoding: discarded?.output ?? Data(), as: UTF8.self)
                        .contains("DIAGNOSTIC") == false
                    && String(decoding: discarded?.output ?? Data(), as: UTF8.self).contains("[]"))
        }

        // A CLI that outruns the capture cap must be reported unusable rather than parsed half-way.
        if let flood = script("flood.sh", "/usr/bin/yes ABCDEFGHIJ | /usr/bin/head -c 5000000; exit 0") {
            let run = ModelResidency.runBoundedForTest(executable: flood, arguments: [], timeout: 20)
            reporter.record("output past the capture cap is flagged truncated, never silently parsed",
                            run?.outputTruncated == true && (run?.output.count ?? 0) <= (4 << 20))
        }

        // Structural pin: no second, unhardened `lms` runner may reappear beside the bounded one.
        // Comments are stripped first, because this file's own prose NAMES the discarded primitives.
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Sources/App/ModelResidency.swift", isDirectory: false)
        let raw = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        reporter.record(
            "every lms call now goes through the one bounded runner; no unescalated Process watchdog "
                + "or blocking readDataToEndOfFile survives",
            !code.isEmpty
                && !code.contains("readDataToEndOfFile")
                && !code.contains("Process()")
                && !code.contains("waitUntilExit")
                && code.contains("POSIX_SPAWN_SETPGROUP")
                && code.contains("kill(-pid, SIGKILL)"))
    }
}
