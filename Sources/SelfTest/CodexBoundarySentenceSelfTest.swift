import Foundation

/// "Codex not found" and "Codex could not be sandboxed" must reach the user as different sentences, on
/// every surface: the boundary error, the HUD allowlist, the Setup/Preflight row, and the provider
/// smoke's operator cause.
///
/// This exists because ADR 0020 fixed ONE sentence for every boundary refusal, and from 2026-09-26 that
/// sentence told users Codex "could not be sandboxed after a Codex update" when the CLI had simply moved
/// out from under a pinned path. Nothing had failed to sandbox; the true cause sat in a log line.
///
/// Offline and synthetic: refusals are driven through the real boundary entry with an injected
/// executable probe and fake ChatGPT.app layouts under TMPDIR. No Codex runs and /Applications is never
/// consulted.
enum CodexBoundarySentenceSelfTest {
    static func run() -> Bool {
        print("=== Codex boundary not-found vs not-sandboxed sentence selftest ===")
        let reporter = SelfTestReporter()
        let check = reporter.check
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "viddydictate-codex-sentence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = CodexIsolationFoundation.scratchPaths(
                root: root.appendingPathComponent("boundary", isDirectory: true))
            let notFound = CodexProviderRuntime.codexNotFoundMessage
            let notSandboxed = CodexProviderRuntime.sandboxUnverifiedMessage
            check("the two sentences are distinct and neither claims the other's cause",
                  notFound != notSandboxed && !notFound.contains("sandbox")
                    && notSandboxed.contains("sandboxed") && !notSandboxed.contains("not found"))

            // Probe every boundary path through a fake ChatGPT.app, so the layout is the only variable.
            func probe(fakeAppRoot: String) -> (String) -> Bool {
                { path in
                    FileManager.default.isExecutableFile(atPath: path.replacingOccurrences(
                        of: CodexCLILocation.chatGPTAppRoot, with: fakeAppRoot))
                }
            }
            func fakeApp(_ name: String, files: [String]) throws -> String {
                let app = root.appendingPathComponent("\(name)/ChatGPT.app", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
                for relative in files {
                    let file = app.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path)
                }
                return app.path
            }
            let shimOnly = try fakeApp("shim", files: [CodexCLILocation.refusedShimRelativePath])
            let empty = try fakeApp("empty", files: [])
            let present = try fakeApp("present", files: [
                CodexCLILocation.cliBundleRelativePath + "/" + CodexCLILocation.bundleExecutableRelativePath,
            ])

            func refusal(_ appRoot: String, runner: String = "/usr/bin/true") -> Error? {
                CodexProviderRuntime.boundaryPreparationRefusalForTest(
                    paths: paths, runnerPath: runner, isExecutableFile: probe(fakeAppRoot: appRoot))
            }
            func kind(_ error: Error?) -> CodexProviderRuntime.BoundaryRefusalKind? {
                (error as? CodexProviderRuntime.BoundaryError)?.kind
            }

            for (label, appRoot) in [("shim-only", shimOnly), ("empty", empty)] {
                let error = refusal(appRoot)
                check("\(label) layout: the boundary refuses as not found",
                      kind(error) == .notFound
                        && (error as? CodexProviderRuntime.BoundaryError)?.description
                            .hasPrefix("Codex CLI not found") == true)
                check("\(label) layout: the user reads the not-found sentence, not the sandbox one",
                      error.map { CodexProviderRuntime.userSentence(forBoundaryRefusal: $0) } == notFound)
                check("\(label) layout: preflight names the missing CLI instead of an unexpected error",
                      (error as? CodexProviderRuntime.BoundaryError)?.preflightDescription
                        == "Codex CLI not found at any supported ChatGPT.app location")
            }

            // A candidate exists, but containment cannot be set up: that is "not sandboxed".
            let helperMissing = refusal(present, runner: root.appendingPathComponent("no-runner").path)
            check("a found CLI with no containment helper refuses as not sandboxed",
                  kind(helperMissing) == .notSandboxed
                    && (helperMissing as? CodexProviderRuntime.BoundaryError)?.description
                        == "Codex containment helper is unavailable")
            check("a found CLI that cannot be contained reads the sandbox sentence",
                  helperMissing.map { CodexProviderRuntime.userSentence(forBoundaryRefusal: $0) }
                    == notSandboxed)
            check("every non-BoundaryError refusal reads the sandbox sentence",
                  CodexProviderRuntime.userSentence(
                    forBoundaryRefusal: CodexIsolationError.failed("synthetic")) == notSandboxed)
            check("the operator cause keeps the true description and the preflight wording",
                  refusal(empty).map { CodexProviderRuntime.operatorCause(forBoundaryRefusal: $0) }?
                    .contains("(Codex CLI not found at any supported ChatGPT.app location)") == true)

            // Negative control: the 1.1.0 mapping said "could not be sandboxed" for everything.
            let legacySentence: (Error) -> String = { _ in notSandboxed }
            check("mutant: the single-sentence mapping reports not-sandboxed when nothing exists",
                  refusal(empty).map(legacySentence) == notSandboxed
                    && refusal(empty).map(legacySentence)
                        != refusal(empty).map { CodexProviderRuntime.userSentence(forBoundaryRefusal: $0) })

            // HUD: both sentences survive the content-safe presentation allowlist verbatim.
            check("HUD allowlist shows the not-found sentence verbatim",
                  CleanupClient.capacityRefusalMessage(for: .unavailable(notFound)) == notFound)
            check("HUD allowlist still shows the sandbox sentence verbatim",
                  CleanupClient.capacityRefusalMessage(for: .unavailable(notSandboxed)) == notSandboxed)

            // Setup/Preflight row: not found is "not installed"; not sandboxed is "installed but not usable".
            let missingPresence = LLMProviderDetection.codexPresence(cliFound: false, state: nil)
            let vanishedPresence = LLMProviderDetection.codexPresence(
                cliFound: true, state: .unavailable(notFound))
            let unsandboxedPresence = LLMProviderDetection.codexPresence(
                cliFound: true, state: .unavailable(notSandboxed))
            check("Setup presence: no CLI, or a CLI that vanished mid-check, is not installed",
                  !missingPresence.installed && !vanishedPresence.installed)
            check("Setup presence: an unsandboxable CLI is installed but unavailable with the sentence",
                  unsandboxedPresence.installed
                    && unsandboxedPresence.state == .unavailable(notSandboxed))
            func codexRow(_ presence: LLMProviderDetection.Presence) -> PreflightFinding? {
                var observation = PreflightSelfTest.healthy
                observation.providers = [
                    .claude: .init(installed: false, state: .unavailable("absent")),
                    .codex: presence,
                    .local: .init(installed: false, state: .unavailable("absent")),
                ]
                return Preflight.evaluate(observation).finding(.textProvider)
            }
            let missingRow = codexRow(missingPresence)
            let unsandboxedRow = codexRow(unsandboxedPresence)
            check("Preflight row: not found says not installed and points at ChatGPT.app",
                  missingRow?.summary.contains("Codex is not installed") == true
                    && missingRow?.remedy?.contains("install ChatGPT.app") == true)
            check("Preflight row: not sandboxed says installed but not usable, with the sandbox sentence",
                  unsandboxedRow?.summary.contains("Codex is installed but not usable") == true
                    && unsandboxedRow?.summary.contains("could not be sandboxed") == true
                    && unsandboxedRow?.remedy?.contains("install ChatGPT.app") != true)
        } catch {
            reporter.record("selftest setup", false, String(describing: error))
        }

        print(reporter.summaryLine(prefix: "[codex-boundary-sentence-selftest]"))
        print(reporter.passed
              ? "CODEX BOUNDARY SENTENCE SELFTEST PASS" : "CODEX BOUNDARY SENTENCE SELFTEST FAIL")
        return reporter.passed
    }
}
