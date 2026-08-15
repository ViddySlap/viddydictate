import CryptoKit
import Darwin
import Foundation

enum CodexIsolationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Unauthenticated, provider-independent foundation for the future Codex transform arm.
///
/// This type owns only deterministic bytes and local filesystem mechanics. It never performs a model
/// call, reads an auth file, or consults the user's normal Codex home. Production provider integration
/// uses these exact profile/stdin/JSONL contracts through the external containment runner.
enum CodexIsolationFoundation {
    static let codexBinary = "/Applications/ChatGPT.app/Contents/Resources/codex"
    /// Diagnostic evidence only. Compatibility is earned by an exact-binary receipt, never by
    /// comparing this text to the candidate CLI's reported version.
    static let lastReviewedCLIVersion = "codex-cli 0.146.0-alpha.3.1"
    static let pinnedCLIVersion = lastReviewedCLIVersion
    static let model = "gpt-5.6-sol"
    static let effort = "xhigh"
    static let envelopeVersion = "viddydictate-transform-v1"
    static let profilePrefix = "route-"
    static let schemaFilename = "transform-output.schema.json"
    static let routeAuditMarker = "VIDDYDICTATE_SYNTHETIC_ROUTE_AUDIT_S1"
    static let userAuditMarker = "VIDDYDICTATE_SYNTHETIC_USER_AUDIT_S1"
    static let vaultLeakMarkers = ["Available skills", "skills_instructions", "SKILL.md", "ViddyVault"]

    static let maxFeatureInventoryBytes = 262_144
    static let maxFeatureInventoryLines = 512
    static let maxOpaqueRouteValueBytes = 65_536

    /// Reviewed continuity floor captured from the accepted 0.146 first-pass inventory. This is not
    /// an enabled-feature allowlist: new false rows remain adoptable, while disappearance of a
    /// previously forceable row fails closed. Deprecated/removed rows may disappear.
    private static let reviewedFeatureInventoryText = """
    Name Stage Enabled
    apply_patch_freeform removed false
    apply_patch_streaming_events under development false
    apps stable true
    apps_mcp_path_override removed false
    artifact under development false
    auth_elicitation stable true
    browser_use stable true
    browser_use_external stable true
    browser_use_full_cdp_access stable true
    chronicle under development false
    code_mode under development false
    code_mode_buffered_exec under development false
    code_mode_host stable true
    code_mode_only under development false
    codex_git_commit removed false
    collaboration_modes removed true
    computer_use stable true
    concurrent_reasoning_summaries under development false
    current_time_reminder under development false
    default_mode_request_user_input under development false
    deferred_executor under development false
    elevated_windows_sandbox removed false
    enable_fanout removed false
    enable_mcp_apps under development false
    enable_request_compression stable true
    exec_permission_approvals under development false
    executor_capability_discovery under development false
    experimental_windows_sandbox removed false
    external_agent_memory_import under development false
    external_migration removed false
    fast_mode stable true
    goals stable true
    guardian_approval stable true
    hooks stable true
    image_detail_original removed false
    image_generation stable true
    in_app_browser stable true
    item_ids removed true
    js_repl removed false
    js_repl_tools_only removed false
    local_thread_store_compression under development false
    mcp_2026_07_28 under development false
    memories stable false
    mentions_v2 stable true
    multi_agent stable true
    multi_agent_mode removed false
    multi_agent_v2 stable false
    network_proxy experimental false
    non_prefixed_mcp_tool_names under development false
    personality stable true
    plugin_hooks removed false
    plugin_sharing stable true
    plugins stable true
    prevent_idle_sleep experimental false
    realtime_conversation under development false
    remote_compaction_v2 stable true
    remote_control removed false
    remote_models removed false
    remote_plugin stable true
    request_permissions_tool under development false
    request_rule removed false
    resize_all_images removed true
    respect_system_proxy under development false
    responses_websockets removed false
    responses_websockets_v2 removed false
    rollout_budget under development false
    runtime_metrics under development false
    search_tool removed false
    secret_auth_storage stable false
    shell_snapshot stable true
    shell_tool stable true
    shell_zsh_fork under development false
    skill_env_var_dependency_prompt removed false
    skill_mcp_dependency_install stable true
    skill_search stable true
    sqlite removed true
    standalone_web_search under development false
    steer removed true
    terminal_resize_reflow removed true
    terminal_visualization_instructions under development false
    token_budget under development false
    tool_call_mcp_elicitation stable true
    tool_search removed false
    tool_search_always_defer_mcp_tools removed true
    tool_suggest stable true
    tui_app_server removed true
    unavailable_dummy_tools removed false
    undo removed false
    unified_exec stable true
    unified_exec_zsh_fork under development false
    use_agent_identity under development false
    use_legacy_landlock deprecated false
    use_linux_sandbox_bwrap removed false
    web_search_cached deprecated false
    web_search_request deprecated false
    workspace_dependencies stable true
    workspace_owner_usage_nudge removed false
    """

    enum FeatureStage: String, Codable, CaseIterable {
        case stable
        case experimental
        case underDevelopment = "under development"
        case deprecated
        case removed

        var isForceable: Bool { self != .deprecated && self != .removed }
    }

    struct FeatureInventoryEntry: Codable, Equatable {
        let name: String
        let stage: FeatureStage
        let enabled: Bool
    }

    struct FeatureInventoryStateChange: Equatable {
        let name: String
        let expected: FeatureInventoryEntry
        let actual: FeatureInventoryEntry
    }

    struct FeatureInventoryDiff {
        let added: [FeatureInventoryEntry]
        let removed: [FeatureInventoryEntry]
        let stateChanged: [FeatureInventoryStateChange]

        var isEmpty: Bool {
            added.isEmpty && removed.isEmpty && stateChanged.isEmpty
        }
    }

    enum ReviewedTombstoneBehavior: String, Codable {
        case collaborationModeTUI
        case responseItemBookkeeping
        case appOwnedRolloutMetadata
        case steerTUIQueueing
        case textOnlyImagePreparation
        case headlessTerminalReflow
        case emptyMCPDeferral
        case headlessTUIAppServer
    }

    struct UnforceableEnabledFeatureAllowance: Equatable {
        let stage: FeatureStage
        let behavior: ReviewedTombstoneBehavior
        let reason: String

        var transformToolNames: Set<String> { [] }
        var modelVisiblePromptMarkers: Set<String> { [] }
        var acceptedJSONLEventTypes: Set<String> { [] }
    }

    /// Exact source-reviewed true tombstones only. The 0.146 additions were checked against
    /// openai/codex tag rust-v0.146.0-alpha.3.1, commit
    /// ff75c5b939c477c49eb1bd5248da6dab71b109d1. Do not generalize this table.
    static let acceptedUnforceableEnabledFeatures:
        [String: UnforceableEnabledFeatureAllowance] = [
        "collaboration_modes": .init(
            stage: .removed,
            behavior: .collaborationModeTUI,
            reason: "rust-v0.146.0-alpha.3.1: behavior is always collaboration-modes-enabled; headless transform exposes no tool, prompt/context, or JSONL event class"),
        "item_ids": .init(
            stage: .removed,
            behavior: .responseItemBookkeeping,
            reason: "rust-v0.146.0-alpha.3.1: always-on response item IDs are additive bookkeeping; no new tool, prompt/context, or JSONL event class"),
        "resize_all_images": .init(
            stage: .removed,
            behavior: .textOnlyImagePreparation,
            reason: "removed always-on image preparation; no images enter the text-only transform envelope"),
        "sqlite": .init(
            stage: .removed,
            behavior: .appOwnedRolloutMetadata,
            reason: "rust-v0.146.0-alpha.3.1: rollout metadata stays under app-owned sqlite_home; no transform tool, prompt/context, or JSONL event class"),
        "steer": .init(
            stage: .removed,
            behavior: .steerTUIQueueing,
            reason: "rust-v0.146.0-alpha.3.1: behavior is always steer-enabled only for TUI queueing; headless transform exposes no tool, prompt/context, or JSONL event class"),
        "terminal_resize_reflow": .init(
            stage: .removed,
            behavior: .headlessTerminalReflow,
            reason: "removed terminal reflow tombstone; no TUI exists in the headless TERM=dumb boundary"),
        "tool_search_always_defer_mcp_tools": .init(
            stage: .removed,
            behavior: .emptyMCPDeferral,
            reason: "removed MCP deferral tombstone; audited transform MCP inventory is empty"),
        "tui_app_server": .init(
            stage: .removed,
            behavior: .headlessTUIAppServer,
            reason: "removed app-server TUI tombstone; no TUI exists in the headless transform boundary"),
    ]

    static func parseFeatureInventory(_ output: String)
        throws -> [String: FeatureInventoryEntry] {
        guard output.utf8.count <= maxFeatureInventoryBytes else {
            throw CodexIsolationError.failed("feature inventory exceeds byte bound")
        }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count <= maxFeatureInventoryLines else {
            throw CodexIsolationError.failed("feature inventory exceeds line bound")
        }

        var inventory: [String: FeatureInventoryEntry] = [:]
        // The real CLI is headerless. Retain one leading headed form only as compatibility input.
        var acceptedHeader = false

        for line in lines {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let first = fields.first, let last = fields.last else { continue }

            if first.lowercased() == "name" && last.lowercased() == "enabled" {
                guard fields.map({ $0.lowercased() }) == ["name", "stage", "enabled"],
                      !acceptedHeader, inventory.isEmpty else {
                    throw CodexIsolationError.failed("feature inventory contains a misplaced header")
                }
                acceptedHeader = true
                continue
            }

            let name: String
            let stageText: String
            let stateText: String
            if fields.count == 3 {
                name = fields[0]
                stageText = fields[1]
                stateText = fields[2]
            } else if fields.count == 4, fields[1] == "under",
                      fields[2] == "development" {
                name = fields[0]
                stageText = "under development"
                stateText = fields[3]
            } else {
                throw CodexIsolationError.failed("feature inventory contains an invalid row")
            }
            guard name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#,
                             options: .regularExpression) != nil,
                  let stage = FeatureStage(rawValue: stageText),
                  stateText == "true" || stateText == "false" else {
                throw CodexIsolationError.failed("feature inventory contains an invalid row")
            }
            let entry = FeatureInventoryEntry(
                name: name, stage: stage, enabled: stateText == "true")
            guard inventory.updateValue(entry, forKey: name) == nil else {
                throw CodexIsolationError.failed("feature inventory contains a duplicate feature")
            }
        }

        guard !inventory.isEmpty else {
            throw CodexIsolationError.failed("feature inventory is empty")
        }
        return inventory
    }

    static func featureInventoryDiff(
        current: [String: FeatureInventoryEntry],
        expected: [String: FeatureInventoryEntry]
    ) -> FeatureInventoryDiff {
        let added = current.keys.filter { expected[$0] == nil }.sorted().map {
            current[$0]!
        }
        let removed = expected.keys.filter { current[$0] == nil }.sorted().map {
            expected[$0]!
        }
        let stateChanged = current.keys.filter {
            expected[$0] != nil && expected[$0] != current[$0]
        }.sorted().map {
            FeatureInventoryStateChange(
                name: $0, expected: expected[$0]!, actual: current[$0]!)
        }
        return FeatureInventoryDiff(added: added, removed: removed, stateChanged: stateChanged)
    }

    static func featureInventoryBoundaryFailure(
        firstPass: [String: FeatureInventoryEntry],
        restrictivePass: [String: FeatureInventoryEntry],
        continuityBaseline: [String: FeatureInventoryEntry] = featureInventoryAuditBaseline,
        acceptedEnabled:
            [String: UnforceableEnabledFeatureAllowance] =
                acceptedUnforceableEnabledFeatures
    ) -> String? {
        let names = Set(firstPass.keys).union(restrictivePass.keys).sorted()
        for name in names {
            guard let first = firstPass[name], let restrictive = restrictivePass[name],
                  first.name == name, restrictive.name == name,
                  first.stage == restrictive.stage else {
                return "feature inventory changed between audit passes: \(name)"
            }
            if first.stage.isForceable {
                if restrictive.enabled {
                    return "forceable feature remained enabled: \(name)"
                }
            } else {
                guard first.enabled == restrictive.enabled else {
                    return "unforceable feature changed between audit passes: \(name)"
                }
                if !restrictive.enabled { continue }
                guard let allowance = acceptedEnabled[name],
                      allowance.stage == restrictive.stage,
                      allowance.transformToolNames.isEmpty,
                      allowance.modelVisiblePromptMarkers.isEmpty,
                      allowance.acceptedJSONLEventTypes.isEmpty else {
                    return "unforceable enabled feature lacks an exact allowance: \(name)"
                }
            }
        }
        if let stale = acceptedEnabled.keys.sorted().first(where: {
            guard let entry = restrictivePass[$0] else { return false }
            return !entry.enabled || entry.stage != acceptedEnabled[$0]?.stage
        }) {
            return "enabled tombstone allowance does not match inventory: \(stale)"
        }
        if let continuity = featureInventoryContinuityFailure(
            current: firstPass, baseline: continuityBaseline) {
            return continuity
        }
        return nil
    }

    static func featureInventoryContinuityFailure(
        current: [String: FeatureInventoryEntry],
        baseline: [String: FeatureInventoryEntry]
    ) -> String? {
        guard !baseline.isEmpty else { return "feature inventory continuity baseline is empty" }
        for name in baseline.keys.sorted() {
            guard let prior = baseline[name] else { continue }
            if current[name] == nil && prior.stage.isForceable {
                return "prior forceable feature disappeared: \(name)"
            }
        }
        return nil
    }

    static func restrictiveFeatureNames(
        from inventory: [String: FeatureInventoryEntry]
    ) -> [String] {
        inventory.values.filter { $0.stage.isForceable }.map(\ .name).sorted()
    }

    static var featureInventoryAuditBaseline: [String: FeatureInventoryEntry] {
        // Source-owned bytes are fixed and covered by the executable signature. A failure here is a
        // programmer error, not untrusted runtime input.
        try! parseFeatureInventory(reviewedFeatureInventoryText)
    }

    static var featureInventoryPinStatus: String {
        "inventory receipt-bound"
    }

    struct Paths {
        let home: URL
        let cwd: URL
        let temp: URL

        var sqlite: URL { home.appendingPathComponent("sqlite", isDirectory: true) }
        var schema: URL { home.appendingPathComponent(schemaFilename, isDirectory: false) }
        var config: URL { home.appendingPathComponent("config.toml", isDirectory: false) }
        var compatibilityReceipt: URL {
            home.appendingPathComponent(
                "compatibility-receipt.json", isDirectory: false)
        }
        var boundaryLock: URL {
            home.deletingLastPathComponent().appendingPathComponent(
                ".codex-compatibility.lock", isDirectory: false)
        }
        var systemSkills: URL {
            skillsRoot
                .appendingPathComponent(".system", isDirectory: true)
        }
        var skillsRoot: URL {
            home.appendingPathComponent("skills", isDirectory: true)
        }
        var executableStore: URL {
            home.deletingLastPathComponent().appendingPathComponent(
                "codex-executables", isDirectory: true)
        }
        func executableSnapshot(filename: String) -> URL {
            executableStore.appendingPathComponent(filename, isDirectory: false)
        }
        var runnerStore: URL {
            home.deletingLastPathComponent().appendingPathComponent(
                "codex-runners", isDirectory: true)
        }
        func runnerSnapshot(filename: String) -> URL {
            runnerStore.appendingPathComponent(filename, isDirectory: false)
        }
    }

    struct RouteProfile {
        let name: String
        let hash: String
        let bytes: Data

        func url(in paths: Paths) -> URL {
            paths.home.appendingPathComponent("\(name).config.toml", isDirectory: false)
        }
    }

    struct CheapFileIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let mode: UInt16
    }

    struct CodeSigningIdentity: Codable, Equatable {
        let identifier: String
        let cdHash: String
        let teamIdentifier: String?
    }

    struct StrongFileIdentity: Codable, Equatable {
        let cheap: CheapFileIdentity
        let sha256: String
        let codeSigning: CodeSigningIdentity?
    }

    struct CompatibilityReceipt: Codable, Equatable {
        static let currentFormatVersion = 3

        let formatVersion: Int
        let originExecutable: StrongFileIdentity
        let executable: StrongFileIdentity
        let executableSnapshotFilename: String
        let originRunner: StrongFileIdentity
        let runner: StrongFileIdentity
        let runnerSnapshotFilename: String
        let cliVersion: String
        let restrictiveConfigSHA256: String
        let effectiveFeatures: [FeatureInventoryEntry]
        let featureContinuityBaseline: [FeatureInventoryEntry]
        let seededSkillTreeSHA256: String
        let skillsRootSHA256: String
        let schemaSHA256: String
        let executionContractSHA256: String

        init(
            originExecutable: StrongFileIdentity,
            executable: StrongFileIdentity,
            executableSnapshotFilename: String,
            originRunner: StrongFileIdentity,
            runner: StrongFileIdentity,
            runnerSnapshotFilename: String,
            cliVersion: String,
            restrictiveConfigSHA256: String,
            effectiveFeatures: [FeatureInventoryEntry],
            featureContinuityBaseline: [FeatureInventoryEntry],
            seededSkillTreeSHA256: String,
            skillsRootSHA256: String,
            schemaSHA256: String,
            executionContractSHA256: String
        ) {
            self.formatVersion = Self.currentFormatVersion
            self.originExecutable = originExecutable
            self.executable = executable
            self.executableSnapshotFilename = executableSnapshotFilename
            self.originRunner = originRunner
            self.runner = runner
            self.runnerSnapshotFilename = runnerSnapshotFilename
            self.cliVersion = cliVersion
            self.restrictiveConfigSHA256 = restrictiveConfigSHA256
            self.effectiveFeatures = effectiveFeatures
            self.featureContinuityBaseline = featureContinuityBaseline
            self.seededSkillTreeSHA256 = seededSkillTreeSHA256
            self.skillsRootSHA256 = skillsRootSHA256
            self.schemaSHA256 = schemaSHA256
            self.executionContractSHA256 = executionContractSHA256
        }
    }

    enum SeededSkillTreeEntryKind: String, Codable {
        case directory
        case regularFile
    }

    struct SeededSkillTreeEntry: Codable, Equatable {
        let relativePath: String
        let kind: SeededSkillTreeEntryKind
        let mode: UInt16
        let sha256: String?
    }

    struct SeededSkillTreeInspection {
        let entries: [SeededSkillTreeEntry]
        let skillFiles: [URL]
        let identitySHA256: String
    }

    struct DedicatedSkillsRootInspection {
        let systemTree: SeededSkillTreeInspection
        let identitySHA256: String
    }

    struct BoundedProcessResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
        let stdoutOverflow: Bool
        let stderrOverflow: Bool
        let leaderReaped: Bool
        let residualProcessGroup: Bool
        let captureFailure: Bool
    }

    enum BoundaryAssetInstallFault: CaseIterable {
        case afterSkillsStaged
        case afterConfigStaged
        case afterSchemaStaged
        case afterReceiptStaged
        case beforeSkillsInstall
        case afterSkillsInstall
        case beforeConfigInstall
        case afterConfigInstall
        case beforeSchemaInstall
        case afterSchemaInstall
        case beforeReceiptInstall
        case afterReceiptInstall
        case beforeRestore
        case beforeCleanup
    }

    static func productionPaths(fileManager fm: FileManager = .default) throws -> Paths {
        guard !fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).isEmpty,
              let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CodexIsolationError.failed("could not resolve user app-owned directories")
        }
        let appRoot = AppPaths.applicationSupportDirectory(fileManager: fm)
        let cacheRoot = caches.appendingPathComponent("ViddyDictate", isDirectory: true)
        return Paths(
            home: appRoot.appendingPathComponent("codex-home", isDirectory: true),
            cwd: appRoot.appendingPathComponent("codex-cwd", isDirectory: true),
            temp: cacheRoot.appendingPathComponent("codex-tmp", isDirectory: true)
        )
    }

    static func scratchPaths(root: URL) -> Paths {
        Paths(
            home: root.appendingPathComponent("codex-home", isDirectory: true),
            cwd: root.appendingPathComponent("codex-cwd", isDirectory: true),
            temp: root.appendingPathComponent("codex-tmp", isDirectory: true)
        )
    }

    static func prepareDirectories(_ paths: Paths, fileManager fm: FileManager = .default) throws {
        for directory in [paths.home, paths.cwd, paths.temp, paths.sqlite] {
            try secureDirectory(directory, fileManager: fm)
        }
    }

    static func baseConfig(
        paths: Paths,
        disabledSkillPaths: [URL],
        featureInventory: [String: FeatureInventoryEntry] = [:]
    ) throws -> Data {
        let normalizedSkills = try disabledSkillPaths.map { try canonicalPath($0) }
        return try renderBaseConfig(
            paths: paths,
            canonicalDisabledSkillPaths: normalizedSkills,
            featureInventory: featureInventory)
    }

    /// Render config for live skill leaves that the boundary transaction has not installed yet.
    /// The live home already exists; the transaction later installs a symlink-free app-owned
    /// `skills/.system` tree, so validated relative components can be appended without aliasing.
    static func preinstallBaseConfig(
        paths: Paths,
        disabledSkillPaths: [URL],
        featureInventory: [String: FeatureInventoryEntry] = [:]
    ) throws -> Data {
        let normalizedSkills = try canonicalPreinstallSkillPaths(
            paths: paths, disabledSkillPaths: disabledSkillPaths)
        return try renderBaseConfig(
            paths: paths,
            canonicalDisabledSkillPaths: normalizedSkills,
            featureInventory: featureInventory)
    }

    private static func renderBaseConfig(
        paths: Paths,
        canonicalDisabledSkillPaths: [String],
        featureInventory: [String: FeatureInventoryEntry]
    ) throws -> Data {
        let normalizedSkills = canonicalDisabledSkillPaths.sorted()
        guard Set(normalizedSkills).count == normalizedSkills.count else {
            throw CodexIsolationError.failed("duplicate seeded-skill path")
        }

        var lines = [
            "model = \(tomlString(model))",
            "model_reasoning_effort = \(tomlString(effort))",
            "sandbox_mode = \"read-only\"",
            "approval_policy = \"never\"",
            "web_search = \"disabled\"",
            "project_doc_max_bytes = 0",
            "project_root_markers = []",
            "check_for_update_on_startup = false",
            "sqlite_home = \(tomlString(try canonicalPath(paths.sqlite)))",
            "",
            "[history]",
            "persistence = \"none\"",
            "",
            "[analytics]",
            "enabled = false",
            "",
            "[feedback]",
            "enabled = false",
            "",
            "[features]",
        ]
        lines.append(contentsOf: restrictiveFeatureNames(
            from: featureInventory).map { "\($0) = false" })
        lines += ["", "[mcp_servers]"]
        for skillPath in normalizedSkills {
            lines += [
                "",
                "[[skills.config]]",
                "path = \(tomlString(skillPath))",
                "enabled = false",
            ]
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static var schemaBytes: Data {
        Data((#"{"type":"object","properties":{"result":{"type":"string"}},"required":["result"],"additionalProperties":false}"# + "\n").utf8)
    }

    static func routeProfile(developerInstructions: String,
                             model: String = model,
                             effort: String = effort,
                             envelopeVersion: String = envelopeVersion) throws -> RouteProfile {
        for (label, value) in [("model", model), ("effort", effort)] {
            guard !value.isEmpty,
                  value.utf8.count <= maxOpaqueRouteValueBytes else {
                throw CodexIsolationError.failed("invalid \(label) identifier")
            }
        }
        guard envelopeVersion.range(
            of: #"^[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil else {
            throw CodexIsolationError.failed("invalid envelope version identifier")
        }
        guard !developerInstructions.isEmpty else {
            throw CodexIsolationError.failed("developer instructions must not be empty")
        }

        // The envelope version is a comment so strict Codex config parsing sees no unknown key, while its
        // canonical bytes still participate in the full profile content hash.
        let canonical = [
            "# viddydictate-envelope-version = \(tomlString(envelopeVersion))",
            "model = \(tomlString(model))",
            "model_reasoning_effort = \(tomlString(effort))",
            "developer_instructions = \(tomlString(developerInstructions))",
            "",
        ].joined(separator: "\n")
        let bytes = Data(canonical.utf8)
        let hash = sha256Hex(bytes)
        return RouteProfile(name: profilePrefix + hash, hash: hash, bytes: bytes)
    }

    static func execArguments(profile: RouteProfile, paths: Paths) -> [String] {
        [
            "-p", profile.name,
            "-s", "read-only",
            "-a", "never",
            "-C", paths.cwd.path,
            "exec",
            "--strict-config",
            "--ephemeral",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--json",
            "--output-schema", paths.schema.path,
            "-",
        ]
    }

    static func stdinBytes(userText: String) -> Data {
        Data("<<<TRANSCRIPT>>>\n\(userText)\n<<<END_TRANSCRIPT>>>\n".utf8)
    }

    static func sanitizedEnvironment(paths: Paths, home: String = NSHomeDirectory()) -> [String: String] {
        [
            "HOME": home,
            "CODEX_HOME": paths.home.path,
            "PATH": "/usr/bin:/bin",
            "TMPDIR": paths.temp.path + "/",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TERM": "dumb",
        ]
    }

    static func enumerateSeededSkills(paths: Paths, fileManager fm: FileManager = .default) throws -> [URL] {
        guard fm.fileExists(atPath: paths.systemSkills.path) else {
            throw CodexIsolationError.failed("pinned CLI did not seed skills/.system")
        }
        var found: [URL] = []

        func walk(_ directory: URL) throws {
            try requireDirectoryNoSymlink(directory)
            let children = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { $0.path < $1.path }
            for child in children {
                var st = stat()
                guard lstat(child.path, &st) == 0 else {
                    throw CodexIsolationError.failed("cannot inspect seeded-skill entry")
                }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFLNK {
                    throw CodexIsolationError.failed("seeded-skill tree contains a symlink")
                } else if kind == S_IFDIR {
                    try walk(child)
                } else if kind == S_IFREG && child.lastPathComponent == "SKILL.md" {
                    found.append(child.standardizedFileURL)
                }
            }
        }

        try walk(paths.systemSkills)
        guard !found.isEmpty else {
            throw CodexIsolationError.failed("seeded-skill inventory is empty")
        }
        return found.sorted { $0.path < $1.path }
    }

    static func cheapFileIdentity(at url: URL) throws -> CheapFileIdentity {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw CodexIsolationError.failed("compatibility identity path is not a regular file")
        }
        return CheapFileIdentity(
            device: UInt64(st.st_dev),
            inode: UInt64(st.st_ino),
            size: Int64(st.st_size),
            modifiedSeconds: Int64(st.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(st.st_mtimespec.tv_nsec),
            mode: UInt16(st.st_mode & 0o7777))
    }

    static func strongFileIdentity(
        at url: URL,
        includeCodeSigning: Bool
    ) throws -> StrongFileIdentity {
        let before = try cheapFileIdentity(at: url)
        let hash = try sha256Hex(ofFile: url)
        let signing = includeCodeSigning ? try codeSigningIdentity(at: url) : nil
        let after = try cheapFileIdentity(at: url)
        guard before == after else {
            throw CodexIsolationError.failed(
                "compatibility identity changed during strong audit")
        }
        return StrongFileIdentity(cheap: after, sha256: hash, codeSigning: signing)
    }

    static func installExecutableSnapshot(
        from origin: URL,
        originIdentity: StrongFileIdentity,
        paths: Paths,
        includeCodeSigning: Bool = true,
        fileManager fm: FileManager = .default
    ) throws -> (url: URL, identity: StrongFileIdentity) {
        try installContentAddressedSnapshot(
            from: origin,
            originIdentity: originIdentity,
            store: paths.executableStore,
            filename: "codex-\(originIdentity.sha256)",
            includeCodeSigning: includeCodeSigning,
            label: "Codex executable",
            fileManager: fm)
    }

    static func installRunnerSnapshot(
        from origin: URL,
        originIdentity: StrongFileIdentity,
        paths: Paths,
        includeCodeSigning: Bool = true,
        fileManager fm: FileManager = .default
    ) throws -> (url: URL, identity: StrongFileIdentity) {
        try installContentAddressedSnapshot(
            from: origin,
            originIdentity: originIdentity,
            store: paths.runnerStore,
            filename: "runner-\(originIdentity.sha256)",
            includeCodeSigning: includeCodeSigning,
            label: "Codex containment runner",
            fileManager: fm)
    }

    private static func installContentAddressedSnapshot(
        from origin: URL,
        originIdentity: StrongFileIdentity,
        store: URL,
        filename: String,
        includeCodeSigning: Bool,
        label: String,
        fileManager fm: FileManager
    ) throws -> (url: URL, identity: StrongFileIdentity) {
        guard try strongFileIdentity(
            at: origin, includeCodeSigning: includeCodeSigning) == originIdentity else {
            throw CodexIsolationError.failed(
                "\(label) origin identity changed before snapshot")
        }
        try secureDirectory(store, fileManager: fm)
        let destination = store.appendingPathComponent(
            filename, isDirectory: false)
        if fm.fileExists(atPath: destination.path) {
            try requireRegularFileNoSymlink(destination)
            try requireFileMode(destination, expected: 0o500)
        } else {
            let staged = store.appendingPathComponent(
                ".\(filename).staged-\(UUID().uuidString)", isDirectory: false)
            do {
                try fm.copyItem(at: origin, to: staged)
                guard chmod(staged.path, 0o500) == 0 else {
                    throw CodexIsolationError.failed(
                        "could not restrict \(label) snapshot")
                }
                let stagedIdentity = try strongFileIdentity(
                    at: staged, includeCodeSigning: includeCodeSigning)
                guard stagedIdentity.sha256 == originIdentity.sha256,
                      stagedIdentity.codeSigning == originIdentity.codeSigning else {
                    throw CodexIsolationError.failed(
                        "\(label) snapshot identity mismatch")
                }
                guard rename(staged.path, destination.path) == 0 else {
                    throw CodexIsolationError.failed(
                        "could not install \(label) snapshot")
                }
            } catch {
                if fm.fileExists(atPath: staged.path) {
                    do { try fm.removeItem(at: staged) }
                    catch {
                        throw CodexIsolationError.failed(
                            "\(label) snapshot staging cleanup failed")
                    }
                }
                throw error
            }
        }
        let identity = try strongFileIdentity(
            at: destination, includeCodeSigning: includeCodeSigning)
        guard identity.sha256 == originIdentity.sha256,
              identity.codeSigning == originIdentity.codeSigning,
              try strongFileIdentity(
                at: origin, includeCodeSigning: includeCodeSigning) == originIdentity else {
            throw CodexIsolationError.failed(
                "\(label) origin identity changed during snapshot")
        }
        return (destination, identity)
    }

    static func executableSnapshotURL(
        paths: Paths,
        receipt: CompatibilityReceipt
    ) throws -> URL {
        let expected = "codex-\(receipt.originExecutable.sha256)"
        guard receipt.executableSnapshotFilename == expected,
              receipt.executable.sha256 == receipt.originExecutable.sha256,
              receipt.executable.codeSigning
                == receipt.originExecutable.codeSigning,
              expected.range(
                of: #"^codex-[0-9a-f]{64}$"#,
                options: .regularExpression) != nil else {
            throw CodexIsolationError.failed(
                "Codex executable snapshot name is invalid")
        }
        return paths.executableSnapshot(filename: expected)
    }

    static func runnerSnapshotURL(
        paths: Paths,
        receipt: CompatibilityReceipt
    ) throws -> URL {
        let expected = "runner-\(receipt.originRunner.sha256)"
        guard receipt.runnerSnapshotFilename == expected,
              receipt.runner.sha256 == receipt.originRunner.sha256,
              receipt.runner.codeSigning == receipt.originRunner.codeSigning,
              expected.range(
                of: #"^runner-[0-9a-f]{64}$"#,
                options: .regularExpression) != nil else {
            throw CodexIsolationError.failed(
                "Codex containment-runner snapshot name is invalid")
        }
        return paths.runnerSnapshot(filename: expected)
    }

    private static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func codeSigningIdentity(at url: URL) throws -> CodeSigningIdentity? {
        let bounded: BoundedProcessResult
        do {
            bounded = try runBoundedProcess(
                executable: "/usr/bin/codesign",
                arguments: ["--display", "--verbose=4", url.path],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "LANG": "C",
                    "LC_ALL": "C",
                ],
                currentDirectory: url.deletingLastPathComponent(),
                timeout: 5,
                stdoutLimit: 1_024,
                stderrLimit: 65_536)
        } catch {
            throw CodexIsolationError.failed("could not inspect code-signing identity")
        }
        guard bounded.leaderReaped,
              !bounded.residualProcessGroup,
              !bounded.captureFailure,
              !bounded.timedOut,
              !bounded.stdoutOverflow,
              !bounded.stderrOverflow else {
            throw CodexIsolationError.failed("code-signing identity exceeded output bound")
        }
        guard bounded.status == 0 else { return nil }
        let data = bounded.stderr
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexIsolationError.failed("code-signing identity is not UTF-8")
        }
        var identifier: String?
        var cdHash: String?
        var teamIdentifier: String?
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("Identifier=") {
                identifier = String(line.dropFirst("Identifier=".count))
            } else if line.hasPrefix("CDHash=") {
                cdHash = String(line.dropFirst("CDHash=".count)).lowercased()
            } else if line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count))
                teamIdentifier = value == "not set" ? nil : value
            }
        }
        guard let identifier, let cdHash,
              identifier.range(of: #"^[A-Za-z0-9._-]+$"#,
                               options: .regularExpression) != nil,
              cdHash.range(of: #"^[0-9a-f]{40,128}$"#,
                           options: .regularExpression) != nil else {
            throw CodexIsolationError.failed("code-signing identity is incomplete")
        }
        return CodeSigningIdentity(
            identifier: identifier, cdHash: cdHash, teamIdentifier: teamIdentifier)
    }

    static var executionContractSHA256: String {
        let canonical = [
            "receipt=3",
            "executable=origin-bound-content-addressed-snapshot",
            "runner=origin-bound-content-addressed-snapshot",
            "envelope=\(envelopeVersion)",
            "schema=\(sha256Hex(schemaBytes))",
            "profile-prefix=\(profilePrefix)",
            "output-contract=thread.started,turn.started,item.started-agent-message,item.completed-agent-message,turn.completed",
            // Staged images sit AFTER the subcommand: `--image` is variadic, and ahead of `exec` it
            // consumed the subcommand itself. Moving them changes this contract hash on purpose, which is
            // what retires any compatibility receipt minted against the broken order.
            "argv=-s read-only;-a never;exec;--strict-config;--ephemeral;--ignore-rules;--skip-git-repo-check;optional-bounded-app-staged-images;--json;--output-schema;-",
        ].joined(separator: "\n")
        return sha256Hex(Data(canonical.utf8))
    }

    static func encodeCompatibilityReceipt(_ receipt: CompatibilityReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(receipt)
    }

    static func decodeCompatibilityReceipt(_ data: Data) throws -> CompatibilityReceipt {
        guard data.count <= 1_048_576 else {
            throw CodexIsolationError.failed("compatibility receipt exceeds byte bound")
        }
        let receipt = try JSONDecoder().decode(CompatibilityReceipt.self, from: data)
        guard receipt.formatVersion == CompatibilityReceipt.currentFormatVersion else {
            throw CodexIsolationError.failed("compatibility receipt format changed")
        }
        return receipt
    }

    static func compatibilityReceiptBoundaryFailure(
        receipt: CompatibilityReceipt,
        originExecutable: StrongFileIdentity,
        executable: StrongFileIdentity,
        originRunner: StrongFileIdentity,
        runner: StrongFileIdentity,
        configSHA256: String,
        skillTreeSHA256: String,
        skillsRootSHA256: String
    ) -> String? {
        guard receipt.formatVersion == CompatibilityReceipt.currentFormatVersion else {
            return "Codex compatibility receipt format changed"
        }
        guard receipt.originExecutable == originExecutable else {
            return "Codex origin executable identity changed"
        }
        guard receipt.executable.sha256 == receipt.originExecutable.sha256,
              receipt.executable.codeSigning
                == receipt.originExecutable.codeSigning else {
            return "Codex executable snapshot content address changed"
        }
        guard receipt.executable == executable else {
            return "Codex executable snapshot identity changed"
        }
        guard receipt.originRunner == originRunner else {
            return "Codex containment-runner origin identity changed"
        }
        guard receipt.runner.sha256 == receipt.originRunner.sha256,
              receipt.runner.codeSigning
                == receipt.originRunner.codeSigning else {
            return "Codex containment-runner snapshot content address changed"
        }
        guard receipt.runner == runner else {
            return "Codex containment-runner snapshot identity changed"
        }
        guard receipt.restrictiveConfigSHA256 == configSHA256 else {
            return "Codex restrictive config changed"
        }
        guard receipt.seededSkillTreeSHA256 == skillTreeSHA256 else {
            return "Codex seeded-skill tree changed"
        }
        guard receipt.skillsRootSHA256 == skillsRootSHA256 else {
            return "Codex skills root changed"
        }
        guard receipt.schemaSHA256 == sha256Hex(schemaBytes),
              receipt.executionContractSHA256 == executionContractSHA256 else {
            return "Codex envelope/schema identity changed"
        }
        var inventory: [String: FeatureInventoryEntry] = [:]
        for entry in receipt.effectiveFeatures {
            guard inventory.updateValue(entry, forKey: entry.name) == nil else {
                return "Codex receipt feature inventory is contradictory"
            }
            if entry.stage.isForceable && entry.enabled {
                return "Codex receipt contains an enabled forceable feature"
            }
            if !entry.stage.isForceable && entry.enabled {
                guard acceptedUnforceableEnabledFeatures[entry.name]?.stage == entry.stage else {
                    return "Codex receipt contains an unreviewed enabled tombstone"
                }
            }
        }
        var baseline: [String: FeatureInventoryEntry] = [:]
        for entry in receipt.featureContinuityBaseline {
            guard baseline.updateValue(entry, forKey: entry.name) == nil else {
                return "Codex receipt continuity evidence is contradictory"
            }
        }
        if featureInventoryContinuityFailure(
            current: baseline,
            baseline: featureInventoryAuditBaseline) != nil {
            return "Codex receipt continuity baseline is incomplete"
        }
        if featureInventoryContinuityFailure(
            current: inventory, baseline: baseline) != nil {
            return "Codex receipt feature continuity evidence failed"
        }
        return nil
    }

    static func normalizeSeededSkillTree(
        systemSkills: URL,
        fileManager fm: FileManager = .default
    ) throws {
        try requireOwnedDirectory(systemSkills)
        func walk(_ directory: URL) throws {
            let children = try fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
            for child in children {
                var st = stat()
                guard lstat(child.path, &st) == 0, st.st_uid == getuid() else {
                    throw CodexIsolationError.failed(
                        "seeded-skill entry is not app-owned")
                }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFLNK {
                    throw CodexIsolationError.failed("seeded-skill tree contains a symlink")
                } else if kind == S_IFDIR {
                    guard chmod(child.path, 0o700) == 0 else {
                        throw CodexIsolationError.failed(
                            "could not restrict seeded-skill directory")
                    }
                    try walk(child)
                } else if kind == S_IFREG {
                    guard chmod(child.path, 0o400) == 0 else {
                        throw CodexIsolationError.failed(
                            "could not restrict seeded-skill file")
                    }
                } else {
                    throw CodexIsolationError.failed(
                        "seeded-skill tree contains a non-regular entry")
                }
            }
        }
        guard chmod(systemSkills.path, 0o700) == 0 else {
            throw CodexIsolationError.failed("could not restrict seeded-skill root")
        }
        try walk(systemSkills)
    }

    static func normalizeDedicatedSkillsRoot(
        skillsRoot: URL,
        fileManager fm: FileManager = .default
    ) throws {
        try requireOwnedDirectory(skillsRoot)
        guard chmod(skillsRoot.path, 0o700) == 0 else {
            throw CodexIsolationError.failed(
                "could not restrict dedicated skills root")
        }
        try normalizeSeededSkillTree(
            systemSkills: skillsRoot.appendingPathComponent(
                ".system", isDirectory: true),
            fileManager: fm)
    }

    static func inspectSeededSkillTree(
        systemSkills: URL,
        fileManager fm: FileManager = .default
    ) throws -> SeededSkillTreeInspection {
        try requireOwnedDirectory(systemSkills)
        try requireFileMode(systemSkills, expected: 0o700)
        let canonicalRoot = systemSkills.standardizedFileURL.path
        var entries: [SeededSkillTreeEntry] = []
        var skills: [URL] = []

        func walk(_ directory: URL) throws {
            let children = try fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
                .sorted { $0.path < $1.path }
            for child in children {
                let standardized = child.standardizedFileURL
                guard standardized.path.hasPrefix(canonicalRoot + "/") else {
                    throw CodexIsolationError.failed("seeded-skill path escaped app root")
                }
                let relative = String(standardized.path.dropFirst(canonicalRoot.count + 1))
                guard !relative.isEmpty, !relative.contains("/../") else {
                    throw CodexIsolationError.failed("seeded-skill path is not canonical")
                }
                var st = stat()
                guard lstat(child.path, &st) == 0, st.st_uid == getuid() else {
                    throw CodexIsolationError.failed(
                        "seeded-skill entry is not app-owned")
                }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFLNK {
                    throw CodexIsolationError.failed("seeded-skill tree contains a symlink")
                } else if kind == S_IFDIR {
                    guard (st.st_mode & 0o777) == 0o700 else {
                        throw CodexIsolationError.failed(
                            "seeded-skill directory mode is not restrictive")
                    }
                    entries.append(.init(
                        relativePath: relative, kind: .directory,
                        mode: UInt16(st.st_mode & 0o777), sha256: nil))
                    try walk(child)
                } else if kind == S_IFREG {
                    guard (st.st_mode & 0o777) == 0o400 else {
                        throw CodexIsolationError.failed(
                            "seeded-skill file mode is not restrictive")
                    }
                    let hash = try sha256Hex(ofFile: child)
                    entries.append(.init(
                        relativePath: relative, kind: .regularFile,
                        mode: UInt16(st.st_mode & 0o777), sha256: hash))
                    if child.lastPathComponent == "SKILL.md" {
                        skills.append(standardized)
                    }
                } else {
                    throw CodexIsolationError.failed(
                        "seeded-skill tree contains a non-regular entry")
                }
            }
        }
        try walk(systemSkills)
        guard !skills.isEmpty else {
            throw CodexIsolationError.failed("seeded-skill inventory is empty")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(entries)
        return SeededSkillTreeInspection(
            entries: entries,
            skillFiles: skills.sorted { $0.path < $1.path },
            identitySHA256: sha256Hex(bytes))
    }

    static func inspectDedicatedSkillsRoot(
        skillsRoot: URL,
        fileManager fm: FileManager = .default
    ) throws -> DedicatedSkillsRootInspection {
        try requireOwnedDirectory(skillsRoot)
        try requireFileMode(skillsRoot, expected: 0o700)
        let children = try fm.contentsOfDirectory(
            at: skillsRoot, includingPropertiesForKeys: nil, options: [])
        guard children.count == 1,
              children[0].lastPathComponent == ".system" else {
            throw CodexIsolationError.failed(
                "dedicated skills root contains a noncanonical sibling")
        }
        let tree = try inspectSeededSkillTree(
            systemSkills: children[0], fileManager: fm)
        let rootEvidence = Data(
            "skills-root-v1\n.system\n\(tree.identitySHA256)\n".utf8)
        return DedicatedSkillsRootInspection(
            systemTree: tree,
            identitySHA256: sha256Hex(rootEvidence))
    }

    static func installAppOwnedBoundaryAssets(
        livePaths: Paths,
        candidateSystemSkills: URL,
        restrictiveConfig: Data,
        receiptBytes: Data,
        fault: BoundaryAssetInstallFault? = nil,
        fileManager fm: FileManager = .default
    ) throws {
        _ = try inspectSeededSkillTree(systemSkills: candidateSystemSkills, fileManager: fm)
        try requireDirectoryNoSymlink(livePaths.home)
        let skillsRoot = livePaths.skillsRoot
        try secureDirectory(skillsRoot, fileManager: fm)
        let suffix = UUID().uuidString
        let transactionRoot = livePaths.home.deletingLastPathComponent()
            .appendingPathComponent(
                ".codex-boundary-transaction-\(suffix)", isDirectory: true)
        try secureDirectory(transactionRoot, fileManager: fm)
        let stagedSkills = transactionRoot.appendingPathComponent(
            "system.staged", isDirectory: true)
        let stagedConfig = transactionRoot.appendingPathComponent(
            "config.staged", isDirectory: false)
        let stagedReceipt = transactionRoot.appendingPathComponent(
            "receipt.staged", isDirectory: false)
        let stagedSchema = transactionRoot.appendingPathComponent(
            "schema.staged", isDirectory: false)
        let backupSkills = transactionRoot.appendingPathComponent(
            "system.backup", isDirectory: true)
        let backupConfig = transactionRoot.appendingPathComponent(
            "config.backup", isDirectory: false)
        let backupReceipt = transactionRoot.appendingPathComponent(
            "receipt.backup", isDirectory: false)
        let backupSchema = transactionRoot.appendingPathComponent(
            "schema.backup", isDirectory: false)

        func injected(_ point: BoundaryAssetInstallFault) throws {
            if fault == point {
                throw CodexIsolationError.failed(
                    "synthetic app-owned boundary transaction fault")
            }
        }

        do {
            try fm.copyItem(at: candidateSystemSkills, to: stagedSkills)
            try normalizeSeededSkillTree(systemSkills: stagedSkills, fileManager: fm)
            _ = try inspectSeededSkillTree(systemSkills: stagedSkills, fileManager: fm)
            try injected(.afterSkillsStaged)
            try atomicRestrictiveWrite(
                restrictiveConfig, to: stagedConfig, finalMode: 0o400,
                allowReplacement: false)
            try injected(.afterConfigStaged)
            try atomicRestrictiveWrite(
                schemaBytes, to: stagedSchema, finalMode: 0o400,
                allowReplacement: false)
            try injected(.afterSchemaStaged)
            try atomicRestrictiveWrite(
                receiptBytes, to: stagedReceipt, finalMode: 0o400,
                allowReplacement: false)
            try injected(.afterReceiptStaged)
        } catch {
            do { try fm.removeItem(at: transactionRoot) }
            catch {
                throw CodexIsolationError.failed(
                    "Codex boundary staging cleanup failed")
            }
            throw error
        }

        let targets = [
            (livePaths.systemSkills, stagedSkills, backupSkills),
            (livePaths.config, stagedConfig, backupConfig),
            (livePaths.schema, stagedSchema, backupSchema),
            (livePaths.compatibilityReceipt, stagedReceipt, backupReceipt),
        ]
        var installedCount = 0
        var backedUp: [Bool] = []
        do {
            for (index, item) in targets.enumerated() {
                let (target, staged, backup) = item
                try injected([
                    .beforeSkillsInstall,
                    .beforeConfigInstall,
                    .beforeSchemaInstall,
                    .beforeReceiptInstall,
                ][index])
                let existed = fm.fileExists(atPath: target.path)
                backedUp.append(existed)
                if existed { try fm.moveItem(at: target, to: backup) }
                try fm.moveItem(at: staged, to: target)
                installedCount += 1
                try injected([
                    .afterSkillsInstall,
                    .afterConfigInstall,
                    .afterSchemaInstall,
                    .afterReceiptInstall,
                ][index])
                if index == 2, fault == .beforeRestore {
                    throw CodexIsolationError.failed(
                        "synthetic boundary restore-path fault")
                }
            }
        } catch {
            var rollbackFailed = fault == .beforeRestore
            if !rollbackFailed, installedCount > 0 {
                for index in stride(from: installedCount - 1, through: 0, by: -1) {
                    let (target, _, backup) = targets[index]
                    do {
                        if fm.fileExists(atPath: target.path) {
                            try fm.removeItem(at: target)
                        }
                        if backedUp[index], fm.fileExists(atPath: backup.path) {
                            try fm.moveItem(at: backup, to: target)
                        }
                    } catch {
                        rollbackFailed = true
                    }
                }
            }
            if !rollbackFailed {
                for index in installedCount..<backedUp.count where backedUp[index] {
                    let (target, _, backup) = targets[index]
                    do {
                        if fm.fileExists(atPath: backup.path) {
                            try fm.moveItem(at: backup, to: target)
                        }
                    } catch {
                        rollbackFailed = true
                    }
                }
            }
            if rollbackFailed {
                if fm.fileExists(atPath: livePaths.compatibilityReceipt.path) {
                    do { try fm.removeItem(at: livePaths.compatibilityReceipt) }
                    catch {
                        throw CodexIsolationError.failed(
                            "Codex boundary rollback and receipt invalidation failed")
                    }
                }
            }
            do { try fm.removeItem(at: transactionRoot) }
            catch {
                if fm.fileExists(atPath: livePaths.compatibilityReceipt.path) {
                    do { try fm.removeItem(at: livePaths.compatibilityReceipt) }
                    catch {
                        throw CodexIsolationError.failed(
                            "Codex boundary rollback cleanup failed")
                    }
                }
                throw CodexIsolationError.failed(
                    "Codex boundary rollback cleanup failed")
            }
            if rollbackFailed {
                throw CodexIsolationError.failed(
                    "Codex boundary rollback failed; receipt invalidated")
            }
            throw error
        }
        do {
            try injected(.beforeCleanup)
            try fm.removeItem(at: transactionRoot)
        } catch {
            if fm.fileExists(atPath: livePaths.compatibilityReceipt.path) {
                try fm.removeItem(at: livePaths.compatibilityReceipt)
            }
            if fm.fileExists(atPath: transactionRoot.path) {
                try fm.removeItem(at: transactionRoot)
            }
            throw CodexIsolationError.failed(
                "Codex boundary transaction cleanup failed; receipt invalidated")
        }
    }

    static func runBoundedProcess(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        stdin: Data? = nil,
        timeout: TimeInterval,
        cleanupGrace: TimeInterval = 2,
        stdoutLimit: Int,
        stderrLimit: Int,
        operationDeadline: TimeInterval? = nil,
        absoluteDeadline: TimeInterval? = nil,
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        postLaunch: (() throws -> Void)? = nil
    ) throws -> BoundedProcessResult {
        guard executable.hasPrefix("/"),
              currentDirectory.path.hasPrefix("/"),
              timeout > 0,
              cleanupGrace > 0,
              stdoutLimit > 0,
              stderrLimit > 0 else {
            throw CodexIsolationError.failed(
                "bounded process configuration is invalid")
        }
        let stdinPipe = stdin == nil ? nil : Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let nullInput = stdin == nil
            ? open("/dev/null", O_RDONLY | O_CLOEXEC)
            : -1
        guard stdin != nil || nullInput >= 0 else {
            throw CodexIsolationError.failed(
                "bounded process could not open null input")
        }
        defer {
            if nullInput >= 0 { close(nullInput) }
        }

        let childStdin = stdinPipe?.fileHandleForReading.fileDescriptor
            ?? nullInput
        let parentStdin = stdinPipe?.fileHandleForWriting.fileDescriptor
        let parentStdout = stdoutPipe.fileHandleForReading.fileDescriptor
        let childStdout = stdoutPipe.fileHandleForWriting.fileDescriptor
        let parentStderr = stderrPipe.fileHandleForReading.fileDescriptor
        let childStderr = stderrPipe.fileHandleForWriting.fileDescriptor
        if let parentStdin {
            _ = fcntl(parentStdin, F_SETNOSIGPIPE, 1)
        }

        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0,
              posix_spawn_file_actions_init(&actions) == 0 else {
            throw CodexIsolationError.failed(
                "bounded process spawn initialization failed")
        }
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        guard posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(
                &actions, childStdin, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(
                &actions, childStdout, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(
                &actions, childStderr, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(
                &actions, parentStdout) == 0,
              posix_spawn_file_actions_addclose(
                &actions, parentStderr) == 0,
              (parentStdin == nil
                || posix_spawn_file_actions_addclose(
                    &actions, parentStdin!) == 0),
              posix_spawn_file_actions_addchdir_np(
                &actions, currentDirectory.path) == 0 else {
            throw CodexIsolationError.failed(
                "bounded process spawn configuration failed")
        }

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let configuredDeadlines:
            (operation: TimeInterval, overall: TimeInterval)?
        if operationDeadline != nil || absoluteDeadline != nil {
            let deadlineConfiguredAt = monotonicNow()
            let resolvedOperation =
                operationDeadline
                    ?? min(
                        deadlineConfiguredAt + timeout,
                        (absoluteDeadline
                            ?? deadlineConfiguredAt
                                + timeout
                                + cleanupGrace)
                            - cleanupGrace)
            let resolvedOverall =
                absoluteDeadline
                    ?? resolvedOperation + cleanupGrace
            guard resolvedOperation > deadlineConfiguredAt,
                  resolvedOverall > resolvedOperation else {
                throw CodexIsolationError.failed(
                    "bounded process deadline configuration is invalid")
            }
            configuredDeadlines =
                (resolvedOperation, resolvedOverall)
        } else {
            configuredDeadlines = nil
        }
        var pid: pid_t = 0
        let spawnStatus = withCStringArray(argv) { argvPointers in
            withCStringArray(envp) { environmentPointers in
                posix_spawn(
                    &pid, executable, &actions, &attributes,
                    argvPointers, environmentPointers)
            }
        }
        guard spawnStatus == 0 else {
            throw CodexIsolationError.failed(
                "bounded process launch failed")
        }
        let legacyStartedAt = monotonicNow()
        let resolvedOperationDeadline =
            configuredDeadlines?.operation
                ?? legacyStartedAt + timeout
        let resolvedOverallDeadline =
            configuredDeadlines?.overall
                ?? resolvedOperationDeadline + cleanupGrace
        _ = setpgid(pid, pid)

        stdinPipe?.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let captures = DispatchGroup()
        let captureLock = NSLock()
        var capturedStdout = Data()
        var capturedStderr = Data()
        var stdoutOverflow = false
        var stderrOverflow = false

        func startCapture(
            _ handle: FileHandle,
            limit: Int,
            stdout: Bool
        ) {
            captures.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var captured = Data()
                var overflow = false
                while true {
                    let chunk = handle.readData(ofLength: 65_536)
                    if chunk.isEmpty { break }
                    if captured.count < limit {
                        let remaining = limit - captured.count
                        captured.append(chunk.prefix(remaining))
                        if chunk.count > remaining { overflow = true }
                    } else {
                        overflow = true
                    }
                }
                captureLock.lock()
                if stdout {
                    capturedStdout = captured
                    stdoutOverflow = overflow
                } else {
                    capturedStderr = captured
                    stderrOverflow = overflow
                }
                captureLock.unlock()
                captures.leave()
            }
        }
        startCapture(
            stdoutPipe.fileHandleForReading,
            limit: stdoutLimit,
            stdout: true)
        startCapture(
            stderrPipe.fileHandleForReading,
            limit: stderrLimit,
            stdout: false)

        do {
            try postLaunch?()
        } catch {
            _ = kill(-pid, SIGTERM)
            var status: Int32 = 0
            var leaderReaped = false
            let cleanupDeadline = min(
                resolvedOverallDeadline,
                monotonicNow() + cleanupGrace)
            let termDeadline =
                monotonicNow()
                    + max(
                        0,
                        cleanupDeadline - monotonicNow()) / 2
            while monotonicNow() < termDeadline {
                if !leaderReaped {
                    let waited = waitpid(pid, &status, WNOHANG)
                    if waited == pid { leaderReaped = true }
                    else if waited < 0 && errno != EINTR { break }
                }
                if leaderReaped && processGroupIsEmpty(pid) { break }
                usleep(5_000)
            }
            if !processGroupIsEmpty(pid) { _ = kill(-pid, SIGKILL) }
            while monotonicNow() < cleanupDeadline {
                if !leaderReaped {
                    let waited = waitpid(pid, &status, WNOHANG)
                    if waited == pid { leaderReaped = true }
                    else if waited < 0 && errno != EINTR { break }
                }
                if leaderReaped && processGroupIsEmpty(pid) { break }
                usleep(5_000)
            }
            stdinPipe?.fileHandleForWriting.closeFile()
            let captureRemaining = max(
                0, cleanupDeadline - monotonicNow())
            let captureFailure =
                captures.wait(
                    timeout: .now() + captureRemaining) == .timedOut
            guard leaderReaped,
                  processGroupIsEmpty(pid),
                  !captureFailure else {
                throw CodexIsolationError.failed(
                    "Codex boundary process cleanup failed")
            }
            throw error
        }

        if let stdin, let input = stdinPipe?.fileHandleForWriting {
            captures.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    try? input.close()
                    captures.leave()
                }
                try? input.write(contentsOf: stdin)
            }
        }

        var status: Int32 = 0
        var leaderReaped = false
        while monotonicNow() < resolvedOperationDeadline {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                leaderReaped = true
                break
            }
            if waited < 0 && errno != EINTR { break }
            usleep(5_000)
        }

        var timedOut = !leaderReaped
        let groupSurvivedLeader =
            leaderReaped && !processGroupIsEmpty(pid)
        timedOut = timedOut || groupSurvivedLeader
        let cleanupDeadline =
            configuredDeadlines?.overall
                ?? monotonicNow() + cleanupGrace
        if timedOut || groupSurvivedLeader {
            _ = kill(-pid, SIGTERM)
            let termDeadline =
                monotonicNow()
                    + max(
                        0,
                        cleanupDeadline - monotonicNow()) / 2
            while monotonicNow() < termDeadline {
                if !leaderReaped {
                    let waited = waitpid(pid, &status, WNOHANG)
                    if waited == pid { leaderReaped = true }
                    else if waited < 0 && errno != EINTR { break }
                }
                if leaderReaped && processGroupIsEmpty(pid) { break }
                usleep(5_000)
            }
            if !processGroupIsEmpty(pid) { _ = kill(-pid, SIGKILL) }
            while monotonicNow() < cleanupDeadline {
                if !leaderReaped {
                    let waited = waitpid(pid, &status, WNOHANG)
                    if waited == pid { leaderReaped = true }
                    else if waited < 0 && errno != EINTR { break }
                }
                if leaderReaped && processGroupIsEmpty(pid) { break }
                usleep(5_000)
            }
        }

        let residualProcessGroup = !processGroupIsEmpty(pid)
        if !leaderReaped { timedOut = true }
        stdinPipe?.fileHandleForWriting.closeFile()
        let captureRemaining = max(
            0, cleanupDeadline - monotonicNow())
        let captureFailure =
            captures.wait(timeout: .now() + captureRemaining) == .timedOut

        captureLock.lock()
        let stdout = capturedStdout
        let stderr = capturedStderr
        let didOverflowStdout = stdoutOverflow
        let didOverflowStderr = stderrOverflow
        captureLock.unlock()
        return BoundedProcessResult(
            status: leaderReaped ? decodedExitStatus(status) : 125,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            stdoutOverflow: didOverflowStdout,
            stderrOverflow: didOverflowStderr,
            leaderReaped: leaderReaped,
            residualProcessGroup: residualProcessGroup,
            captureFailure: captureFailure)
    }

    private static func decodedExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func processGroupIsEmpty(_ processID: pid_t) -> Bool {
        errno = 0
        return kill(-processID, 0) != 0 && errno == ESRCH
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] =
            strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer {
            body($0.baseAddress!)
        }
    }

    static func withExclusiveBoundaryLock<T>(
        paths: Paths,
        _ body: () throws -> T
    ) throws -> T {
        try requireDirectoryNoSymlink(paths.boundaryLock.deletingLastPathComponent())
        let fd = open(
            paths.boundaryLock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw CodexIsolationError.failed("could not open Codex compatibility lock")
        }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0, flock(fd, LOCK_EX) == 0 else {
            throw CodexIsolationError.failed("could not acquire Codex compatibility lock")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func requireOwnedDirectory(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid() else {
            throw CodexIsolationError.failed(
                "seeded-skill directory is not canonical and app-owned")
        }
    }

    static func stageConfig(_ data: Data, at url: URL) throws {
        try atomicRestrictiveWrite(data, to: url, finalMode: 0o400, allowReplacement: true)
    }

    static func stageSchema(paths: Paths) throws {
        try atomicRestrictiveWrite(schemaBytes, to: paths.schema, finalMode: 0o400, allowReplacement: true)
    }

    static func stageProfile(_ profile: RouteProfile, paths: Paths) throws {
        try atomicRestrictiveWrite(profile.bytes, to: profile.url(in: paths), finalMode: 0o400,
                                   allowReplacement: false)
    }

    static func atomicRestrictiveWrite(_ data: Data, to destination: URL, finalMode: mode_t,
                                       allowReplacement: Bool) throws {
        try requireDirectoryNoSymlink(destination.deletingLastPathComponent())

        if FileManager.default.fileExists(atPath: destination.path) {
            try requireRegularFileNoSymlink(destination)
            let existing = try Data(contentsOf: destination)
            if existing == data {
                guard chmod(destination.path, finalMode) == 0 else {
                    throw CodexIsolationError.failed("could not restore restrictive file mode")
                }
                return
            }
            guard allowReplacement else {
                throw CodexIsolationError.failed("immutable content-hashed file mismatch")
            }
        }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw CodexIsolationError.failed("could not create restrictive temporary file")
        }

        var writeError: String?
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if count < 0 {
                    writeError = "could not write restrictive temporary file"
                    break
                }
                written += count
            }
        }
        if writeError == nil && fsync(fd) != 0 { writeError = "could not flush restrictive temporary file" }
        if writeError == nil && fchmod(fd, finalMode) != 0 { writeError = "could not set restrictive file mode" }
        let closeResult = close(fd)
        if writeError == nil && closeResult != 0 { writeError = "could not close restrictive temporary file" }
        if let writeError {
            _ = unlink(temporary.path)
            throw CodexIsolationError.failed(writeError)
        }

        guard rename(temporary.path, destination.path) == 0 else {
            _ = unlink(temporary.path)
            throw CodexIsolationError.failed("could not atomically install restrictive file")
        }
        let parentFD = open(destination.deletingLastPathComponent().path, O_RDONLY)
        if parentFD >= 0 { _ = fsync(parentFD); _ = close(parentFD) }
        try requireFileMode(destination, expected: finalMode)
    }

    static func secureDirectory(_ url: URL, fileManager fm: FileManager = .default) throws {
        if fm.fileExists(atPath: url.path) {
            try requireDirectoryNoSymlink(url)
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: 0o700)])
            try requireDirectoryNoSymlink(url)
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw CodexIsolationError.failed("could not set app-owned directory mode 0700")
        }
        try requireFileMode(url, expected: 0o700)
    }

    static func requireDirectoryNoSymlink(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw CodexIsolationError.failed("required path is not a real directory: \(url.lastPathComponent)")
        }
    }

    static func requireRegularFileNoSymlink(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw CodexIsolationError.failed("required path is not a regular file: \(url.lastPathComponent)")
        }
    }

    static func requireFileMode(_ url: URL, expected: mode_t) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw CodexIsolationError.failed("could not inspect file mode")
        }
        guard (st.st_mode & 0o777) == expected else {
            throw CodexIsolationError.failed(
                "restrictive mode mismatch for \(url.lastPathComponent): expected \(String(expected, radix: 8))"
            )
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Config path values must name existing objects. Resolve them through realpath(3) so the
    /// serialized bytes use the kernel-canonical spelling; a missing path fails closed.
    static func canonicalPath(_ url: URL) throws -> String {
        let path = url.path
        guard path.hasPrefix("/") else {
            throw CodexIsolationError.failed("path is not absolute")
        }
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            throw CodexIsolationError.failed(
                "path canonicalization requires an existing path")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func canonicalPreinstallSkillPaths(
        paths: Paths,
        disabledSkillPaths: [URL]
    ) throws -> [String] {
        let anchorPath = paths.home.path
        guard anchorPath.hasPrefix("/") else {
            throw CodexIsolationError.failed("path is not absolute")
        }
        let descendantPrefix = anchorPath == "/" ? "/" : anchorPath + "/"
        let canonicalAnchor = try canonicalPath(paths.home)

        return try disabledSkillPaths.map { skillURL in
            let skillPath = skillURL.path
            guard skillPath.hasPrefix(descendantPrefix) else {
                throw CodexIsolationError.failed(
                    "not-yet-installed skill escaped its existing home anchor")
            }
            let relativePath = String(skillPath.dropFirst(descendantPrefix.count))
            let components = relativePath.split(
                separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.count >= 3,
                  components[0] == "skills",
                  components[1] == ".system",
                  components.allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
                  }) else {
                throw CodexIsolationError.failed(
                    "not-yet-installed skill path is not canonical")
            }
            let suffix = components.joined(separator: "/")
            return canonicalAnchor == "/" ? "/\(suffix)" : "\(canonicalAnchor)/\(suffix)"
        }
    }

    static func tomlString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x00...0x1F, 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}

/// Fail-closed JSONL + nested schema parser. It intentionally accepts no reasoning, plan, command,
/// filesystem, MCP, web, browser, app, plugin, skill, hook, or unknown event.
enum CodexTransformOutputContract {
    static let maxJSONLBytes = 1_048_576
    static let maxLineBytes = 262_144
    static let maxResultCharacters = 200_000

    static func parseAcceptedResult(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= maxJSONLBytes else {
            throw CodexIsolationError.failed("JSONL size contract failed")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexIsolationError.failed("JSONL is not UTF-8")
        }

        enum State { case initial, thread, turn, message, completed }
        var state = State.initial
        var agentMessageStarted = false
        var messageText: String?
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in rawLines {
            if rawLine.isEmpty { continue }
            guard rawLine.utf8.count <= maxLineBytes,
                  let object = try JSONSerialization.jsonObject(with: Data(rawLine.utf8)) as? [String: Any],
                  let type = object["type"] as? String else {
                throw CodexIsolationError.failed("malformed JSONL event")
            }
            if state == .completed { throw CodexIsolationError.failed("event after turn.completed") }

            switch type {
            case "thread.started":
                guard state == .initial else { throw CodexIsolationError.failed("duplicate/out-of-order thread.started") }
                state = .thread
            case "turn.started":
                guard state == .thread else { throw CodexIsolationError.failed("duplicate/out-of-order turn.started") }
                state = .turn
            case "item.started":
                guard state == .turn, !agentMessageStarted,
                      let item = object["item"] as? [String: Any],
                      item["type"] as? String == "agent_message" else {
                    throw CodexIsolationError.failed("tool/bookkeeping item.started rejected")
                }
                agentMessageStarted = true
            case "item.completed":
                guard state == .turn, messageText == nil,
                      let item = object["item"] as? [String: Any],
                      item["type"] as? String == "agent_message",
                      let value = item["text"] as? String else {
                    throw CodexIsolationError.failed("tool/bookkeeping or duplicate item.completed rejected")
                }
                messageText = value
                state = .message
            case "turn.completed":
                guard state == .message else { throw CodexIsolationError.failed("partial/ambiguous turn rejected") }
                state = .completed
            case "error", "turn.failed":
                throw CodexIsolationError.failed("Codex error event rejected")
            default:
                throw CodexIsolationError.failed("unexpected JSONL event rejected: \(type)")
            }
        }

        guard state == .completed, let messageText else {
            throw CodexIsolationError.failed("missing terminal completed message")
        }
        guard let nestedData = messageText.data(using: .utf8),
              let nested = try JSONSerialization.jsonObject(with: nestedData) as? [String: Any],
              Set(nested.keys) == ["result"],
              let result = nested["result"] as? String else {
            throw CodexIsolationError.failed("agent message failed strict output schema")
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, result.count <= maxResultCharacters else {
            throw CodexIsolationError.failed("result bounds contract failed")
        }
        return result
    }
}
