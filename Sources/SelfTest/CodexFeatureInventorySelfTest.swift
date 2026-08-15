import Foundation

enum CodexFeatureInventorySelfTest {
    private static let syntheticFeatureListFixture = """
    Name Stage Enabled
    apps                         experimental   false
    fast_mode                    stable         true
    shell_tool                   under development     false
    """

    private static let realHeaderlessFeatureListFixture = """
    apply_patch_freeform                 removed            false
    apply_patch_streaming_events         under development  false
    apps                                 stable             true
    collaboration_modes                  removed            true
    item_ids                             removed            true
    network_proxy                        experimental       false
    use_legacy_landlock                  deprecated         false
    workspace_dependencies               stable             true
    """

    static func run() -> Bool {
        print("=== Codex feature inventory parser and diff selftest ===")
        let reporter = SelfTestReporter()
        let check = reporter.check

        do {
            let syntheticTestBundle = URL(
                fileURLWithPath:
                    "/private/tmp/viddydictate-build/ViddyDictateTests.app",
                isDirectory: true)
            check("host inventory resolves the shipping containment runner",
                  CodexFeatureInventoryTool.shippingRunnerPath(
                    bundleURL: syntheticTestBundle)
                    == "/private/tmp/viddydictate-build/ViddyDictate.app/Contents/Helpers/CodexContainmentRunner")

            let parsed = try CodexIsolationFoundation.parseFeatureInventory(
                syntheticFeatureListFixture)
            check("parses the complete headed synthetic feature inventory",
                  parsed == [
                    "apps": .init(name: "apps", stage: .experimental, enabled: false),
                    "fast_mode": .init(name: "fast_mode", stage: .stable, enabled: true),
                    "shell_tool": .init(
                        name: "shell_tool", stage: .underDevelopment, enabled: false),
                  ])
            let equivalentHeadedInventory =
                try CodexIsolationFoundation.parseFeatureInventory(
                    "Name Stage Enabled\n\(realHeaderlessFeatureListFixture)")
            do {
                let realHeaderlessInventory =
                    try CodexIsolationFoundation.parseFeatureInventory(
                        realHeaderlessFeatureListFixture)
                check("real headerless feature inventory matches headed compatibility input",
                      realHeaderlessInventory == equivalentHeadedInventory)
            } catch let error as CodexIsolationError {
                reporter.record(
                    "real headerless feature inventory matches headed compatibility input",
                    false,
                    error.description)
            }
            let fakeCodexOutput = try runFakeCodexFeatureList()
            let fakeCodexInventory =
                try CodexIsolationFoundation.parseFeatureInventory(
                    fakeCodexOutput)
            check("end-to-end fake Codex inventory rail accepts the real headerless shape",
                  fakeCodexOutput == realHeaderlessFeatureListFixture + "\n"
                    && fakeCodexInventory == equivalentHeadedInventory)

            let expected: [String: CodexIsolationFoundation.FeatureInventoryEntry] = [
                "apps": .init(name: "apps", stage: .experimental, enabled: false),
                "removed_fixture": .init(
                    name: "removed_fixture", stage: .removed, enabled: false),
                "shell_tool": .init(
                    name: "shell_tool", stage: .underDevelopment, enabled: true),
            ]
            let diff = CodexIsolationFoundation.featureInventoryDiff(
                current: parsed, expected: expected)
            check("diff reports added features in sorted order",
                  diff.added == [
                    .init(name: "fast_mode", stage: .stable, enabled: true),
                  ])
            check("diff reports removed features in sorted order",
                  diff.removed == [
                    .init(name: "removed_fixture", stage: .removed, enabled: false),
                  ])
            check("diff reports stage/state changes with expected and actual entries",
                  diff.stateChanged == [
                    .init(
                        name: "shell_tool",
                        expected: .init(
                            name: "shell_tool", stage: .underDevelopment, enabled: true),
                        actual: .init(
                            name: "shell_tool", stage: .underDevelopment, enabled: false)),
                  ])
            check("exact full inventories produce an empty diff",
                  CodexIsolationFoundation.featureInventoryDiff(
                    current: parsed, expected: parsed).isEmpty)

            let currentFirst = try fixture("codex-features-0.146-first.txt")
            let currentSecond = try fixture("codex-features-0.146-restrictive.txt")
            let currentFirstInventory = try CodexIsolationFoundation.parseFeatureInventory(
                currentFirst)
            let currentSecondInventory = try CodexIsolationFoundation.parseFeatureInventory(
                currentSecond)
            check("current 0.146 staged two-pass inventory is compatibility-auditable",
                  CodexIsolationFoundation.featureInventoryBoundaryFailure(
                    firstPass: currentFirstInventory,
                    restrictivePass: currentSecondInventory) == nil)
            let acceptedTombstones =
                CodexIsolationFoundation.acceptedUnforceableEnabledFeatures
            check("0.146 removed-true tombstone allowlist is exact and does not generalize",
                  Set(acceptedTombstones.keys) == [
                    "collaboration_modes", "item_ids", "resize_all_images", "sqlite", "steer",
                    "terminal_resize_reflow", "tool_search_always_defer_mcp_tools",
                    "tui_app_server",
                  ] && acceptedTombstones.values.allSatisfy {
                      $0.stage == .removed
                        && $0.transformToolNames.isEmpty
                        && $0.modelVisiblePromptMarkers.isEmpty
                        && $0.acceptedJSONLEventTypes.isEmpty
                  })
            check("0.146 collaboration_modes has a separate exact source/stage ruling",
                  acceptedTombstones["collaboration_modes"] == .init(
                    stage: .removed,
                    behavior: .collaborationModeTUI,
                    reason: "rust-v0.146.0-alpha.3.1: behavior is always collaboration-modes-enabled; headless transform exposes no tool, prompt/context, or JSONL event class"))
            check("0.146 item_ids has a separate exact bookkeeping ruling",
                  acceptedTombstones["item_ids"] == .init(
                    stage: .removed,
                    behavior: .responseItemBookkeeping,
                    reason: "rust-v0.146.0-alpha.3.1: always-on response item IDs are additive bookkeeping; no new tool, prompt/context, or JSONL event class"))
            check("0.146 sqlite has a separate exact app-owned persistence ruling",
                  acceptedTombstones["sqlite"] == .init(
                    stage: .removed,
                    behavior: .appOwnedRolloutMetadata,
                    reason: "rust-v0.146.0-alpha.3.1: rollout metadata stays under app-owned sqlite_home; no transform tool, prompt/context, or JSONL event class"))
            check("0.146 steer has a separate exact TUI-only ruling",
                  acceptedTombstones["steer"] == .init(
                    stage: .removed,
                    behavior: .steerTUIQueueing,
                    reason: "rust-v0.146.0-alpha.3.1: behavior is always steer-enabled only for TUI queueing; headless transform exposes no tool, prompt/context, or JSONL event class"))
            check("0.146 forceable additions are dynamically disabled",
                  Set(["code_mode_buffered_exec", "executor_capability_discovery", "mcp_2026_07_28"])
                    .isSubset(of: Set(CodexIsolationFoundation.restrictiveFeatureNames(
                        from: currentFirstInventory))))
            check("removed/deprecated 0.146 keys are never emitted into strict config",
                  Set(CodexIsolationFoundation.restrictiveFeatureNames(
                    from: currentFirstInventory)).isDisjoint(with: [
                        "apply_patch_freeform", "item_ids", "use_legacy_landlock",
                        "web_search_cached", "web_search_request",
                    ]))

            let futureAddedFirst = currentFirstInventory.merging([
                "future_forceable": .init(
                    name: "future_forceable", stage: .underDevelopment, enabled: false),
            ]) { _, new in new }
            let futureAddedSecond = currentSecondInventory.merging([
                "future_forceable": .init(
                    name: "future_forceable", stage: .underDevelopment, enabled: false),
            ]) { _, new in new }
            check("a future added false forceable feature passes without a source pin",
                  CodexIsolationFoundation.featureInventoryBoundaryFailure(
                    firstPass: futureAddedFirst, restrictivePass: futureAddedSecond) == nil)

            let truncatedFirst = currentFirstInventory.filter {
                ["apply_patch_freeform", "item_ids"].contains($0.key)
            }
            let truncatedSecond = currentSecondInventory.filter {
                ["apply_patch_freeform", "item_ids"].contains($0.key)
            }
            check("identical truncated inventories cannot satisfy reviewed continuity",
                  CodexIsolationFoundation.featureInventoryAuditBaseline.count
                    == currentFirstInventory.count
                    && CodexIsolationFoundation.featureInventoryBoundaryFailure(
                        firstPass: truncatedFirst,
                        restrictivePass: truncatedSecond) != nil)

            var futureRemovedFirst = currentFirstInventory
            var futureRemovedSecond = currentSecondInventory
            futureRemovedFirst.removeValue(forKey: "apply_patch_streaming_events")
            futureRemovedSecond.removeValue(forKey: "apply_patch_streaming_events")
            check("disappearance of a prior forceable row fails continuity",
                  CodexIsolationFoundation.featureInventoryBoundaryFailure(
                    firstPass: futureRemovedFirst,
                    restrictivePass: futureRemovedSecond)
                    == "prior forceable feature disappeared: apply_patch_streaming_events")

            var removedDeprecatedFirst = currentFirstInventory
            var removedDeprecatedSecond = currentSecondInventory
            removedDeprecatedFirst.removeValue(forKey: "use_legacy_landlock")
            removedDeprecatedSecond.removeValue(forKey: "use_legacy_landlock")
            check("disappearance of a prior deprecated row remains acceptable",
                  CodexIsolationFoundation.featureInventoryBoundaryFailure(
                    firstPass: removedDeprecatedFirst,
                    restrictivePass: removedDeprecatedSecond) == nil)

            var futureTrue = currentSecondInventory
            futureTrue["future_forceable"] = .init(
                name: "future_forceable", stage: .stable, enabled: true)
            var futureTrueFirst = currentFirstInventory
            futureTrueFirst["future_forceable"] = .init(
                name: "future_forceable", stage: .stable, enabled: true)
            check("a future unforceable true feature fails closed",
                  CodexIsolationFoundation.featureInventoryBoundaryFailure(
                    firstPass: futureTrueFirst, restrictivePass: futureTrue)
                    == "forceable feature remained enabled: future_forceable")

            var unknownTombstoneFirst = currentFirstInventory
            var unknownTombstoneSecond = currentSecondInventory
            unknownTombstoneFirst["future_tombstone"] = .init(
                name: "future_tombstone", stage: .removed, enabled: true)
            unknownTombstoneSecond["future_tombstone"] = .init(
                name: "future_tombstone", stage: .removed, enabled: true)
            check("a new removed-stage true tombstone fails without exact source review",
                  CodexIsolationFoundation.featureInventoryBoundaryFailure(
                    firstPass: unknownTombstoneFirst,
                    restrictivePass: unknownTombstoneSecond)
                    == "unforceable enabled feature lacks an exact allowance: future_tombstone")

            var contradictorySecond = currentSecondInventory
            contradictorySecond["apps"] = .init(
                name: "apps", stage: .removed, enabled: false)
            check("a lifecycle-stage contradiction between passes fails closed",
                  CodexIsolationFoundation.featureInventoryBoundaryFailure(
                    firstPass: currentFirstInventory,
                    restrictivePass: contradictorySecond)
                    == "feature inventory changed between audit passes: apps")

            var contradictoryTombstoneSecond = currentSecondInventory
            contradictoryTombstoneSecond["item_ids"] = .init(
                name: "item_ids", stage: .removed, enabled: false)
            check("an unforceable tombstone state contradiction between passes fails closed",
                  CodexIsolationFoundation.featureInventoryBoundaryFailure(
                    firstPass: currentFirstInventory,
                    restrictivePass: contradictoryTombstoneSecond)
                    == "unforceable feature changed between audit passes: item_ids")
        } catch {
            reporter.record("synthetic feature fixture setup", false, String(describing: error))
        }

        check("parser rejects a non-Boolean state", throwsError {
            _ = try CodexIsolationFoundation.parseFeatureInventory("""
            Name Stage Enabled
            apps experimental maybe
            """)
        })
        check("parser rejects duplicate feature rows", throwsError {
            _ = try CodexIsolationFoundation.parseFeatureInventory("""
            Name Stage Enabled
            apps experimental false
            apps stable false
            """)
        })
        check("parser rejects an unknown lifecycle stage", throwsError {
            _ = try CodexIsolationFoundation.parseFeatureInventory("""
            Name Stage Enabled
            apps future false
            """)
        })
        check("parser rejects extra columns rather than guessing", throwsError {
            _ = try CodexIsolationFoundation.parseFeatureInventory("""
            Name Stage Enabled
            apps stable unexpected false
            """)
        })
        check("parser rejects a header after feature rows with the existing error", errorDescription {
            _ = try CodexIsolationFoundation.parseFeatureInventory("""
            apps stable false
            Name Stage Enabled
            """)
        } == "feature inventory contains a misplaced header")
        check("parser rejects a malformed header with the existing error", errorDescription {
            _ = try CodexIsolationFoundation.parseFeatureInventory("""
            Name Lifecycle Enabled
            apps stable false
            """)
        } == "feature inventory contains a misplaced header")
        check("parser rejects a duplicate header with the existing error", errorDescription {
            _ = try CodexIsolationFoundation.parseFeatureInventory("""
            Name Stage Enabled
            Name Stage Enabled
            apps stable false
            """)
        } == "feature inventory contains a misplaced header")
        check("parser rejects empty output", throwsError {
            _ = try CodexIsolationFoundation.parseFeatureInventory("\n")
        })
        check("parser rejects inventory output over the existing line bound", errorDescription {
            _ = try CodexIsolationFoundation.parseFeatureInventory(
                String(
                    repeating: "apps stable false\n",
                    count: CodexIsolationFoundation.maxFeatureInventoryLines + 1))
        } == "feature inventory exceeds line bound")
        check("parser rejects inventory output over the existing byte bound", errorDescription {
            _ = try CodexIsolationFoundation.parseFeatureInventory(
                String(repeating: "x", count: CodexIsolationFoundation.maxFeatureInventoryBytes + 1))
        } == "feature inventory exceeds byte bound")

        print(reporter.summaryLine(prefix: "[codex-feature-inventory-selftest]"))
        return reporter.passed
    }

    private static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: "Sources/SelfTest/Fixtures")
            .appendingPathComponent(name, isDirectory: false)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func runFakeCodexFeatureList() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "viddydictate-headerless-inventory-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try CodexIsolationFoundation.secureDirectory(root)
        let fakeCodex = root.appendingPathComponent("fake-codex", isDirectory: false)
        let script = """
        #!/bin/sh
        if [ "$#" -ne 2 ] || [ "$1" != "features" ] || [ "$2" != "list" ]; then
          exit 64
        fi
        /usr/bin/printf '%s\\n' \\
          'apply_patch_freeform                 removed            false' \\
          'apply_patch_streaming_events         under development  false' \\
          'apps                                 stable             true' \\
          'collaboration_modes                  removed            true' \\
          'item_ids                             removed            true' \\
          'network_proxy                        experimental       false' \\
          'use_legacy_landlock                  deprecated         false' \\
          'workspace_dependencies               stable             true'
        """
        try CodexIsolationFoundation.atomicRestrictiveWrite(
            Data(script.utf8),
            to: fakeCodex,
            finalMode: 0o500,
            allowReplacement: false)
        let result = try CodexIsolationFoundation.runBoundedProcess(
            executable: fakeCodex.path,
            arguments: ["features", "list"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
                "TERM": "dumb",
            ],
            currentDirectory: root,
            timeout: 2,
            stdoutLimit: CodexIsolationFoundation.maxFeatureInventoryBytes,
            stderrLimit: 1_024)
        guard result.status == 0,
              !result.timedOut,
              !result.stdoutOverflow,
              !result.stderrOverflow,
              result.stderr.isEmpty,
              result.leaderReaped,
              !result.residualProcessGroup,
              !result.captureFailure,
              let output = String(data: result.stdout, encoding: .utf8) else {
            throw CodexIsolationError.failed(
                "synthetic fake Codex inventory command failed")
        }
        return output
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

    private static func throwsError(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch {
            return true
        }
    }
}
