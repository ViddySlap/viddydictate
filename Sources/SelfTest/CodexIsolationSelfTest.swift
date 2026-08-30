import Foundation

enum CodexIsolationSelfTest {
    static func run(runnerPath: String) -> Bool {
        print("=== Codex S1 foundation selftest (synthetic/offline) ===")
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("viddydictate-codex-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reporter = SelfTestReporter()
        let check = reporter.check

        do {
            try CodexIsolationFoundation.secureDirectory(root)
            let paths = CodexIsolationFoundation.scratchPaths(root: root)
            try CodexIsolationFoundation.prepareDirectories(paths)

            let nonExecutableRunner = root.appendingPathComponent(
                "non-executable-runner", isDirectory: false)
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("fixture".utf8), to: nonExecutableRunner,
                finalMode: 0o400, allowReplacement: false)
            let boundaryError = CodexProviderRuntime.boundaryPreparationErrorForTest(
                paths: paths,
                runnerPath: nonExecutableRunner.path,
                isExecutableFile: { path in
                    if path == CodexIsolationFoundation.codexBinary { return true }
                    return FileManager.default.isExecutableFile(atPath: path)
                })
            check("boundary rejects a non-executable runner before version audit with exact message",
                  boundaryError == "Codex containment helper is unavailable")

            let processFixture = root.appendingPathComponent(
                "bounded-process-fixture", isDirectory: false)
            let descendantPIDFile = root.appendingPathComponent(
                "bounded-process-descendant.pid", isDirectory: false)
            let processScript = """
            #!/bin/sh
            trap '' TERM INT
            (
              trap '' TERM INT
              while :; do /bin/sleep 1; done
            ) &
            printf '%s\\n' "$!" > \(descendantPIDFile.path)
            while :; do /bin/sleep 1; done
            """
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data(processScript.utf8),
                to: processFixture,
                finalMode: 0o500,
                allowReplacement: false)
            let boundedStarted = Date()
            // The pid file is the descendant's readiness event. Waiting for
            // it in postLaunch ensures the timeout fixture cannot clean up
            // before the signal-ignoring pipe holder actually exists.
            let boundedResult =
                try CodexIsolationFoundation.runBoundedProcess(
                    executable: processFixture.path,
                    arguments: [],
                    environment: [
                        "HOME": paths.home.path,
                        "PATH": "/usr/bin:/bin",
                        "LANG": "C",
                        "LC_ALL": "C",
                    ],
                    currentDirectory: paths.cwd,
                    timeout: 0.2,
                    // Reaping a signal-ignoring group and its orphaned child
                    // has no caller-visible event beyond wait/group absence
                    // and pipe EOF. Allow host scheduling without weakening
                    // any of those required cleanup assertions.
                    cleanupGrace: 5,
                    stdoutLimit: 1_024,
                    stderrLimit: 1_024,
                    postLaunch: {
                        let descendantReadyDeadline =
                            ProcessInfo.processInfo.systemUptime + 5
                        while !FileManager.default.fileExists(
                                atPath: descendantPIDFile.path),
                              ProcessInfo.processInfo.systemUptime
                                < descendantReadyDeadline {
                            usleep(5_000)
                        }
                        guard FileManager.default.fileExists(
                                atPath: descendantPIDFile.path) else {
                            throw CodexIsolationError.failed(
                                "bounded process descendant readiness event did not arrive")
                        }
                    })
            let boundedElapsed = Date().timeIntervalSince(boundedStarted)
            let descendantPID = try pid_t(
                String(contentsOf: descendantPIDFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            var descendantGone = false
            if let descendantPID {
                // Pipe EOF already proves exit; allow the host orphan reaper
                // to remove the remaining numeric process-table entry.
                for _ in 0..<200 {
                    if kill(descendantPID, 0) != 0 && errno == ESRCH {
                        descendantGone = true
                        break
                    }
                    usleep(25_000)
                }
                if !descendantGone { _ = kill(descendantPID, SIGKILL) }
            }
            let sharedCapturePassed =
                boundedResult.timedOut
                    && boundedResult.leaderReaped
                    && !boundedResult.residualProcessGroup
                    && !boundedResult.captureFailure
                    && boundedElapsed < 10.5
                    && descendantGone
            if !sharedCapturePassed {
                print(
                    "[codex-s1][diag] shared_quarantine "
                        + "status=\(boundedResult.status) "
                        + "timed_out=\(boundedResult.timedOut) "
                        + "leader_reaped=\(boundedResult.leaderReaped) "
                        + "residual_group=\(boundedResult.residualProcessGroup) "
                        + "drain_complete=\(!boundedResult.captureFailure) "
                        + "elapsed_ms=\(Int(boundedElapsed * 1_000)) "
                        + "descendant_pid=\(descendantPID ?? -1) "
                        + "descendant_pgid=\(descendantPID.map(getpgid) ?? -1) "
                        + "descendant_gone=\(descendantGone)")
            }
            check("shared quarantine capture bounds TERM/grace/KILL/reap and pipe holders",
                  sharedCapturePassed)

            let launchRaceRunner = root.appendingPathComponent(
                "launch-race-runner", isDirectory: false)
            let launchRaceReady = root.appendingPathComponent(
                "launch-race-ready", isDirectory: false)
            let launchRaceRelease = root.appendingPathComponent(
                "launch-race-release", isDirectory: false)
            let launchRaceLeak = root.appendingPathComponent(
                "launch-race-leak", isDirectory: false)
            let launchRaceOrigin = """
            #!/bin/sh
            : > \(launchRaceReady.path)
            while [ ! -f \(launchRaceRelease.path) ]; do /bin/sleep 0.01; done
            exec "$0"
            """
            let launchRaceReplacement = """
            #!/bin/sh
            IFS= read -r value
            printf '%s\\n' "$value" > \(launchRaceLeak.path)
            """
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data(launchRaceOrigin.utf8),
                to: launchRaceRunner,
                finalMode: 0o500,
                allowReplacement: false)
            let launchRaceIdentity =
                try CodexIsolationFoundation.strongFileIdentity(
                    at: launchRaceRunner, includeCodeSigning: false)
            var launchRaceRejected = false
            do {
                _ = try CodexIsolationFoundation.runBoundedProcess(
                    executable: launchRaceRunner.path,
                    arguments: [],
                    environment: [
                        "HOME": paths.home.path,
                        "PATH": "/usr/bin:/bin",
                        "LANG": "C",
                        "LC_ALL": "C",
                    ],
                    currentDirectory: paths.cwd,
                    stdin: Data("SYNTHETIC_RUNNER_STDIN_CANARY\n".utf8),
                    timeout: 1,
                    cleanupGrace: 0.5,
                    stdoutLimit: 1_024,
                    stderrLimit: 1_024,
                    postLaunch: {
                        for _ in 0..<200
                            where !FileManager.default.fileExists(
                                atPath: launchRaceReady.path) {
                            usleep(5_000)
                        }
                        guard FileManager.default.fileExists(
                            atPath: launchRaceReady.path) else {
                            throw CodexIsolationError.failed(
                                "spawn-window fixture did not reach the runner")
                        }
                        try CodexIsolationFoundation.atomicRestrictiveWrite(
                            Data(launchRaceReplacement.utf8),
                            to: launchRaceRunner,
                            finalMode: 0o500,
                            allowReplacement: true)
                        try Data().write(
                            to: launchRaceRelease, options: [.atomic])
                        for _ in 0..<200
                            where !FileManager.default.fileExists(
                                atPath: launchRaceLeak.path) {
                            usleep(5_000)
                        }
                        guard try CodexIsolationFoundation.strongFileIdentity(
                            at: launchRaceRunner,
                            includeCodeSigning: false) == launchRaceIdentity else {
                            throw CodexIsolationError.failed(
                                "Codex boundary executable identity changed")
                        }
                    })
            } catch {
                launchRaceRejected = true
            }
            check("post-spawn runner revalidation precedes every stdin canary byte",
                  launchRaceRejected
                    && !FileManager.default.fileExists(
                        atPath: launchRaceLeak.path))

            let skillA = paths.systemSkills.appendingPathComponent("alpha/SKILL.md")
            let skillB = paths.systemSkills.appendingPathComponent("beta/nested/SKILL.md")
            for directory in [
                paths.skillsRoot,
                paths.systemSkills,
                skillA.deletingLastPathComponent(),
                skillB.deletingLastPathComponent()
                    .deletingLastPathComponent(),
                skillB.deletingLastPathComponent(),
            ] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o755)])
                guard chmod(directory.path, 0o755) == 0 else {
                    throw CodexIsolationError.failed(
                        "could not stage CLI-real seeded-skill directory mode")
                }
            }
            for skill in [skillA, skillB] {
                try Data("fixture".utf8).write(
                    to: skill, options: .withoutOverwriting)
                guard chmod(skill.path, 0o644) == 0 else {
                    throw CodexIsolationError.failed(
                        "could not stage CLI-real seeded-skill file mode")
                }
            }
            check("CLI-seeded fixture begins at umask-real root, directory, and file modes",
                  try mode(paths.skillsRoot) == 0o755
                    && mode(paths.systemSkills) == 0o755
                    && mode(skillB.deletingLastPathComponent()) == 0o755
                    && mode(skillB) == 0o644)
            let treeOnlyNormalizationError = errorDescription {
                try CodexIsolationFoundation.normalizeSeededSkillTree(
                    systemSkills: paths.systemSkills)
                _ = try CodexIsolationFoundation.inspectDedicatedSkillsRoot(
                    skillsRoot: paths.skillsRoot)
            }
            check("unchanged tree-only normalize exposes the exact CLI-seeded skills-root red",
                  treeOnlyNormalizationError
                    == "restrictive mode mismatch for skills: expected 700")
            try CodexIsolationFoundation.normalizeDedicatedSkillsRoot(
                skillsRoot: paths.skillsRoot)
            _ = try CodexIsolationFoundation.inspectDedicatedSkillsRoot(
                skillsRoot: paths.skillsRoot)
            check("production normalize and inspect accepts a CLI-seeded skills root",
                  try mode(paths.skillsRoot) == 0o700
                    && mode(paths.systemSkills) == 0o700
                    && mode(skillB.deletingLastPathComponent()) == 0o700
                    && mode(skillB) == 0o400)

            let stagedParent = root.appendingPathComponent(
                "tree-only-staging-parent", isDirectory: true)
            let stagedSystem = stagedParent.appendingPathComponent(
                "system.staged", isDirectory: true)
            let stagedSkill = stagedSystem.appendingPathComponent(
                "fixture/SKILL.md", isDirectory: false)
            try FileManager.default.createDirectory(
                at: stagedSkill.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o755)])
            for directory in [
                stagedParent,
                stagedSystem,
                stagedSkill.deletingLastPathComponent(),
            ] {
                guard chmod(directory.path, 0o755) == 0 else {
                    throw CodexIsolationError.failed(
                        "could not stage tree-only directory mode")
                }
            }
            try Data("staged".utf8).write(
                to: stagedSkill, options: .withoutOverwriting)
            guard chmod(stagedSkill.path, 0o644) == 0 else {
                throw CodexIsolationError.failed(
                    "could not stage tree-only file mode")
            }
            try CodexIsolationFoundation.normalizeSeededSkillTree(
                systemSkills: stagedSystem)
            check("tree-only staging normalization never chmods its arbitrary parent",
                  try mode(stagedParent) == 0o755
                    && mode(stagedSystem) == 0o700
                    && mode(stagedSkill.deletingLastPathComponent()) == 0o700
                    && mode(stagedSkill) == 0o400)

            let appCreatedRoot = root.appendingPathComponent(
                "app-created-control", isDirectory: true)
            let appCreatedPaths = CodexIsolationFoundation.scratchPaths(
                root: appCreatedRoot)
            try CodexIsolationFoundation.prepareDirectories(appCreatedPaths)
            let appCreatedSkill = appCreatedPaths.systemSkills
                .appendingPathComponent("fixture/SKILL.md", isDirectory: false)
            try CodexIsolationFoundation.secureDirectory(
                appCreatedSkill.deletingLastPathComponent())
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("app-created".utf8),
                to: appCreatedSkill,
                finalMode: 0o400,
                allowReplacement: false)
            try CodexIsolationFoundation.normalizeDedicatedSkillsRoot(
                skillsRoot: appCreatedPaths.skillsRoot)
            _ = try CodexIsolationFoundation.inspectDedicatedSkillsRoot(
                skillsRoot: appCreatedPaths.skillsRoot)
            check("app-created 0700 skills-root control remains green",
                  try mode(appCreatedPaths.skillsRoot) == 0o700
                    && mode(appCreatedPaths.systemSkills) == 0o700
                    && mode(appCreatedSkill) == 0o400)
            let skills = try CodexIsolationFoundation.enumerateSeededSkills(paths: paths)
            check("enumerates every nested seeded SKILL.md", skills == [skillA, skillB].map(\ .standardizedFileURL).sorted { $0.path < $1.path })
            let skillTree = try CodexIsolationFoundation.inspectSeededSkillTree(
                systemSkills: paths.systemSkills)
            check("seeded-skill receipt covers every relative path, type, mode, and file byte",
                  skillTree.skillFiles == skills
                    && skillTree.entries.contains(where: {
                        $0.relativePath == "alpha/SKILL.md"
                            && $0.kind == .regularFile && $0.mode == 0o400
                    })
                    && skillTree.entries.contains(where: {
                        $0.relativePath == "beta/nested" && $0.kind == .directory
                            && $0.mode == 0o700
                    })
                    && skillTree.identitySHA256.count == 64)
            let escapingLink = paths.systemSkills.appendingPathComponent("escape", isDirectory: false)
            try FileManager.default.createSymbolicLink(
                at: escapingLink, withDestinationURL: root.deletingLastPathComponent())
            check("seeded-skill tree rejects symlinks before copy or prompt audit", throwsError {
                _ = try CodexIsolationFoundation.inspectSeededSkillTree(
                    systemSkills: paths.systemSkills)
            })
            try FileManager.default.removeItem(at: escapingLink)
            let rogueSkill = paths.systemSkills.deletingLastPathComponent()
                .appendingPathComponent("foo/SKILL.md", isDirectory: false)
            try CodexIsolationFoundation.secureDirectory(
                rogueSkill.deletingLastPathComponent())
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("rogue".utf8), to: rogueSkill,
                finalMode: 0o400, allowReplacement: false)
            check("a sibling skill outside canonical .system invalidates the boundary",
                  throwsError {
                      _ = try CodexProviderRuntime.verifySkillInventoryAndConfig(
                          paths: paths,
                          skills: skills,
                          skillNames: Set(["alpha", "beta"]),
                          verifyStagedBytes: false)
                  })
            try FileManager.default.removeItem(
                at: paths.systemSkills.deletingLastPathComponent()
                    .appendingPathComponent("foo", isDirectory: true))

            let featureFixture = try String(
                contentsOf: URL(fileURLWithPath:
                    "Sources/SelfTest/Fixtures/codex-features-0.146-first.txt"),
                encoding: .utf8)
            let featureInventory = try CodexIsolationFoundation.parseFeatureInventory(
                featureFixture)
            let config = try CodexIsolationFoundation.baseConfig(
                paths: paths,
                disabledSkillPaths: skills,
                featureInventory: featureInventory)
            try CodexIsolationFoundation.stageConfig(config, at: paths.config)
            check("base config is immutable mode 0400", try mode(paths.config) == 0o400)
            let configText = String(decoding: config, as: UTF8.self)
            let canonicalSkillPath = skillA.path
            let standardizedSkillPath = skillA.standardizedFileURL.path
            let canonicalSQLitePath = paths.sqlite.path
            let standardizedSQLitePath = paths.sqlite.standardizedFileURL.path
            check("Foundation standardizedFileURL strips /private from existing temp paths",
                  FileManager.default.fileExists(atPath: canonicalSkillPath)
                    && FileManager.default.fileExists(atPath: canonicalSQLitePath)
                    && canonicalSkillPath.hasPrefix("/private/tmp/")
                    && canonicalSQLitePath.hasPrefix("/private/tmp/")
                    && standardizedSkillPath.hasPrefix("/tmp/")
                    && standardizedSQLitePath.hasPrefix("/tmp/"))
            let missingConfigPath = root.appendingPathComponent(
                "missing-config-path", isDirectory: false)
            check("canonical config paths fail closed when the path does not exist",
                  errorDescription {
                      _ = try CodexIsolationFoundation.canonicalPath(
                          missingConfigPath)
                  } == "path canonicalization requires an existing path")
            let preinstallRoot = root.appendingPathComponent(
                "preinstall-live-config", isDirectory: true)
            try CodexIsolationFoundation.secureDirectory(preinstallRoot)
            let preinstallPaths = CodexIsolationFoundation.scratchPaths(
                root: preinstallRoot)
            try CodexIsolationFoundation.prepareDirectories(preinstallPaths)
            let futureLiveSkill = preinstallPaths.systemSkills
                .appendingPathComponent("future/SKILL.md", isDirectory: false)
            let futureCanonicalError = errorDescription {
                _ = try CodexIsolationFoundation.canonicalPath(futureLiveSkill)
            }
            let preinstallConfig = try CodexIsolationFoundation.preinstallBaseConfig(
                paths: preinstallPaths,
                disabledSkillPaths: [futureLiveSkill],
                featureInventory: featureInventory)
            let preinstallConfigText = String(decoding: preinstallConfig, as: UTF8.self)
            let anchoredFutureSkillPath =
                "\(try CodexIsolationFoundation.canonicalPath(preinstallPaths.home))"
                + "/skills/.system/future/SKILL.md"
            let anchoredFutureSkillLine =
                "path = \(CodexIsolationFoundation.tomlString(anchoredFutureSkillPath))"
            check("pre-install live config derives a future skill path from its existing home anchor",
                  !FileManager.default.fileExists(
                    atPath: preinstallPaths.systemSkills.path)
                    && futureCanonicalError
                        == "path canonicalization requires an existing path"
                    && preinstallConfigText.contains(anchoredFutureSkillLine))
            try CodexIsolationFoundation.secureDirectory(
                futureLiveSkill.deletingLastPathComponent())
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("future".utf8),
                to: futureLiveSkill,
                finalMode: 0o400,
                allowReplacement: false)
            let postInstallFutureSkillPath =
                try CodexIsolationFoundation.canonicalPath(futureLiveSkill)
            let postInstallFutureSkillLine =
                "path = \(CodexIsolationFoundation.tomlString(postInstallFutureSkillPath))"
            check("pre-install skill path bytes equal post-install realpath bytes",
                  anchoredFutureSkillPath == postInstallFutureSkillPath
                    && preinstallConfigText.contains(postInstallFutureSkillLine))
            let canonicalSkillLine =
                "path = \(CodexIsolationFoundation.tomlString(canonicalSkillPath))"
            let standardizedSkillLine =
                "path = \(CodexIsolationFoundation.tomlString(standardizedSkillPath))"
            let canonicalSQLiteLine =
                "sqlite_home = \(CodexIsolationFoundation.tomlString(canonicalSQLitePath))"
            let standardizedSQLiteLine =
                "sqlite_home = \(CodexIsolationFoundation.tomlString(standardizedSQLitePath))"
            check("base config writes realpath-canonical existing paths without alias spellings",
                  configText.components(separatedBy: canonicalSkillLine).count - 1 == 1
                    && !configText.contains(standardizedSkillLine)
                    && configText.components(separatedBy: canonicalSQLiteLine).count - 1 == 1
                    && !configText.contains(standardizedSQLiteLine))
            check("config writer and S1 auditor agree on canonical skill path bytes",
                  errorDescription {
                      try CodexIsolationPreflight.auditConfigSkillEntries(
                          configURL: paths.config, skillURLs: skills)
                  } == nil)
            let featureBlock = configText.components(separatedBy: "\n[features]\n")
                .dropFirst().first?.components(separatedBy: "\n[mcp_servers]\n").first ?? ""
            let renderedFeatureKeys = Set(featureBlock.split(separator: "\n").compactMap { line in
                let suffix = " = false"
                return line.hasSuffix(suffix) ? String(line.dropLast(suffix.count)) : nil
            })
            let expectedForceable = Set(CodexIsolationFoundation.restrictiveFeatureNames(
                from: featureInventory))
            check("base config emits every and only currently forceable feature",
                  renderedFeatureKeys == expectedForceable)
            check("base config omits removed/deprecated tombstones including 0.146 apply_patch",
                  renderedFeatureKeys.isDisjoint(with: [
                    "apply_patch_freeform", "item_ids", "use_legacy_landlock",
                    "web_search_cached", "web_search_request",
                  ]))
            check("top-level web search remains canonically disabled",
                  configText.contains("\nweb_search = \"disabled\"\n"))
            check("each seeded skill is disabled exactly once",
                  skills.allSatisfy { configText.components(separatedBy: $0.path).count - 1 == 1 })

            try CodexIsolationFoundation.stageSchema(paths: paths)
            check("strict schema is immutable mode 0400", try mode(paths.schema) == 0o400)

            let instructions = "\(CodexIsolationFoundation.routeAuditMarker)\nSynthetic instruction only."
            let profile = try CodexIsolationFoundation.routeProfile(developerInstructions: instructions)
            try CodexIsolationFoundation.stageProfile(profile, paths: paths)
            check("profile name is its complete canonical SHA-256",
                  profile.name == "route-\(CodexIsolationFoundation.sha256Hex(profile.bytes))")
            check("profile is immutable mode 0400", try mode(profile.url(in: paths)) == 0o400)
            check("model changes alter the full profile hash",
                  try CodexIsolationFoundation.routeProfile(developerInstructions: instructions, model: "gpt-test").hash != profile.hash)
            check("effort changes alter the full profile hash",
                  try CodexIsolationFoundation.routeProfile(developerInstructions: instructions, effort: "medium").hash != profile.hash)
            check("developer instructions alter the full profile hash",
                  try CodexIsolationFoundation.routeProfile(developerInstructions: instructions + " changed").hash != profile.hash)
            check("envelope version alters the full profile hash",
                  try CodexIsolationFoundation.routeProfile(developerInstructions: instructions,
                                                             envelopeVersion: "viddydictate-transform-v2").hash != profile.hash)
            let opaqueModel = "nebula.runtime::next@☄️"
            let opaqueEffort = "x/y"
            let opaqueProfile = try? CodexIsolationFoundation.routeProfile(
                developerInstructions: instructions,
                model: opaqueModel,
                effort: opaqueEffort)
            check("future-shaped opaque catalog model and effort reach the execution profile exactly",
                  opaqueProfile.map {
                      let text = String(decoding: $0.bytes, as: UTF8.self)
                      return text.contains(
                          "model = \(CodexIsolationFoundation.tomlString(opaqueModel))")
                        && text.contains(
                          "model_reasoning_effort = \(CodexIsolationFoundation.tomlString(opaqueEffort))")
                  } == true)
            check("opaque route values remain nonempty and byte bounded",
                  throwsError {
                      _ = try CodexIsolationFoundation.routeProfile(
                          developerInstructions: instructions,
                          model: "",
                          effort: opaqueEffort)
                  }
                    && throwsError {
                        _ = try CodexIsolationFoundation.routeProfile(
                            developerInstructions: instructions,
                            model: opaqueModel,
                            effort: String(
                                repeating: "e",
                                count: CodexIsolationFoundation.maxOpaqueRouteValueBytes + 1))
                    })

            let secretMarker = "SYNTHETIC_ARGV_PRIVACY_CANARY"
            let args = CodexIsolationFoundation.execArguments(profile: profile, paths: paths)
            check("exec contract reads the complete user message only from stdin",
                  args.last == "-" && !args.joined(separator: " ").contains(secretMarker))
            check("argv carries only the content-hashed profile name, not developer instructions",
                  args.contains(profile.name) && !args.joined(separator: " ").contains(CodexIsolationFoundation.routeAuditMarker))
            let argumentPairs = Array(zip(args, args.dropFirst()))
            check("exec contract pins the Codex sandbox to read-only",
                  args.filter { $0 == "-s" }.count == 1
                    && argumentPairs.contains { $0.0 == "-s" && $0.1 == "read-only" })
            check("exec contract pins approval to never",
                  args.filter { $0 == "-a" }.count == 1
                    && argumentPairs.contains { $0.0 == "-a" && $0.1 == "never" })
            let stdin = String(decoding: CodexIsolationFoundation.stdinBytes(userText: secretMarker), as: UTF8.self)
            check("stdin uses the fixed fenced transcript contract",
                  stdin == "<<<TRANSCRIPT>>>\n\(secretMarker)\n<<<END_TRANSCRIPT>>>\n")

            let valid = """
            {"type":"thread.started","thread_id":"synthetic"}
            {"type":"turn.started"}
            {"type":"item.completed","item":{"type":"agent_message","text":"{\\"result\\":\\"clean\\"}"}}
            {"type":"turn.completed"}
            """
            check("strict JSONL accepts one schema-valid completed agent message",
                  try CodexTransformOutputContract.parseAcceptedResult(Data(valid.utf8)) == "clean")
            let ignoredItemStates = """
            {"type":"item.started","item":{"id":"initial-start","type":"reasoning"}}
            {"type":"item.completed","item":{"id":"initial-complete","type":"error"}}
            {"type":"thread.started","thread_id":"synthetic"}
            {"type":"item.started","item":{"id":"thread-start","type":"todo_list"}}
            {"type":"item.completed","item":{"id":"thread-complete","type":"command_execution"}}
            {"type":"turn.started"}
            {"type":"item.started","item":{"id":"turn-start","type":"file_change"}}
            {"type":"item.completed","item":{"id":"turn-complete","type":"mcp_tool_call"}}
            {"type":"item.completed","item":{"type":"agent_message","text":"{\\"result\\":\\"clean\\"}"}}
            {"type":"item.started","item":{"id":"message-start","type":"web_search"}}
            {"type":"item.completed","item":{"id":"message-complete","type":"browser_action"}}
            {"type":"turn.completed"}
            """
            check("non-agent item events are ignored in every pre-terminal parser state",
                  try CodexTransformOutputContract.parseAcceptedResult(
                    Data(ignoredItemStates.utf8)) == "clean")
            let noAgentMessage = """
            {"type":"thread.started","thread_id":"synthetic"}
            {"type":"item.completed","item":{"type":"error","message":"synthetic advisory"}}
            {"type":"turn.started"}
            {"type":"item.completed","item":{"type":"reasoning"}}
            {"type":"turn.completed"}
            """
            check("strict JSONL rejects a stream with no agent message", throwsError {
                _ = try CodexTransformOutputContract.parseAcceptedResult(
                    Data(noAgentMessage.utf8))
            })
            check("strict JSONL rejects partial streams", throwsError {
                _ = try CodexTransformOutputContract.parseAcceptedResult(
                    Data(valid.replacingOccurrences(of: "{\"type\":\"turn.completed\"}", with: "").utf8)
                )
            })
            check("strict JSONL rejects duplicate final messages", throwsError {
                let duplicate = valid.replacingOccurrences(of: "{\"type\":\"turn.completed\"}", with:
                    "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{\\\"result\\\":\\\"again\\\"}\"}}\n{\"type\":\"turn.completed\"}")
                _ = try CodexTransformOutputContract.parseAcceptedResult(Data(duplicate.utf8))
            })
            check("strict JSONL rejects a top-level error event", throwsError {
                let bad = valid.replacingOccurrences(
                    of: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{\\\"result\\\":\\\"clean\\\"}\"}}",
                    with: "{\"type\":\"error\",\"message\":\"synthetic failure\"}")
                _ = try CodexTransformOutputContract.parseAcceptedResult(Data(bad.utf8))
            })
            check("strict JSONL rejects a turn.failed event", throwsError {
                let bad = valid.replacingOccurrences(
                    of: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{\\\"result\\\":\\\"clean\\\"}\"}}",
                    with: "{\"type\":\"turn.failed\",\"error\":{\"message\":\"synthetic failure\"}}")
                _ = try CodexTransformOutputContract.parseAcceptedResult(Data(bad.utf8))
            })
            check("strict JSONL rejects every event after turn.completed", throwsError {
                let bad = valid + "\n{\"type\":\"item.completed\",\"item\":{\"type\":\"error\"}}"
                _ = try CodexTransformOutputContract.parseAcceptedResult(Data(bad.utf8))
            })
            check("strict nested schema rejects additional properties", throwsError {
                let bad = valid.replacingOccurrences(of: "{\\\"result\\\":\\\"clean\\\"}",
                                                     with: "{\\\"result\\\":\\\"clean\\\",\\\"extra\\\":true}")
                _ = try CodexTransformOutputContract.parseAcceptedResult(Data(bad.utf8))
            })
            let itemIDs = """
            {"type":"thread.started","thread_id":"synthetic","id":"thread-bookkeeping"}
            {"type":"turn.started","id":"turn-bookkeeping"}
            {"type":"item.completed","item":{"id":"item-bookkeeping","type":"agent_message","text":"{\\"result\\":\\"clean\\"}"}}
            {"type":"turn.completed","id":"turn-bookkeeping"}
            """
            check("item_ids changes only additive bookkeeping on already-accepted JSONL classes",
                  try CodexTransformOutputContract.parseAcceptedResult(Data(itemIDs.utf8))
                    == "clean")
            check("item_ids does not authorize a new JSONL event class", errorDescription {
                _ = try CodexTransformOutputContract.parseAcceptedResult(Data("""
                {"type":"thread.started","thread_id":"synthetic"}
                {"type":"turn.started"}
                {"type":"item.id_assigned","id":"item-bookkeeping"}
                {"type":"item.completed","item":{"type":"agent_message","text":"{\\"result\\":\\"clean\\"}"}}
                {"type":"turn.completed"}
                """.utf8))
            } == "unexpected JSONL event rejected: item.id_assigned")

            let realPromptMessages: [[String: Any]] = [
                [
                    "role": "developer",
                    "content": [
                        ["type": "input_text", "text": instructions],
                        [
                            "type": "input_text",
                            "text": """
                            <permissions instructions>
                            Synthetic restrictive sandbox profile.
                            </permissions instructions>
                            """,
                        ],
                    ],
                    "id": "msg_synthetic_001",
                    "type": "message",
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": "synthetic-turn-001",
                    ],
                ],
                [
                    "role": "developer",
                    "content": [[
                        "type": "input_text",
                        "text": "You are `/root`, the primary agent in a synthetic team.",
                    ]],
                    "id": "msg_synthetic_002",
                    "type": "message",
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": "synthetic-turn-001",
                    ],
                ],
                [
                    "role": "developer",
                    "content": [[
                        "type": "input_text",
                        "text": """
                        <multi_agent_mode>
                        Do not spawn synthetic sub-agents.
                        </multi_agent_mode>
                        """,
                    ]],
                    "id": "msg_synthetic_003",
                    "type": "message",
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": "synthetic-turn-001",
                    ],
                ],
                [
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": """
                        <environment_context>
                          <cwd>/private/tmp/viddydictate-synthetic/cwd</cwd>
                        </environment_context>
                        """,
                    ]],
                    "id": "msg_synthetic_004",
                    "type": "message",
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": "synthetic-turn-001",
                    ],
                ],
                [
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": CodexIsolationFoundation.userAuditMarker,
                    ]],
                    "id": "msg_synthetic_005",
                    "type": "message",
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": "synthetic-turn-001",
                    ],
                ],
            ]
            func promptAuditError(
                _ messages: [[String: Any]],
                skillNames: Set<String> = [],
                returnPreflightDescription: Bool = false
            ) throws -> String? {
                let data = try JSONSerialization.data(
                    withJSONObject: messages, options: [.sortedKeys])
                return CodexProviderRuntime.auditPromptInputErrorForTest(
                    data,
                    paths: paths,
                    skillNames: skillNames,
                    routeMarker: CodexIsolationFoundation.routeAuditMarker,
                    userMarker: CodexIsolationFoundation.userAuditMarker,
                    expectedDeveloperContent: instructions,
                    returnPreflightDescription: returnPreflightDescription)
            }
            func replacingPromptBlockText(
                _ messages: [[String: Any]],
                messageIndex: Int,
                blockIndex: Int,
                text: String
            ) -> [[String: Any]] {
                var updated = messages
                var blocks =
                    updated[messageIndex]["content"] as! [[String: Any]]
                blocks[blockIndex]["text"] = text
                updated[messageIndex]["content"] = blocks
                return updated
            }

            let realPromptEnvelopeError = try promptAuditError(
                realPromptMessages, returnPreflightDescription: true)
            reporter.record(
                "real 0.149 five-message prompt-input envelope is accepted",
                realPromptEnvelopeError == nil,
                realPromptEnvelopeError ?? "")

            // ADR 0020. Measured from codex-cli 0.150.0-alpha.8 on 2026-08-29. The prompt shape is
            // MODEL-dependent, not version-dependent: the fixture above is gpt-5.6-sol, what the app
            // is configured to use. gpt-5.1-codex-max, on the same binary and the same restrictive
            // config, collapses the three developer messages into one, drops <multi_agent_mode>, and
            // moves <environment_context> ahead of the user turn. Nothing the sandbox cares about
            // differs between them. The old audit pinned the first shape and would have rejected the
            // second during model qualification, so both must pass the same audit.
            let realPrompt0150Messages: [[String: Any]] = [
                [
                    "role": "developer",
                    "content": [
                        ["type": "input_text", "text": instructions],
                        [
                            "type": "input_text",
                            "text": """
                            <permissions instructions>
                            Synthetic restrictive sandbox profile.
                            </permissions instructions>
                            """,
                        ],
                    ],
                    "id": "msg_synthetic_0150_001",
                    "type": "message",
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": "auto-compact-0",
                        "content_item_kinds": ["generic.developer_instructions"],
                    ],
                ],
                [
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": """
                        <environment_context>
                          <cwd>/private/tmp/viddydictate-synthetic/cwd</cwd>
                        </environment_context>
                        """,
                    ]],
                    "id": "msg_synthetic_0150_002",
                    "type": "message",
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": "auto-compact-0",
                        "content_item_kinds": ["environments.environment_context"],
                    ],
                ],
                [
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": CodexIsolationFoundation.userAuditMarker,
                    ]],
                    "id": "msg_synthetic_0150_003",
                    "type": "message",
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": "auto-compact-0",
                        "content_item_kinds": ["user.text"],
                    ],
                ],
            ]
            let real0150EnvelopeError = try promptAuditError(
                realPrompt0150Messages, returnPreflightDescription: true)
            reporter.record(
                "real 0.150 three-message prompt-input envelope is accepted",
                real0150EnvelopeError == nil,
                real0150EnvelopeError ?? "")

            // ADR 0020: an added key is upstream's business, but the contamination scan walks the
            // whole payload, so nothing of ours can hide inside one.
            var extraMessageKey = realPromptMessages
            extraMessageKey[1]["unexpected"] = true
            check("prompt envelope accepts an added upstream message key",
                  try promptAuditError(extraMessageKey) == nil)

            var contaminatedExtraKey = realPromptMessages
            contaminatedExtraKey[1]["unexpected"] = "leaks ~/.codex"
            check("contamination scan reaches a value hidden in an added message key",
                  try promptAuditError(contaminatedExtraKey)
                    == "Codex prompt context contamination was detected")

            var contaminatedMetadataValue = realPromptMessages
            contaminatedMetadataValue[1][
                "internal_chat_message_metadata_passthrough"] = [
                    "turn_id": "synthetic-turn-001",
                    "nested": ["leaks ViddyVault"],
                ]
            check("contamination scan reaches a value nested in passthrough metadata",
                  try promptAuditError(contaminatedMetadataValue)
                    == "Codex prompt context contamination was detected")

            var wrongMessageType = realPromptMessages
            wrongMessageType[1]["type"] = "response"
            check("prompt envelope accepts an upstream message type it does not know",
                  try promptAuditError(wrongMessageType) == nil)

            var malformedMessageID = realPromptMessages
            malformedMessageID[1]["id"] = "message_synthetic_002"
            check("prompt envelope rejects a malformed opaque message id precisely",
                  try promptAuditError(malformedMessageID)
                    == "Codex prompt message id changed")

            var oversizedMessageID = realPromptMessages
            oversizedMessageID[1]["id"] =
                "msg_" + String(repeating: "a", count: 4_093)
            check("prompt envelope rejects an oversized message id precisely",
                  try promptAuditError(oversizedMessageID)
                    == "Codex prompt message id changed")

            var duplicateMessageID = realPromptMessages
            duplicateMessageID[1]["id"] = "msg_synthetic_001"
            check("prompt envelope rejects duplicate opaque message ids precisely",
                  try promptAuditError(duplicateMessageID)
                    == "Codex prompt message id changed")

            var malformedMetadata = realPromptMessages
            malformedMetadata[1][
                "internal_chat_message_metadata_passthrough"] = ["not-an-object"]
            check("prompt envelope rejects malformed passthrough metadata precisely",
                  try promptAuditError(malformedMetadata)
                    == "Codex prompt message metadata changed")

            var oversizedMetadata = realPromptMessages
            oversizedMetadata[1][
                "internal_chat_message_metadata_passthrough"] = [
                    "turn_id": String(repeating: "m", count: 4_097),
                ]
            check("prompt envelope rejects oversized passthrough metadata precisely",
                  try promptAuditError(oversizedMetadata)
                    == "Codex prompt message metadata changed")

            var badBlockShape = realPromptMessages
            badBlockShape[1]["content"] = [[
                "type": "input_text",
                "text": "synthetic",
                "unexpected": true,
            ]]
            check("prompt envelope accepts an added upstream block key",
                  try promptAuditError(badBlockShape) == nil)

            var wrongBlockType = realPromptMessages
            wrongBlockType[1]["content"] = [[
                "type": "output_text",
                "text": "synthetic",
            ]]
            check("prompt envelope accepts an upstream block type it does not know",
                  try promptAuditError(wrongBlockType) == nil)

            var missingBlockText = realPromptMessages
            missingBlockText[1]["content"] = [["type": "input_text"]]
            check("prompt envelope still rejects a block with no readable text",
                  try promptAuditError(missingBlockText)
                    == "Codex prompt block shape changed")

            var tooManyBlocks = realPromptMessages
            tooManyBlocks[1]["content"] = (0...32).map {
                ["type": "input_text", "text": "synthetic-\($0)"]
            }
            check("prompt envelope rejects a block count past its own bound",
                  try promptAuditError(tooManyBlocks)
                    == "Codex prompt block shape changed")

            let tooManyMessages = (0...64).map { index in
                var message = realPromptMessages[1]
                message["id"] = "msg_synthetic_bulk_\(index)"
                return message
            }
            check("prompt envelope rejects a message count past its own bound",
                  try promptAuditError(tooManyMessages)
                    == "Codex prompt message count bound exceeded")

            let oversizedBlock = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 1,
                blockIndex: 0,
                text: String(
                    repeating: "b",
                    count: CodexIsolationFoundation.maxOpaqueRouteValueBytes + 1))
            check("prompt envelope rejects oversized block text precisely",
                  try promptAuditError(oversizedBlock)
                    == "Codex prompt block text bound exceeded")

            // ADR 0020: upstream may reorder its own turns. What must hold is the role of the two
            // messages that carry our content.
            var wrongRoleSequence = realPromptMessages
            wrongRoleSequence[1]["role"] = "user"
            check("prompt envelope accepts an upstream role reordering",
                  try promptAuditError(wrongRoleSequence) == nil)

            var routeInstructionsAsUser = realPromptMessages
            routeInstructionsAsUser[0]["role"] = "user"
            check("route instructions outside a developer message are rejected",
                  try promptAuditError(routeInstructionsAsUser)
                    == "Codex prompt marker placement changed")

            var userMarkerAsDeveloper = realPromptMessages
            userMarkerAsDeveloper[4]["role"] = "developer"
            check("user text outside a user message is rejected",
                  try promptAuditError(userMarkerAsDeveloper)
                    == "Codex prompt marker placement changed")

            let mutatedRouteInstructions = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 0,
                blockIndex: 0,
                text: instructions + " tampered")
            check("route instructions must arrive as one byte-identical block",
                  try promptAuditError(mutatedRouteInstructions)
                    == "Codex prompt marker placement changed")

            let permissionsProseWithoutItsTag = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 0,
                blockIndex: 1,
                text: "Synthetic permissions prose without its structural tag")
            check("upstream boilerplate may lose its structural tag",
                  try promptAuditError(permissionsProseWithoutItsTag) == nil)

            var markerInBoilerplate = realPromptMessages
            markerInBoilerplate = replacingPromptBlockText(
                markerInBoilerplate,
                messageIndex: 0,
                blockIndex: 1,
                text: """
                <permissions instructions>
                Synthetic CLI block \(CodexIsolationFoundation.routeAuditMarker)
                </permissions instructions>
                """)
            check("prompt envelope rejects a route marker in CLI boilerplate precisely",
                  try promptAuditError(markerInBoilerplate)
                    == "Codex prompt marker placement changed")

            let contaminatedCLIBlock = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 1,
                blockIndex: 0,
                text: "Synthetic CLI block references ~/.codex")
            check("prompt contamination scan covers every CLI-injected block",
                  try promptAuditError(contaminatedCLIBlock)
                    == "Codex prompt context contamination was detected")

            let contaminatedVaultMarker = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 1,
                blockIndex: 0,
                text: "Synthetic CLI block references ViddyVault")
            check("prompt contamination scan covers vault leak markers",
                  try promptAuditError(contaminatedVaultMarker)
                    == "Codex prompt context contamination was detected")

            let contaminatedSkillsPath = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 1,
                blockIndex: 0,
                text: "Synthetic CLI block references \(paths.systemSkills.path)")
            check("prompt contamination scan covers the seeded skills path",
                  try promptAuditError(contaminatedSkillsPath)
                    == "Codex prompt context contamination was detected")

            let contaminatedSkillName = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 1,
                blockIndex: 0,
                text: "Synthetic CLI block references synthetic-skill-canary")
            check("prompt contamination scan covers every discovered skill name",
                  try promptAuditError(
                    contaminatedSkillName,
                    skillNames: ["synthetic-skill-canary"])
                    == "Codex prompt context contamination was detected")

            // ADR 0020: codex-cli 0.150 emits <skills_instructions> unconditionally, before the
            // per-leaf disable is applied, so the bare tag is no longer evidence of anything. What
            // must never appear is a seeded skill's name or its path, and those are still rejected.
            let reintroducedSkillsBlock = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 2,
                blockIndex: 0,
                text: "<skills_instructions>\n</skills_instructions>")
            check("an empty skills block alone is no longer treated as contamination",
                  try promptAuditError(reintroducedSkillsBlock) == nil)

            let reintroducedSkillListing = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 2,
                blockIndex: 0,
                text: """
                <skills_instructions>
                - synthetic-skill-canary: reintroduced by upstream
                </skills_instructions>
                """)
            check("a skills block that lists a seeded skill is still rejected",
                  try promptAuditError(
                    reintroducedSkillListing,
                    skillNames: ["synthetic-skill-canary"])
                    == "Codex prompt context contamination was detected")

            let malformedEnvironment = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 3,
                blockIndex: 0,
                text: "synthetic-prefix\n<environment_context></environment_context>")
            check("upstream environment context may change its own framing",
                  try promptAuditError(malformedEnvironment) == nil)

            let finalMarkerWithExtraText = replacingPromptBlockText(
                realPromptMessages,
                messageIndex: 4,
                blockIndex: 0,
                text: "\(CodexIsolationFoundation.userAuditMarker) extra")
            check("final user marker must be the entire final message text",
                  try promptAuditError(finalMarkerWithExtraText)
                    == "Codex prompt marker placement changed")

            // ADR 0020: message count does not decide availability. Substance does, and this shape
            // carries our instructions and our user text correctly.
            let twoMessageShape = [
                realPromptMessages[0], realPromptMessages[4],
            ]
            check("a shorter upstream prompt shape is accepted on its substance",
                  try promptAuditError(twoMessageShape) == nil)

            for tombstone in ["collaboration_modes", "item_ids", "sqlite", "steer"] {
                let plantedEvent = valid.replacingOccurrences(
                    of: "{\"type\":\"turn.started\"}",
                    with: "{\"type\":\"\(tombstone)\"}")
                check("\(tombstone) planted JSONL event-class fault is rejected",
                      errorDescription {
                          _ = try CodexTransformOutputContract.parseAcceptedResult(
                              Data(plantedEvent.utf8))
                      } == "unexpected JSONL event rejected: \(tombstone)")
                let plantedTool = valid.replacingOccurrences(
                    of: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{\\\"result\\\":\\\"clean\\\"}\"}}",
                    with: "{\"type\":\"item.completed\",\"item\":{\"type\":\"\(tombstone)\"}}")
                check("\(tombstone) planted transform-tool fault is rejected", throwsError {
                    _ = try CodexTransformOutputContract.parseAcceptedResult(
                        Data(plantedTool.utf8))
                })

                let contaminatedPrompt = replacingPromptBlockText(
                    realPromptMessages,
                    messageIndex: 1,
                    blockIndex: 0,
                    text: tombstone)
                check("\(tombstone) planted model-visible prompt/context fault is rejected",
                      try promptAuditError(contaminatedPrompt)
                        == "Codex prompt context contamination was detected")
            }

            for (role, content) in [
                ("system", "anonymous neutral context"),
                ("developer", "anonymous extra developer message"),
                ("tool", "anonymous tool result"),
                ("app", "anonymous app context"),
                ("skill", "anonymous capability context"),
            ] {
                var contaminatedPrompt = realPromptMessages
                contaminatedPrompt.append([
                    "role": role,
                    "content": [[
                        "type": "input_text",
                        "text": content,
                    ]],
                    "id": "msg_synthetic_extra_\(role)",
                    "type": "message",
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": "synthetic-turn-001",
                    ],
                ])
                check("anonymous extra \(role) prompt context is accepted",
                      try promptAuditError(contaminatedPrompt) == nil)

                var markerBearingPrompt = realPromptMessages
                markerBearingPrompt.append([
                    "role": role,
                    "content": [[
                        "type": "input_text",
                        "text": CodexIsolationFoundation.routeAuditMarker,
                    ]],
                    "id": "msg_synthetic_marker_\(role)",
                    "type": "message",
                    "internal_chat_message_metadata_passthrough": [
                        "turn_id": "synthetic-turn-001",
                    ],
                ])
                check("an extra \(role) message echoing the route marker is rejected",
                      try promptAuditError(markerBearingPrompt)
                        == "Codex prompt marker placement changed")
            }

            let deprecationFixture = try Data(contentsOf: URL(fileURLWithPath:
                "Sources/SelfTest/Fixtures/codex-jsonl-deprecation-errors.jsonl"))
            check("real 0.145 pre-turn item errors are ignored when the turn completes",
                  try CodexTransformOutputContract.parseAcceptedResult(deprecationFixture)
                    == "SYNTHETIC_RESULT_AFTER_DEPRECATION_ERRORS")
            let cleanFixture = try Data(contentsOf: URL(fileURLWithPath:
                "Sources/SelfTest/Fixtures/codex-jsonl-clean.jsonl"))
            check("real 0.145 clean shape without item.started parses to the result",
                  try CodexTransformOutputContract.parseAcceptedResult(cleanFixture)
                    == "SYNTHETIC_CLEAN_RESULT")
            let real20260827Fixture = try Data(contentsOf: URL(fileURLWithPath:
                "Sources/SelfTest/Fixtures/codex-jsonl-real-20260827.jsonl"))
            check("real 2026-08-27 code-mode advisory stream parses to the result",
                  try CodexTransformOutputContract.parseAcceptedResult(real20260827Fixture)
                    == "Return the word CAPTURED.")

            let binaryFixture = root.appendingPathComponent("candidate-codex", isDirectory: false)
            let runnerFixture = root.appendingPathComponent("candidate-runner", isDirectory: false)
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("binary-a".utf8), to: binaryFixture, finalMode: 0o500,
                allowReplacement: false)
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("runner-a".utf8), to: runnerFixture, finalMode: 0o500,
                allowReplacement: false)
            let binaryIdentity = try CodexIsolationFoundation.strongFileIdentity(
                at: binaryFixture, includeCodeSigning: false)
            let snapshot = try CodexIsolationFoundation.installExecutableSnapshot(
                from: binaryFixture,
                originIdentity: binaryIdentity,
                paths: paths,
                includeCodeSigning: false)
            let runnerIdentity = try CodexIsolationFoundation.strongFileIdentity(
                at: runnerFixture, includeCodeSigning: false)
            let runnerSnapshot =
                try CodexIsolationFoundation.installRunnerSnapshot(
                    from: runnerFixture,
                    originIdentity: runnerIdentity,
                    paths: paths,
                    includeCodeSigning: false)
            let raceOrigin = root.appendingPathComponent(
                "race-origin", isDirectory: false)
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("#!/bin/sh\nIFS= read -r value\nprintf 'SNAPSHOT_A:%s\\n' \"$value\"\n".utf8),
                to: raceOrigin, finalMode: 0o500, allowReplacement: false)
            let raceOriginIdentity =
                try CodexIsolationFoundation.strongFileIdentity(
                    at: raceOrigin, includeCodeSigning: false)
            let raceSnapshot =
                try CodexIsolationFoundation.installExecutableSnapshot(
                    from: raceOrigin,
                    originIdentity: raceOriginIdentity,
                    paths: paths,
                    includeCodeSigning: false)
            let raceProcess = Process()
            raceProcess.executableURL = raceSnapshot.url
            let raceInput = Pipe(), raceOutput = Pipe()
            raceProcess.standardInput = raceInput
            raceProcess.standardOutput = raceOutput
            raceProcess.standardError = FileHandle.nullDevice
            raceProcess.environment = ["PATH": "/usr/bin:/bin"]
            try raceProcess.run()
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("#!/bin/sh\nIFS= read -r value\nprintf 'ORIGIN_B:%s\\n' \"$value\"\n".utf8),
                to: raceOrigin, finalMode: 0o500, allowReplacement: true)
            let stdinCanary = "SYNTHETIC_STDIN_CANARY"
            raceInput.fileHandleForWriting.write(Data("\(stdinCanary)\n".utf8))
            raceInput.fileHandleForWriting.closeFile()
            let raceOutputBytes = raceOutput.fileHandleForReading.readDataToEndOfFile()
            raceProcess.waitUntilExit()
            let raceSnapshotAfter =
                try CodexIsolationFoundation.strongFileIdentity(
                    at: raceSnapshot.url, includeCodeSigning: false)
            let raceOriginAfter =
                try CodexIsolationFoundation.strongFileIdentity(
                    at: raceOrigin, includeCodeSigning: false)
            check("spawn-window origin swap cannot change snapshot bytes or receive stdin canary",
                  raceProcess.terminationStatus == 0
                    && String(decoding: raceOutputBytes, as: UTF8.self)
                        == "SNAPSHOT_A:\(stdinCanary)\n"
                    && raceSnapshotAfter == raceSnapshot.identity
                    && raceOriginAfter != raceOriginIdentity)
            let skillsRoot = try CodexIsolationFoundation.inspectDedicatedSkillsRoot(
                skillsRoot: paths.skillsRoot)
            let receipt = CodexIsolationFoundation.CompatibilityReceipt(
                originExecutable: binaryIdentity,
                executable: snapshot.identity,
                executableSnapshotFilename: snapshot.url.lastPathComponent,
                originRunner: runnerIdentity,
                runner: runnerSnapshot.identity,
                runnerSnapshotFilename:
                    runnerSnapshot.url.lastPathComponent,
                cliVersion: "codex-cli synthetic-newer",
                restrictiveConfigSHA256: CodexIsolationFoundation.sha256Hex(config),
                effectiveFeatures: featureInventory.values.sorted { $0.name < $1.name },
                featureContinuityBaseline:
                    CodexIsolationFoundation.featureInventoryAuditBaseline.values.sorted {
                        $0.name < $1.name
                    },
                seededSkillTreeSHA256: skillTree.identitySHA256,
                skillsRootSHA256: skillsRoot.identitySHA256,
                schemaSHA256: CodexIsolationFoundation.sha256Hex(
                    CodexIsolationFoundation.schemaBytes),
                executionContractSHA256: CodexIsolationFoundation.executionContractSHA256)
            let receiptBytes = try CodexIsolationFoundation.encodeCompatibilityReceipt(receipt)
            check("compatibility receipt round-trips every locked identity field",
                  try CodexIsolationFoundation.decodeCompatibilityReceipt(receiptBytes) == receipt
                    && receipt.executable.sha256.count == 64
                    && receipt.originExecutable.sha256.count == 64
                    && receipt.originRunner.sha256.count == 64
                    && receipt.runner.sha256.count == 64
                    && (try CodexIsolationFoundation.runnerSnapshotURL(
                        paths: paths, receipt: receipt))
                        == runnerSnapshot.url
                    && receipt.cliVersion == "codex-cli synthetic-newer"
                    && receipt.effectiveFeatures.count == featureInventory.count)
            check("exact version text is diagnostic receipt evidence, not a source equality gate",
                  receipt.cliVersion != CodexIsolationFoundation.lastReviewedCLIVersion)
            let mismatchedSnapshotReceipt =
                CodexIsolationFoundation.CompatibilityReceipt(
                    originExecutable: binaryIdentity,
                    executable: runnerIdentity,
                    executableSnapshotFilename:
                        "codex-\(binaryIdentity.sha256)",
                    originRunner: runnerIdentity,
                    runner: runnerSnapshot.identity,
                    runnerSnapshotFilename:
                        runnerSnapshot.url.lastPathComponent,
                    cliVersion: receipt.cliVersion,
                    restrictiveConfigSHA256:
                        receipt.restrictiveConfigSHA256,
                    effectiveFeatures: receipt.effectiveFeatures,
                    featureContinuityBaseline:
                        receipt.featureContinuityBaseline,
                    seededSkillTreeSHA256:
                        receipt.seededSkillTreeSHA256,
                    skillsRootSHA256: receipt.skillsRootSHA256,
                    schemaSHA256: receipt.schemaSHA256,
                    executionContractSHA256:
                        receipt.executionContractSHA256)
            check("receipt rejects a snapshot filename not addressed by launched bytes",
                  throwsError {
                      _ = try CodexIsolationFoundation.executableSnapshotURL(
                          paths: paths,
                          receipt: mismatchedSnapshotReceipt)
                  })
            let mismatchedRunnerSnapshotReceipt =
                CodexIsolationFoundation.CompatibilityReceipt(
                    originExecutable: receipt.originExecutable,
                    executable: receipt.executable,
                    executableSnapshotFilename:
                        receipt.executableSnapshotFilename,
                    originRunner: receipt.originRunner,
                    runner: receipt.runner,
                    runnerSnapshotFilename:
                        "runner-\(String(repeating: "0", count: 64))",
                    cliVersion: receipt.cliVersion,
                    restrictiveConfigSHA256:
                        receipt.restrictiveConfigSHA256,
                    effectiveFeatures: receipt.effectiveFeatures,
                    featureContinuityBaseline:
                        receipt.featureContinuityBaseline,
                    seededSkillTreeSHA256:
                        receipt.seededSkillTreeSHA256,
                    skillsRootSHA256: receipt.skillsRootSHA256,
                    schemaSHA256: receipt.schemaSHA256,
                    executionContractSHA256:
                        receipt.executionContractSHA256)
            check("receipt rejects a runner snapshot filename not addressed by launched bytes",
                  throwsError {
                      _ = try CodexIsolationFoundation.runnerSnapshotURL(
                          paths: paths,
                          receipt: mismatchedRunnerSnapshotReceipt)
                  })
            var corruptTransformRan = false
            let corruptGate = CodexProviderRuntime.authenticatedAuditGateForTest(
                paths: paths,
                receiptBytes: Data("{".utf8),
                validate: { _ in true },
                syntheticTransform: { corruptTransformRan = true })
            check("corrupt S2 receipt blocks before the synthetic transform",
                  corruptGate != nil && !corruptTransformRan)

            let holderEntered = DispatchSemaphore(value: 0)
            let releaseHolder = DispatchSemaphore(value: 0)
            let transformReached = DispatchSemaphore(value: 0)
            let gateCompleted = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                try? CodexIsolationFoundation.withExclusiveBoundaryLock(
                    paths: paths) {
                    holderEntered.signal()
                    _ = releaseHolder.wait(timeout: .now() + 2)
                }
            }
            _ = holderEntered.wait(timeout: .now() + 1)
            DispatchQueue.global(qos: .userInitiated).async {
                _ = CodexProviderRuntime.authenticatedAuditGateForTest(
                    paths: paths,
                    receiptBytes: receiptBytes,
                    validate: { $0 == receipt },
                    syntheticTransform: { transformReached.signal() })
                gateCompleted.signal()
            }
            let ranWhileReseedLocked =
                transformReached.wait(timeout: .now() + 0.15) == .success
            releaseHolder.signal()
            let ranAfterRelease =
                transformReached.wait(timeout: .now() + 1) == .success
            let completed =
                gateCompleted.wait(timeout: .now() + 1) == .success
            check("concurrent reseed lock blocks S2 before synthetic transform",
                  !ranWhileReseedLocked && ranAfterRelease && completed)

            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("binary-b".utf8), to: binaryFixture, finalMode: 0o500,
                allowReplacement: true)
            let replacementIdentity = try CodexIsolationFoundation.strongFileIdentity(
                at: binaryFixture, includeCodeSigning: false)
            check("same-path executable replacement invalidates the exact-binary receipt",
                  replacementIdentity != binaryIdentity
                    && CodexIsolationFoundation.compatibilityReceiptBoundaryFailure(
                        receipt: receipt,
                        originExecutable: replacementIdentity,
                        executable: snapshot.identity,
                        originRunner: runnerIdentity,
                        runner: runnerSnapshot.identity,
                        configSHA256: receipt.restrictiveConfigSHA256,
                        skillTreeSHA256: receipt.seededSkillTreeSHA256,
                        skillsRootSHA256: receipt.skillsRootSHA256)
                        == "Codex origin executable identity changed")
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("runner-b".utf8), to: runnerFixture, finalMode: 0o500,
                allowReplacement: true)
            let replacementRunnerIdentity =
                try CodexIsolationFoundation.strongFileIdentity(
                    at: runnerFixture, includeCodeSigning: false)
            check("containment-runner origin replacement invalidates the receipt",
                  CodexIsolationFoundation.compatibilityReceiptBoundaryFailure(
                    receipt: receipt,
                    originExecutable: binaryIdentity,
                    executable: snapshot.identity,
                    originRunner: replacementRunnerIdentity,
                    runner: runnerSnapshot.identity,
                    configSHA256: receipt.restrictiveConfigSHA256,
                    skillTreeSHA256: receipt.seededSkillTreeSHA256,
                    skillsRootSHA256: receipt.skillsRootSHA256)
                    == "Codex containment-runner origin identity changed")
            check("containment-runner snapshot replacement invalidates the receipt",
                  CodexIsolationFoundation.compatibilityReceiptBoundaryFailure(
                    receipt: receipt,
                    originExecutable: binaryIdentity,
                    executable: snapshot.identity,
                    originRunner: runnerIdentity,
                    runner: replacementRunnerIdentity,
                    configSHA256: receipt.restrictiveConfigSHA256,
                    skillTreeSHA256: receipt.seededSkillTreeSHA256,
                    skillsRootSHA256: receipt.skillsRootSHA256)
                    == "Codex containment-runner snapshot identity changed")
            check("config drift invalidates the receipt",
                  CodexIsolationFoundation.compatibilityReceiptBoundaryFailure(
                    receipt: receipt,
                    originExecutable: binaryIdentity,
                    executable: snapshot.identity,
                    originRunner: runnerIdentity,
                    runner: runnerSnapshot.identity,
                    configSHA256: String(repeating: "1", count: 64),
                    skillTreeSHA256: receipt.seededSkillTreeSHA256,
                    skillsRootSHA256: receipt.skillsRootSHA256)
                    == "Codex restrictive config changed")

            let liveRoot = root.appendingPathComponent("live", isDirectory: true)
            let candidateRoot = root.appendingPathComponent("candidate", isDirectory: true)
            try CodexIsolationFoundation.secureDirectory(liveRoot)
            try CodexIsolationFoundation.secureDirectory(candidateRoot)
            let livePaths = CodexIsolationFoundation.scratchPaths(root: liveRoot)
            let candidatePaths = CodexIsolationFoundation.scratchPaths(root: candidateRoot)
            try CodexIsolationFoundation.prepareDirectories(livePaths)
            try CodexIsolationFoundation.prepareDirectories(candidatePaths)
            let oldSkill = livePaths.systemSkills.appendingPathComponent("old/SKILL.md")
            let candidateSkill = candidatePaths.systemSkills
                .appendingPathComponent("new/SKILL.md")
            for directory in [
                oldSkill.deletingLastPathComponent(),
                candidateSkill.deletingLastPathComponent(),
            ] {
                try CodexIsolationFoundation.secureDirectory(directory)
            }
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("old-skill".utf8), to: oldSkill, finalMode: 0o400,
                allowReplacement: false)
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("new-skill".utf8), to: candidateSkill, finalMode: 0o400,
                allowReplacement: false)
            let oldConfig = Data("old-config\n".utf8)
            try CodexIsolationFoundation.stageConfig(oldConfig, at: livePaths.config)
            let auth = livePaths.home.appendingPathComponent("auth.json", isDirectory: false)
            let installation = livePaths.home.appendingPathComponent(
                ".installation_identity", isDirectory: false)
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("SYNTHETIC_OPAQUE_AUTH".utf8), to: auth, finalMode: 0o400,
                allowReplacement: false)
            try CodexIsolationFoundation.atomicRestrictiveWrite(
                Data("SYNTHETIC_INSTALLATION_ID".utf8), to: installation,
                finalMode: 0o400, allowReplacement: false)
            let opaqueAuthDigest = try digest(auth)
            let opaqueInstallationDigest = try digest(installation)

            try CodexIsolationFoundation.installAppOwnedBoundaryAssets(
                livePaths: livePaths,
                candidateSystemSkills: candidatePaths.systemSkills,
                restrictiveConfig: config,
                receiptBytes: receiptBytes)
            let installedTree = try CodexIsolationFoundation.inspectSeededSkillTree(
                systemSkills: livePaths.systemSkills)
            check("app-owned .system reseed and restrictive config install together",
                  try (installedTree.entries.contains(where: {
                      $0.relativePath == "new/SKILL.md"
                  }) && Data(contentsOf: livePaths.config) == config))
            check("successful reseed preserves auth and installation identity as opaque bytes",
                  try (digest(auth) == opaqueAuthDigest
                    && digest(installation) == opaqueInstallationDigest))

            let installedConfig = try Data(contentsOf: livePaths.config)
            let installedSchema = try Data(contentsOf: livePaths.schema)
            let installedReceipt = try Data(contentsOf: livePaths.compatibilityReceipt)
            let installedTreeHash = installedTree.identitySHA256
            var allFaultsSurfaced = true
            var allFaultsSafe = true
            for fault in CodexIsolationFoundation.BoundaryAssetInstallFault.allCases {
                if !FileManager.default.fileExists(
                    atPath: livePaths.compatibilityReceipt.path) {
                    try CodexIsolationFoundation.installAppOwnedBoundaryAssets(
                        livePaths: livePaths,
                        candidateSystemSkills: candidatePaths.systemSkills,
                        restrictiveConfig: installedConfig,
                        receiptBytes: installedReceipt)
                }
                let failed = throwsError {
                    try CodexIsolationFoundation.installAppOwnedBoundaryAssets(
                        livePaths: livePaths,
                        candidateSystemSkills: paths.systemSkills,
                        restrictiveConfig: Data("replacement-config\n".utf8),
                        receiptBytes: Data("replacement-receipt\n".utf8),
                        fault: fault)
                }
                allFaultsSurfaced = allFaultsSurfaced && failed
                let invalidatingFault =
                    fault == .beforeRestore || fault == .beforeCleanup
                let receiptExists = FileManager.default.fileExists(
                    atPath: livePaths.compatibilityReceipt.path)
                let skillsChildren = try FileManager.default.contentsOfDirectory(
                    atPath: livePaths.skillsRoot.path)
                let transactionArtifacts = try FileManager.default.contentsOfDirectory(
                    atPath: livePaths.home.deletingLastPathComponent().path)
                    .filter { $0.hasPrefix(".codex-boundary-transaction-") }
                let rollbackMatches = try
                    CodexIsolationFoundation.inspectSeededSkillTree(
                        systemSkills: livePaths.systemSkills).identitySHA256
                        == installedTreeHash
                    && Data(contentsOf: livePaths.config) == installedConfig
                    && Data(contentsOf: livePaths.schema) == installedSchema
                    && (!receiptExists
                        || Data(contentsOf: livePaths.compatibilityReceipt)
                            == installedReceipt)
                let boundaryStateSafe = invalidatingFault
                    ? !receiptExists
                    : receiptExists && rollbackMatches
                allFaultsSafe = allFaultsSafe
                    && skillsChildren == [".system"]
                    && transactionArtifacts.isEmpty
                    && boundaryStateSafe
            }
            check("staging, every install boundary, restore, and cleanup faults surface",
                  allFaultsSurfaced)
            check("every transaction fault rolls back or leaves no valid receipt/loadable sibling",
                  allFaultsSafe)
            check("failed reseed never touches opaque auth or installation identity",
                  try (digest(auth) == opaqueAuthDigest
                    && digest(installation) == opaqueInstallationDigest))

            let runner = try runRunner(runnerPath: runnerPath, scratchRoot: root)
            print(runner.output.trimmingCharacters(in: .whitespacesAndNewlines))
            check("external containment runner deterministic selftest", runner.status == 0 && runner.output.contains("CONTAINMENT SELFTEST PASS"))
        } catch {
            reporter.record("setup", false, String(describing: error))
        }

        print(reporter.passed ? "[codex-s1-selftest] PASS" : "[codex-s1-selftest] FAIL")
        return reporter.passed
    }

    private static func mode(_ url: URL) throws -> mode_t {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw CodexIsolationError.failed("mode lookup failed") }
        return st.st_mode & 0o777
    }

    private static func digest(_ url: URL) throws -> String {
        CodexIsolationFoundation.sha256Hex(try Data(contentsOf: url))
    }

    private static func throwsError(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    private static func errorDescription(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as CodexIsolationError {
            return error.description
        } catch {
            return String(describing: error)
        }
    }

    private static func runRunner(runnerPath: String, scratchRoot: URL) throws -> (status: Int32, output: String) {
        let privateScratch = scratchRoot
            .appendingPathComponent("runner", isDirectory: true).path
        let runnerScratch: String
        if privateScratch.hasPrefix("/private/tmp/") {
            runnerScratch = "/tmp/" + privateScratch.dropFirst(
                "/private/tmp/".count)
        } else {
            runnerScratch = privateScratch
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runnerPath)
        process.arguments = ["selftest", "--scratch-root",
                             runnerScratch]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
