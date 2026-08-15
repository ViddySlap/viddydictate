import CoreFoundation
import Darwin
import Foundation

indirect enum ModelCatalogJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([ModelCatalogJSONValue])
    case object([String: ModelCatalogJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ModelCatalogJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ModelCatalogJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

struct ModelCatalogReasoningEffort: Codable, Equatable {
    let reasoningEffort: String
    let description: String?
    let unknownFields: [String: ModelCatalogJSONValue]
}

struct ModelCatalogUpgradeInfo: Codable, Equatable {
    let model: String
    let upgradeCopy: String?
    let modelLink: String?
    let migrationMarkdown: String?
    let unknownFields: [String: ModelCatalogJSONValue]
}

struct ModelCatalogRow: Codable, Equatable {
    let id: String
    let model: String
    let displayName: String?
    let description: String?
    let hidden: Bool
    let defaultReasoningEffort: String?
    let supportedReasoningEfforts: [ModelCatalogReasoningEffort]
    /// `nil` preserves the stable protocol's older-catalog omission. Policy may apply the documented
    /// text+image fallback later; transport never rewrites what the server actually advertised.
    let inputModalities: [String]?
    let supportsPersonality: Bool?
    let isDefault: Bool?
    let upgrade: String?
    let upgradeInfo: ModelCatalogUpgradeInfo?
    let unknownFields: [String: ModelCatalogJSONValue]
}

struct ModelCatalogPageMetadata: Codable, Equatable {
    let unknownFields: [String: ModelCatalogJSONValue]
}

struct ModelCatalog: Codable, Equatable {
    let rows: [ModelCatalogRow]
    let pageMetadata: [ModelCatalogPageMetadata]
}

struct CodexCatalogBounds {
    let maxPages: Int
    let maxItems: Int
    let pageSize: Int
    let maxCursorBytes: Int
    let maxLineBytes: Int
    let maxTotalStdoutBytes: Int
    let maxLines: Int
    let maxNotifications: Int
    let maxStringBytes: Int
    let maxJSONDepth: Int
    let maxJSONNodes: Int
    let maxCacheBytes: Int
    let wallClockSeconds: TimeInterval
    let lineReadSeconds: TimeInterval
    let processGraceSeconds: TimeInterval

    init(
        maxPages: Int = 16,
        maxItems: Int = 512,
        pageSize: Int = 100,
        maxCursorBytes: Int = 4_096,
        maxLineBytes: Int = 1_048_576,
        maxTotalStdoutBytes: Int = 8_388_608,
        maxLines: Int = 1_024,
        maxNotifications: Int = 32,
        maxStringBytes: Int = 65_536,
        maxJSONDepth: Int = 16,
        maxJSONNodes: Int = 8_192,
        maxCacheBytes: Int = 8_388_608,
        wallClockSeconds: TimeInterval = 20,
        lineReadSeconds: TimeInterval = 5,
        processGraceSeconds: TimeInterval = 2
    ) {
        self.maxPages = maxPages
        self.maxItems = maxItems
        self.pageSize = pageSize
        self.maxCursorBytes = maxCursorBytes
        self.maxLineBytes = maxLineBytes
        self.maxTotalStdoutBytes = maxTotalStdoutBytes
        self.maxLines = maxLines
        self.maxNotifications = maxNotifications
        self.maxStringBytes = maxStringBytes
        self.maxJSONDepth = maxJSONDepth
        self.maxJSONNodes = maxJSONNodes
        self.maxCacheBytes = maxCacheBytes
        self.wallClockSeconds = wallClockSeconds
        self.lineReadSeconds = lineReadSeconds
        self.processGraceSeconds = processGraceSeconds
    }
}

struct CodexCatalogFailure: Error, CustomStringConvertible {
    enum Code: String, Codable, Equatable {
        case protocolViolation = "protocol"
        case paginationViolation = "pagination"
        case invalidCatalog = "catalog"
        case boundExceeded = "bound"
        case timeout
        case prematureEOF = "eof"
        case processFailure = "process"
        case processLaunch = "launch"
        case providerUnavailable = "provider"
        case compatibilityBoundary = "compatibility"
        case cacheRead = "cache-read"
        case cacheWrite = "cache-write"
    }

    let code: Code
    var description: String { "Codex catalog \(code.rawValue) failure" }

    init(_ code: Code) {
        self.code = code
    }
}

enum CodexCatalogReadResult {
    case line(Data)
    case eof
    case timeout
    case overflow
    case failure
}

struct CodexCatalogProcessExit: Equatable {
    let exitCode: Int32
    let timedOut: Bool
    let terminatedBySignal: Bool
    let leaderReaped: Bool
    let residualProcessGroup: Bool
    let stderrBytes: Int
    let stderrOverflow: Bool
    let stdoutBytes: Int
    let stdoutOverflow: Bool
    let stdoutPendingBytes: Int
    let stdoutFailure: Bool
    let drainsComplete: Bool
    let stdoutEOF: Bool
    let stderrEOF: Bool

    init(
        exitCode: Int32,
        timedOut: Bool,
        terminatedBySignal: Bool,
        leaderReaped: Bool,
        residualProcessGroup: Bool,
        stderrBytes: Int,
        stderrOverflow: Bool,
        stdoutBytes: Int = 0,
        stdoutOverflow: Bool = false,
        stdoutPendingBytes: Int = 0,
        stdoutFailure: Bool = false,
        drainsComplete: Bool = true,
        stdoutEOF: Bool = true,
        stderrEOF: Bool = true
    ) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.terminatedBySignal = terminatedBySignal
        self.leaderReaped = leaderReaped
        self.residualProcessGroup = residualProcessGroup
        self.stderrBytes = stderrBytes
        self.stderrOverflow = stderrOverflow
        self.stdoutBytes = stdoutBytes
        self.stdoutOverflow = stdoutOverflow
        self.stdoutPendingBytes = stdoutPendingBytes
        self.stdoutFailure = stdoutFailure
        self.drainsComplete = drainsComplete
        self.stdoutEOF = stdoutEOF
        self.stderrEOF = stderrEOF
    }

    static let clean = CodexCatalogProcessExit(
        exitCode: 0, timedOut: false, terminatedBySignal: false,
        leaderReaped: true, residualProcessGroup: false,
        stderrBytes: 0, stderrOverflow: false)
}

enum CodexCatalogProcessOperation: Equatable {
    case wait
    case groupProbe
    case termSignal
    case killSignal
}

protocol CodexCatalogProcessSession: AnyObject {
    func writeLine(_ data: Data) throws
    func readLine(
        absoluteDeadline: TimeInterval
    ) -> CodexCatalogReadResult
    func closeInput()
    func finishAndReap(
        absoluteDeadline: TimeInterval
    ) -> CodexCatalogProcessExit
    func terminateAndReap(
        absoluteDeadline: TimeInterval
    ) -> CodexCatalogProcessExit
}

struct CodexCatalogProcessLaunch {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: URL
    let expectedExecutableIdentity: CodexIsolationFoundation.StrongFileIdentity
    let stdoutLineLimit: Int
    let stdoutTotalLimit: Int
    let stderrLimit: Int
    let spawnedPIDRecorder: ((pid_t) -> Void)?
    let postSpawnBeforeIdentityValidation: (() -> Void)?
    let launchCleanupEvidenceRecorder:
        ((CodexCatalogProcessExit) -> Void)?
    let launchCleanupDeadlineRecorder:
        ((TimeInterval) -> Void)?
    let drainCompletionDelayForTesting: TimeInterval
    let processOperationRecorder:
        ((CodexCatalogProcessOperation) -> Void)?
    let processSignal:
        (pid_t, Int32) -> Int32
    let absoluteDeadline: TimeInterval
    let operationDeadline: TimeInterval
    let monotonicNow: () -> TimeInterval
    let immediateCleanupSeconds: TimeInterval

    init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        expectedExecutableIdentity:
            CodexIsolationFoundation.StrongFileIdentity,
        stdoutLineLimit: Int,
        stdoutTotalLimit: Int,
        stderrLimit: Int,
        spawnedPIDRecorder: ((pid_t) -> Void)? = nil,
        postSpawnBeforeIdentityValidation: (() -> Void)? = nil,
        launchCleanupEvidenceRecorder:
            ((CodexCatalogProcessExit) -> Void)? = nil,
        launchCleanupDeadlineRecorder:
            ((TimeInterval) -> Void)? = nil,
        drainCompletionDelayForTesting: TimeInterval = 0,
        processOperationRecorder:
            ((CodexCatalogProcessOperation) -> Void)? = nil,
        processSignal:
            @escaping (pid_t, Int32) -> Int32 = Darwin.kill,
        absoluteDeadline: TimeInterval? = nil,
        operationDeadline: TimeInterval? = nil,
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        immediateCleanupSeconds: TimeInterval = 0.25
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.expectedExecutableIdentity = expectedExecutableIdentity
        self.stdoutLineLimit = stdoutLineLimit
        self.stdoutTotalLimit = stdoutTotalLimit
        self.stderrLimit = stderrLimit
        self.spawnedPIDRecorder = spawnedPIDRecorder
        self.postSpawnBeforeIdentityValidation =
            postSpawnBeforeIdentityValidation
        self.launchCleanupEvidenceRecorder =
            launchCleanupEvidenceRecorder
        self.launchCleanupDeadlineRecorder =
            launchCleanupDeadlineRecorder
        self.drainCompletionDelayForTesting =
            drainCompletionDelayForTesting
        self.processOperationRecorder = processOperationRecorder
        self.processSignal = processSignal
        self.monotonicNow = monotonicNow
        self.immediateCleanupSeconds =
            max(0, immediateCleanupSeconds)
        let resolvedDeadline =
            absoluteDeadline ?? monotonicNow() + 1
        self.absoluteDeadline = resolvedDeadline
        self.operationDeadline =
            operationDeadline
                ?? resolvedDeadline - self.immediateCleanupSeconds
    }

    func bounded(
        absoluteDeadline: TimeInterval,
        operationDeadline: TimeInterval,
        monotonicNow: @escaping () -> TimeInterval,
        immediateCleanupSeconds: TimeInterval
    ) -> CodexCatalogProcessLaunch {
        CodexCatalogProcessLaunch(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            expectedExecutableIdentity: expectedExecutableIdentity,
            stdoutLineLimit: stdoutLineLimit,
            stdoutTotalLimit: stdoutTotalLimit,
            stderrLimit: stderrLimit,
            spawnedPIDRecorder: spawnedPIDRecorder,
            postSpawnBeforeIdentityValidation:
                postSpawnBeforeIdentityValidation,
            launchCleanupEvidenceRecorder:
                launchCleanupEvidenceRecorder,
            launchCleanupDeadlineRecorder:
                launchCleanupDeadlineRecorder,
            drainCompletionDelayForTesting:
                drainCompletionDelayForTesting,
            processOperationRecorder: processOperationRecorder,
            processSignal: processSignal,
            absoluteDeadline: absoluteDeadline,
            operationDeadline: operationDeadline,
            monotonicNow: monotonicNow,
            immediateCleanupSeconds: immediateCleanupSeconds)
    }
}

typealias CodexCatalogProcessFactory =
    (CodexCatalogProcessLaunch) throws -> CodexCatalogProcessSession

enum CodexCatalogTransport {
    private struct ReceiveState {
        let overallDeadline: TimeInterval
        let operationDeadline: TimeInterval
        var bytes = 0
        var lines = 0
        var notifications = 0
    }

    private struct ParsedPage {
        let rows: [ModelCatalogRow]
        let nextCursor: String?
        let metadata: ModelCatalogPageMetadata
    }

    static func productionLaunch(
        paths: CodexIsolationFoundation.Paths,
        executablePath: String,
        executableIdentity: CodexIsolationFoundation.StrongFileIdentity,
        hostHome: String? = nil,
        bounds: CodexCatalogBounds = CodexCatalogBounds()
    ) -> CodexCatalogProcessLaunch {
        CodexCatalogProcessLaunch(
            executable: executablePath,
            arguments: ["app-server"],
            environment: CodexIsolationFoundation.sanitizedEnvironment(
                paths: paths, home: hostHome ?? paths.home.path),
            currentDirectory: paths.cwd,
            expectedExecutableIdentity: executableIdentity,
            stdoutLineLimit: bounds.maxLineBytes,
            stdoutTotalLimit: bounds.maxTotalStdoutBytes,
            stderrLimit: min(bounds.maxTotalStdoutBytes, 131_072))
    }

    static func acquire(
        launch: CodexCatalogProcessLaunch,
        processFactory: CodexCatalogProcessFactory = CodexCatalogPOSIXSession.start,
        bounds: CodexCatalogBounds = CodexCatalogBounds(),
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) throws -> ModelCatalog {
        try validate(bounds)
        let startedAt = monotonicNow()
        let overallDeadline =
            startedAt + bounds.wallClockSeconds
        let operationDeadline =
            overallDeadline - bounds.processGraceSeconds
        let boundedLaunch = launch.bounded(
            absoluteDeadline: overallDeadline,
            operationDeadline: operationDeadline,
            monotonicNow: monotonicNow,
            immediateCleanupSeconds: bounds.processGraceSeconds)
        guard monotonicNow() < operationDeadline else {
            throw CodexCatalogFailure(.timeout)
        }
        let session: CodexCatalogProcessSession
        do { session = try processFactory(boundedLaunch) }
        catch { throw CodexCatalogFailure(.processLaunch) }
        return try acquire(
            session: session,
            bounds: bounds,
            monotonicNow: monotonicNow,
            overallDeadline: overallDeadline,
            operationDeadline: operationDeadline)
    }

    static func acquire(
        session: CodexCatalogProcessSession,
        bounds: CodexCatalogBounds = CodexCatalogBounds(),
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) throws -> ModelCatalog {
        try validate(bounds)
        let startedAt = monotonicNow()
        return try acquire(
            session: session,
            bounds: bounds,
            monotonicNow: monotonicNow,
            overallDeadline:
                startedAt + bounds.wallClockSeconds,
            operationDeadline:
                startedAt
                    + bounds.wallClockSeconds
                    - bounds.processGraceSeconds)
    }

    private static func acquire(
        session: CodexCatalogProcessSession,
        bounds: CodexCatalogBounds,
        monotonicNow: @escaping () -> TimeInterval,
        overallDeadline: TimeInterval,
        operationDeadline: TimeInterval
    ) throws -> ModelCatalog {
        var state = ReceiveState(
            overallDeadline: overallDeadline,
            operationDeadline: operationDeadline)
        do {
            try requireOperationTime(
                state: state,
                monotonicNow: monotonicNow)
            try send(
                [
                    "method": "initialize",
                    "id": 1,
                    "params": [
                        "clientInfo": [
                            "name": "viddydictate",
                            "title": "ViddyDictate",
                            "version": "1",
                        ],
                    ],
                ],
                to: session,
                bounds: bounds,
                operationDeadline: state.operationDeadline,
                monotonicNow: monotonicNow)
            _ = try receiveResponse(
                id: 1, session: session, bounds: bounds,
                state: &state, monotonicNow: monotonicNow)
            try requireOperationTime(
                state: state,
                monotonicNow: monotonicNow)
            try send(
                ["method": "initialized", "params": [String: Any]()],
                to: session,
                bounds: bounds,
                operationDeadline: state.operationDeadline,
                monotonicNow: monotonicNow)

            var rows: [ModelCatalogRow] = []
            var pageMetadata: [ModelCatalogPageMetadata] = []
            var cursor: String?
            var seenCursors: Set<String> = []
            var seenIDs: Set<String> = []
            var seenModels: Set<String> = []
            var page = 0
            var nextID = 2

            repeat {
                guard page < bounds.maxPages else {
                    throw CodexCatalogFailure(.boundExceeded)
                }
                var params: [String: Any] = [
                    "includeHidden": true,
                    "limit": bounds.pageSize,
                ]
                if let cursor { params["cursor"] = cursor }
                try requireOperationTime(
                    state: state,
                    monotonicNow: monotonicNow)
                try send(
                    ["method": "model/list", "id": nextID, "params": params],
                    to: session,
                    bounds: bounds,
                    operationDeadline: state.operationDeadline,
                    monotonicNow: monotonicNow)
                let result = try receiveResponse(
                    id: nextID, session: session, bounds: bounds,
                    state: &state, monotonicNow: monotonicNow)
                try requireOperationTime(
                    state: state,
                    monotonicNow: monotonicNow)
                let parsed = try parsePage(result, bounds: bounds)
                try requireOperationTime(
                    state: state,
                    monotonicNow: monotonicNow)
                guard !parsed.rows.isEmpty else {
                    throw CodexCatalogFailure(.invalidCatalog)
                }
                guard rows.count + parsed.rows.count <= bounds.maxItems else {
                    throw CodexCatalogFailure(.boundExceeded)
                }
                for row in parsed.rows {
                    guard seenIDs.insert(row.id).inserted,
                          seenModels.insert(row.model).inserted else {
                        throw CodexCatalogFailure(.invalidCatalog)
                    }
                    rows.append(row)
                }
                pageMetadata.append(parsed.metadata)
                cursor = parsed.nextCursor
                if let cursor {
                    guard cursor.utf8.count <= bounds.maxCursorBytes,
                          !cursor.isEmpty,
                          seenCursors.insert(cursor).inserted else {
                        throw CodexCatalogFailure(.paginationViolation)
                    }
                }
                page += 1
                nextID += 1
            } while cursor != nil

            guard !rows.isEmpty else {
                throw CodexCatalogFailure(.invalidCatalog)
            }
            let catalog = ModelCatalog(rows: rows, pageMetadata: pageMetadata)
            try validateCachedCatalog(catalog, bounds: bounds)
            session.closeInput()
            try drainCleanEOF(
                session: session,
                bounds: bounds,
                state: &state,
                monotonicNow: monotonicNow)
            let exit = session.finishAndReap(
                absoluteDeadline: state.overallDeadline)
            guard monotonicNow() <= state.overallDeadline else {
                throw CodexCatalogFailure(.timeout)
            }
            try validate(exit)
            return catalog
        } catch let failure as CodexCatalogFailure {
            session.closeInput()
            let exit = terminateAndReapWithRetry(
                session: session,
                state: state,
                monotonicNow: monotonicNow)
            guard hasCleanupEvidence(exit) else {
                throw CodexCatalogFailure(.processFailure)
            }
            throw failure
        } catch {
            session.closeInput()
            let exit = terminateAndReapWithRetry(
                session: session,
                state: state,
                monotonicNow: monotonicNow)
            guard hasCleanupEvidence(exit) else {
                throw CodexCatalogFailure(.processFailure)
            }
            throw CodexCatalogFailure(.processFailure)
        }
    }

    private static func drainCleanEOF(
        session: CodexCatalogProcessSession,
        bounds: CodexCatalogBounds,
        state: inout ReceiveState,
        monotonicNow: () -> TimeInterval
    ) throws {
        while true {
            let remaining = operationRemaining(
                state: state,
                monotonicNow: monotonicNow)
            guard remaining > 0 else { throw CodexCatalogFailure(.timeout) }
            let readDeadline = min(
                state.operationDeadline,
                monotonicNow() + bounds.lineReadSeconds)
            switch session.readLine(
                absoluteDeadline: readDeadline) {
            case .eof:
                try requireOperationTime(
                    state: state,
                    monotonicNow: monotonicNow)
                return
            case .line:
                throw CodexCatalogFailure(.protocolViolation)
            case .overflow:
                throw CodexCatalogFailure(.boundExceeded)
            case .failure:
                throw CodexCatalogFailure(.processFailure)
            case .timeout:
                throw CodexCatalogFailure(.timeout)
            }
        }
    }

    private static func validate(_ bounds: CodexCatalogBounds) throws {
        guard bounds.maxPages > 0, bounds.maxItems > 0,
              bounds.pageSize > 0, bounds.pageSize <= bounds.maxItems,
              bounds.maxCursorBytes > 0, bounds.maxLineBytes > 0,
              bounds.maxTotalStdoutBytes >= bounds.maxLineBytes,
              bounds.maxLines > 0, bounds.maxNotifications >= 0,
              bounds.maxStringBytes > 0, bounds.maxJSONDepth > 0,
              bounds.maxJSONNodes > 0, bounds.maxCacheBytes > 0,
              bounds.wallClockSeconds > 0, bounds.lineReadSeconds > 0,
              bounds.processGraceSeconds > 0,
              bounds.wallClockSeconds > bounds.processGraceSeconds else {
            throw CodexCatalogFailure(.boundExceeded)
        }
    }

    private static func validate(_ exit: CodexCatalogProcessExit) throws {
        guard exit.exitCode == 0,
              !exit.timedOut,
              !exit.terminatedBySignal,
              exit.leaderReaped,
              !exit.residualProcessGroup,
              exit.stderrBytes == 0,
              !exit.stderrOverflow,
              !exit.stdoutOverflow,
              exit.stdoutPendingBytes == 0,
              !exit.stdoutFailure,
              exit.drainsComplete,
              exit.stdoutEOF,
              exit.stderrEOF else {
            throw CodexCatalogFailure(.processFailure)
        }
    }

    private static func operationRemaining(
        state: ReceiveState,
        monotonicNow: () -> TimeInterval
    ) -> TimeInterval {
        state.operationDeadline - monotonicNow()
    }

    private static func requireOperationTime(
        state: ReceiveState,
        monotonicNow: () -> TimeInterval
    ) throws {
        guard operationRemaining(
            state: state,
            monotonicNow: monotonicNow) > 0 else {
            throw CodexCatalogFailure(.timeout)
        }
    }

    private static func terminateAndReapWithRetry(
        session: CodexCatalogProcessSession,
        state: ReceiveState,
        monotonicNow: () -> TimeInterval
    ) -> CodexCatalogProcessExit {
        let first = session.terminateAndReap(
            absoluteDeadline: state.overallDeadline)
        if hasCleanupEvidence(first) { return first }
        guard monotonicNow() < state.overallDeadline else {
            return first
        }
        return session.terminateAndReap(
            absoluteDeadline: state.overallDeadline)
    }

    private static func hasCleanupEvidence(
        _ exit: CodexCatalogProcessExit
    ) -> Bool {
        exit.leaderReaped
            && !exit.residualProcessGroup
            && exit.drainsComplete
    }

    private static func send(
        _ object: [String: Any],
        to session: CodexCatalogProcessSession,
        bounds: CodexCatalogBounds,
        operationDeadline: TimeInterval,
        monotonicNow: () -> TimeInterval
    ) throws {
        guard monotonicNow() < operationDeadline else {
            throw CodexCatalogFailure(.timeout)
        }
        guard let method = object["method"] as? String,
              ["initialize", "initialized", "model/list"].contains(method),
              JSONSerialization.isValidJSONObject(object) else {
            throw CodexCatalogFailure(.protocolViolation)
        }
        let bytes: Data
        do { bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        catch { throw CodexCatalogFailure(.protocolViolation) }
        guard !bytes.isEmpty, bytes.count <= bounds.maxLineBytes else {
            throw CodexCatalogFailure(.boundExceeded)
        }
        guard monotonicNow() < operationDeadline else {
            throw CodexCatalogFailure(.timeout)
        }
        do { try session.writeLine(bytes) }
        catch { throw CodexCatalogFailure(.processFailure) }
        guard monotonicNow() < operationDeadline else {
            throw CodexCatalogFailure(.timeout)
        }
    }

    private static func receiveResponse(
        id: Int,
        session: CodexCatalogProcessSession,
        bounds: CodexCatalogBounds,
        state: inout ReceiveState,
        monotonicNow: () -> TimeInterval
    ) throws -> [String: Any] {
        while true {
            let now = monotonicNow()
            let remaining = operationRemaining(
                state: state,
                monotonicNow: { now })
            guard remaining > 0 else { throw CodexCatalogFailure(.timeout) }
            let readDeadline = min(
                state.operationDeadline,
                now + bounds.lineReadSeconds)
            let read = session.readLine(
                absoluteDeadline: readDeadline)
            guard monotonicNow() < state.operationDeadline else {
                throw CodexCatalogFailure(.timeout)
            }
            switch read {
            case .timeout:
                throw CodexCatalogFailure(.timeout)
            case .eof:
                throw CodexCatalogFailure(.prematureEOF)
            case .failure:
                throw CodexCatalogFailure(.processFailure)
            case .overflow:
                throw CodexCatalogFailure(.boundExceeded)
            case .line(let line):
                guard !line.isEmpty, line.count <= bounds.maxLineBytes else {
                    throw CodexCatalogFailure(.boundExceeded)
                }
                state.lines += 1
                state.bytes += line.count + 1
                guard state.lines <= bounds.maxLines,
                      state.bytes <= bounds.maxTotalStdoutBytes else {
                    throw CodexCatalogFailure(.boundExceeded)
                }
                let any: Any
                do { any = try JSONSerialization.jsonObject(with: line) }
                catch { throw CodexCatalogFailure(.protocolViolation) }
                guard monotonicNow() < state.operationDeadline else {
                    throw CodexCatalogFailure(.timeout)
                }
                guard let object = any as? [String: Any] else {
                    throw CodexCatalogFailure(.protocolViolation)
                }
                if let methodAny = object["method"] {
                    // A well-formed server NOTIFICATION is skipped without ever being
                    // interpreted. Membership in a fixed allow-list is deliberately NOT
                    // required: the vendor adds notifications between releases (0.146.0
                    // emits remoteControl/status/changed immediately after the initialize
                    // response), and an allow-list turns that drift into a hard catalog
                    // failure - the exact fail-closed-on-vendor-drift behaviour this
                    // evergreen path exists to remove. Containment is preserved by
                    // construction: an unknown notification's params are never parsed or
                    // surfaced, a server REQUEST (method WITH an id) still fails closed so
                    // injection is impossible, and maxNotifications still bounds the stream.
                    guard methodAny is String,
                          object["id"] == nil,
                          object["result"] == nil,
                          object["error"] == nil else {
                        throw CodexCatalogFailure(.protocolViolation)
                    }
                    state.notifications += 1
                    guard state.notifications <= bounds.maxNotifications else {
                        throw CodexCatalogFailure(.boundExceeded)
                    }
                    continue
                }
                guard strictInteger(object["id"]) == id,
                      object["error"] == nil,
                      let result = object["result"] as? [String: Any] else {
                    throw CodexCatalogFailure(.protocolViolation)
                }
                return result
            }
        }
    }

    private static func parsePage(
        _ result: [String: Any],
        bounds: CodexCatalogBounds
    ) throws -> ParsedPage {
        guard let data = result["data"] as? [Any] else {
            throw CodexCatalogFailure(.protocolViolation)
        }
        let nextCursor: String?
        if result["nextCursor"] == nil || result["nextCursor"] is NSNull {
            nextCursor = nil
        } else if let value = result["nextCursor"] as? String {
            try requireBounded(value, bounds: bounds)
            nextCursor = value
        } else {
            throw CodexCatalogFailure(.paginationViolation)
        }
        let rows = try data.map { try parseRow($0, bounds: bounds) }
        var unknown = result
        unknown.removeValue(forKey: "data")
        unknown.removeValue(forKey: "nextCursor")
        return ParsedPage(
            rows: rows,
            nextCursor: nextCursor,
            metadata: ModelCatalogPageMetadata(
                unknownFields: try unknownFields(unknown, bounds: bounds)))
    }

    private static func parseRow(
        _ any: Any,
        bounds: CodexCatalogBounds
    ) throws -> ModelCatalogRow {
        guard var object = any as? [String: Any] else {
            throw CodexCatalogFailure(.invalidCatalog)
        }
        let id = try requiredString("id", in: &object, bounds: bounds)
        let model = try requiredString("model", in: &object, bounds: bounds)
        let displayName = try optionalString("displayName", in: &object, bounds: bounds)
        let description = try optionalString("description", in: &object, bounds: bounds)
        guard let hidden = strictBool(object.removeValue(forKey: "hidden")) else {
            throw CodexCatalogFailure(.invalidCatalog)
        }
        let defaultEffort = try optionalString(
            "defaultReasoningEffort", in: &object, bounds: bounds)
        guard let effortValues = object.removeValue(
            forKey: "supportedReasoningEfforts") as? [Any] else {
            throw CodexCatalogFailure(.invalidCatalog)
        }
        let efforts = try effortValues.map { try parseEffort($0, bounds: bounds) }
        let modalities = try optionalStringArray(
            "inputModalities", in: &object, bounds: bounds)
        let supportsPersonality = try optionalBool("supportsPersonality", in: &object)
        let isDefault = try optionalBool("isDefault", in: &object)
        let upgrade = try optionalString("upgrade", in: &object, bounds: bounds)
        let upgradeInfo = try optionalUpgradeInfo(
            "upgradeInfo", in: &object, bounds: bounds)
        if let upgrade, let structured = upgradeInfo?.model, upgrade != structured {
            throw CodexCatalogFailure(.invalidCatalog)
        }
        return ModelCatalogRow(
            id: id,
            model: model,
            displayName: displayName,
            description: description,
            hidden: hidden,
            defaultReasoningEffort: defaultEffort,
            supportedReasoningEfforts: efforts,
            inputModalities: modalities,
            supportsPersonality: supportsPersonality,
            isDefault: isDefault,
            upgrade: upgrade,
            upgradeInfo: upgradeInfo,
            unknownFields: try unknownFields(object, bounds: bounds))
    }

    private static func parseEffort(
        _ any: Any,
        bounds: CodexCatalogBounds
    ) throws -> ModelCatalogReasoningEffort {
        guard var object = any as? [String: Any] else {
            throw CodexCatalogFailure(.invalidCatalog)
        }
        return ModelCatalogReasoningEffort(
            reasoningEffort: try requiredString(
                "reasoningEffort", in: &object, bounds: bounds),
            description: try optionalString("description", in: &object, bounds: bounds),
            unknownFields: try unknownFields(object, bounds: bounds))
    }

    private static func optionalUpgradeInfo(
        _ key: String,
        in object: inout [String: Any],
        bounds: CodexCatalogBounds
    ) throws -> ModelCatalogUpgradeInfo? {
        guard let value = object.removeValue(forKey: key) else { return nil }
        if value is NSNull { return nil }
        guard var fields = value as? [String: Any] else {
            throw CodexCatalogFailure(.invalidCatalog)
        }
        return ModelCatalogUpgradeInfo(
            model: try requiredString("model", in: &fields, bounds: bounds),
            upgradeCopy: try optionalString("upgradeCopy", in: &fields, bounds: bounds),
            modelLink: try optionalString("modelLink", in: &fields, bounds: bounds),
            migrationMarkdown: try optionalString(
                "migrationMarkdown", in: &fields, bounds: bounds),
            unknownFields: try unknownFields(fields, bounds: bounds))
    }

    private static func requiredString(
        _ key: String,
        in object: inout [String: Any],
        bounds: CodexCatalogBounds
    ) throws -> String {
        guard let value = object.removeValue(forKey: key) as? String,
              !value.isEmpty else {
            throw CodexCatalogFailure(.invalidCatalog)
        }
        try requireBounded(value, bounds: bounds)
        return value
    }

    private static func optionalString(
        _ key: String,
        in object: inout [String: Any],
        bounds: CodexCatalogBounds
    ) throws -> String? {
        guard let value = object.removeValue(forKey: key) else { return nil }
        if value is NSNull { return nil }
        guard let string = value as? String else {
            throw CodexCatalogFailure(.invalidCatalog)
        }
        try requireBounded(string, bounds: bounds)
        return string
    }

    private static func optionalBool(
        _ key: String,
        in object: inout [String: Any]
    ) throws -> Bool? {
        guard let value = object.removeValue(forKey: key) else { return nil }
        if value is NSNull { return nil }
        guard let boolean = strictBool(value) else {
            throw CodexCatalogFailure(.invalidCatalog)
        }
        return boolean
    }

    private static func optionalStringArray(
        _ key: String,
        in object: inout [String: Any],
        bounds: CodexCatalogBounds
    ) throws -> [String]? {
        guard let value = object.removeValue(forKey: key) else { return nil }
        if value is NSNull { return nil }
        guard let values = value as? [Any] else {
            throw CodexCatalogFailure(.invalidCatalog)
        }
        return try values.map {
            guard let string = $0 as? String else {
                throw CodexCatalogFailure(.invalidCatalog)
            }
            try requireBounded(string, bounds: bounds)
            return string
        }
    }

    private static func requireBounded(
        _ value: String,
        bounds: CodexCatalogBounds
    ) throws {
        guard value.utf8.count <= bounds.maxStringBytes else {
            throw CodexCatalogFailure(.boundExceeded)
        }
    }

    private static func strictBool(_ any: Any?) -> Bool? {
        guard let number = any as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func strictInteger(_ any: Any?) -> Int? {
        guard let number = any as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite, floor(value) == value,
              value >= Double(Int.min), value <= Double(Int.max) else {
            return nil
        }
        return Int(value)
    }

    private static func unknownFields(
        _ object: [String: Any],
        bounds: CodexCatalogBounds
    ) throws -> [String: ModelCatalogJSONValue] {
        var nodeCount = 0
        return try object.reduce(into: [:]) { result, pair in
            try requireBounded(pair.key, bounds: bounds)
            result[pair.key] = try jsonValue(
                pair.value, depth: 1, nodeCount: &nodeCount, bounds: bounds)
        }
    }

    private static func jsonValue(
        _ any: Any,
        depth: Int,
        nodeCount: inout Int,
        bounds: CodexCatalogBounds
    ) throws -> ModelCatalogJSONValue {
        nodeCount += 1
        guard nodeCount <= bounds.maxJSONNodes, depth <= bounds.maxJSONDepth else {
            throw CodexCatalogFailure(.boundExceeded)
        }
        if any is NSNull { return .null }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            guard double.isFinite else { throw CodexCatalogFailure(.protocolViolation) }
            if floor(double) == double,
               double >= Double(Int64.min), double <= Double(Int64.max) {
                return .integer(number.int64Value)
            }
            return .number(double)
        }
        if let string = any as? String {
            try requireBounded(string, bounds: bounds)
            return .string(string)
        }
        if let values = any as? [Any] {
            return .array(try values.map {
                try jsonValue(
                    $0, depth: depth + 1, nodeCount: &nodeCount, bounds: bounds)
            })
        }
        if let fields = any as? [String: Any] {
            var result: [String: ModelCatalogJSONValue] = [:]
            for (key, value) in fields {
                try requireBounded(key, bounds: bounds)
                result[key] = try jsonValue(
                    value, depth: depth + 1, nodeCount: &nodeCount, bounds: bounds)
            }
            return .object(result)
        }
        throw CodexCatalogFailure(.protocolViolation)
    }

    static func validateCachedCatalog(
        _ catalog: ModelCatalog,
        bounds: CodexCatalogBounds
    ) throws {
        guard !catalog.rows.isEmpty,
              catalog.rows.count <= bounds.maxItems,
              catalog.pageMetadata.count <= bounds.maxPages else {
            throw CodexCatalogFailure(.cacheRead)
        }
        var ids: Set<String> = []
        var models: Set<String> = []
        for row in catalog.rows {
            guard !row.id.isEmpty, !row.model.isEmpty,
                  row.id.utf8.count <= bounds.maxStringBytes,
                  row.model.utf8.count <= bounds.maxStringBytes,
                  ids.insert(row.id).inserted,
                  models.insert(row.model).inserted,
                  row.upgrade == nil || row.upgradeInfo == nil
                    || row.upgrade == row.upgradeInfo?.model else {
                throw CodexCatalogFailure(.cacheRead)
            }
            let strings = [
                row.displayName, row.description, row.defaultReasoningEffort,
                row.upgrade, row.upgradeInfo?.model, row.upgradeInfo?.upgradeCopy,
                row.upgradeInfo?.modelLink, row.upgradeInfo?.migrationMarkdown,
            ].compactMap { $0 }
                + row.supportedReasoningEfforts.flatMap {
                    [$0.reasoningEffort, $0.description].compactMap { $0 }
                }
                + (row.inputModalities ?? [])
            guard strings.allSatisfy({ $0.utf8.count <= bounds.maxStringBytes }) else {
                throw CodexCatalogFailure(.cacheRead)
            }
            var nodes = 0
            try validateUnknownFields(
                row.unknownFields, depth: 1, nodes: &nodes, bounds: bounds)
            for effort in row.supportedReasoningEfforts {
                try validateUnknownFields(
                    effort.unknownFields, depth: 1, nodes: &nodes, bounds: bounds)
            }
            if let upgradeInfo = row.upgradeInfo {
                try validateUnknownFields(
                    upgradeInfo.unknownFields, depth: 1,
                    nodes: &nodes, bounds: bounds)
            }
        }
        for metadata in catalog.pageMetadata {
            var nodes = 0
            try validateUnknownFields(
                metadata.unknownFields, depth: 1, nodes: &nodes, bounds: bounds)
        }
    }

    private static func validateUnknownFields(
        _ fields: [String: ModelCatalogJSONValue],
        depth: Int,
        nodes: inout Int,
        bounds: CodexCatalogBounds
    ) throws {
        guard depth <= bounds.maxJSONDepth else {
            throw CodexCatalogFailure(.cacheRead)
        }
        for (key, value) in fields {
            guard key.utf8.count <= bounds.maxStringBytes else {
                throw CodexCatalogFailure(.cacheRead)
            }
            try validateJSONValue(
                value, depth: depth, nodes: &nodes, bounds: bounds)
        }
    }

    private static func validateJSONValue(
        _ value: ModelCatalogJSONValue,
        depth: Int,
        nodes: inout Int,
        bounds: CodexCatalogBounds
    ) throws {
        nodes += 1
        guard nodes <= bounds.maxJSONNodes, depth <= bounds.maxJSONDepth else {
            throw CodexCatalogFailure(.cacheRead)
        }
        switch value {
        case .null, .bool, .integer:
            break
        case .number(let number):
            guard number.isFinite else { throw CodexCatalogFailure(.cacheRead) }
        case .string(let string):
            guard string.utf8.count <= bounds.maxStringBytes else {
                throw CodexCatalogFailure(.cacheRead)
            }
        case .array(let values):
            for child in values {
                try validateJSONValue(
                    child, depth: depth + 1, nodes: &nodes, bounds: bounds)
            }
        case .object(let fields):
            try validateUnknownFields(
                fields, depth: depth + 1, nodes: &nodes, bounds: bounds)
        }
    }
}

struct CodexModelCatalogCache: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let checkedAt: String
    let catalog: ModelCatalog

    init(version: Int = currentVersion, checkedAt: String, catalog: ModelCatalog) {
        self.version = version
        self.checkedAt = checkedAt
        self.catalog = catalog
    }

    static func decode(
        _ data: Data,
        maxBytes: Int = CodexCatalogBounds().maxCacheBytes
    ) throws -> CodexModelCatalogCache {
        guard data.count <= maxBytes else { throw CodexCatalogFailure(.boundExceeded) }
        let decoded: CodexModelCatalogCache
        do { decoded = try JSONDecoder().decode(CodexModelCatalogCache.self, from: data) }
        catch { throw CodexCatalogFailure(.cacheRead) }
        let bounds = CodexCatalogBounds(maxCacheBytes: maxBytes)
        guard decoded.version == currentVersion,
              !decoded.checkedAt.isEmpty,
              decoded.checkedAt.utf8.count <= bounds.maxStringBytes else {
            throw CodexCatalogFailure(.cacheRead)
        }
        try CodexCatalogTransport.validateCachedCatalog(
            decoded.catalog, bounds: bounds)
        return decoded
    }

    func encode(maxBytes: Int = CodexCatalogBounds().maxCacheBytes) throws -> Data {
        let bounds = CodexCatalogBounds(maxCacheBytes: maxBytes)
        guard version == Self.currentVersion,
              !checkedAt.isEmpty,
              checkedAt.utf8.count <= bounds.maxStringBytes else {
            throw CodexCatalogFailure(.cacheWrite)
        }
        try CodexCatalogTransport.validateCachedCatalog(catalog, bounds: bounds)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do { data = try encoder.encode(self) }
        catch { throw CodexCatalogFailure(.cacheWrite) }
        guard data.count <= maxBytes else { throw CodexCatalogFailure(.boundExceeded) }
        return data
    }
}

struct CodexCatalogCacheIO {
    let read: () throws -> Data?
    let replaceAtomically: (Data) throws -> Void
}

enum ModelCatalogDiagnostic: String, Codable, Equatable, CaseIterable {
    case current
    case protocolViolation = "protocol"
    case paginationViolation = "pagination"
    case invalidCatalog = "catalog"
    case boundExceeded = "bound"
    case timeout
    case prematureEOF = "eof"
    case processFailure = "process"
    case processLaunch = "launch"
    case providerUnavailable = "provider"
    case compatibilityBoundary = "compatibility"
    case cacheRead = "cache-read"
    case cacheWrite = "cache-write"

    init(_ code: CodexCatalogFailure.Code) {
        self = ModelCatalogDiagnostic(rawValue: code.rawValue) ?? .providerUnavailable
    }
}

struct ModelCatalogCheckResult: Equatable {
    let catalog: ModelCatalog?
    let checkedAt: String?
    let isStale: Bool
    let diagnostic: ModelCatalogDiagnostic
}

enum CodexModelCatalogChecker {
    static func refresh(
        checkedAt: String,
        provider: @escaping () throws -> ModelCatalog,
        cache: CodexCatalogCacheIO,
        bounds: CodexCatalogBounds = CodexCatalogBounds(),
        serialize: ((_ body: @escaping () -> ModelCatalogCheckResult)
                    -> ModelCatalogCheckResult) = { body in body() }
    ) -> ModelCatalogCheckResult {
        serialize {
            let prior: CodexModelCatalogCache?
            do {
                if let bytes = try cache.read() {
                    prior = try CodexModelCatalogCache.decode(
                        bytes, maxBytes: bounds.maxCacheBytes)
                } else {
                    prior = nil
                }
            } catch {
                return ModelCatalogCheckResult(
                    catalog: nil,
                    checkedAt: nil,
                    isStale: true,
                    diagnostic: .cacheRead)
            }
            do {
                let catalog = try provider()
                let updated = CodexModelCatalogCache(
                    checkedAt: checkedAt, catalog: catalog)
                let bytes = try updated.encode(maxBytes: bounds.maxCacheBytes)
                do { try cache.replaceAtomically(bytes) }
                catch {
                    return ModelCatalogCheckResult(
                        catalog: prior?.catalog,
                        checkedAt: prior?.checkedAt,
                        isStale: true,
                        diagnostic: .cacheWrite)
                }
                return ModelCatalogCheckResult(
                    catalog: catalog,
                    checkedAt: checkedAt,
                    isStale: false,
                    diagnostic: .current)
            } catch let failure as CodexCatalogFailure {
                return ModelCatalogCheckResult(
                    catalog: prior?.catalog,
                    checkedAt: prior?.checkedAt,
                    isStale: true,
                    diagnostic: ModelCatalogDiagnostic(failure.code))
            } catch {
                return ModelCatalogCheckResult(
                    catalog: prior?.catalog,
                    checkedAt: prior?.checkedAt,
                    isStale: true,
                    diagnostic: .providerUnavailable)
            }
        }
    }
}

enum CodexModelCatalogDiskCache {
    static var defaultURL: URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent("codex-model-catalog.json", isDirectory: false)
    }

    static func io(
        url: URL = defaultURL,
        bounds: CodexCatalogBounds = CodexCatalogBounds(),
        postInstallValidation: (() throws -> Void)? = nil
    ) -> CodexCatalogCacheIO {
        CodexCatalogCacheIO(
            read: {
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try readBounded(
                    url: url,
                    maxBytes: bounds.maxCacheBytes,
                    failure: .cacheRead)
            },
            replaceAtomically: { data in
                guard data.count <= bounds.maxCacheBytes else {
                    throw CodexCatalogFailure(.cacheWrite)
                }
                try CodexIsolationFoundation.secureDirectory(
                    url.deletingLastPathComponent())
                let fm = FileManager.default
                let existed = fm.fileExists(atPath: url.path)
                let prior = existed
                    ? try readBounded(
                        url: url,
                        maxBytes: bounds.maxCacheBytes,
                        failure: .cacheWrite)
                    : nil
                let suffix = UUID().uuidString
                let staged = url.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".\(url.lastPathComponent).staged-\(suffix)")
                let backup = url.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".\(url.lastPathComponent).backup-\(suffix)")
                var installed = false
                var backedUp = false
                do {
                    try CodexIsolationFoundation.atomicRestrictiveWrite(
                        data, to: staged, finalMode: 0o600,
                        allowReplacement: false)
                    if existed {
                        try fm.moveItem(at: url, to: backup)
                        backedUp = true
                    }
                    try fm.moveItem(at: staged, to: url)
                    installed = true
                    guard try readBounded(
                        url: url,
                        maxBytes: bounds.maxCacheBytes,
                        failure: .cacheWrite) == data else {
                        throw CodexCatalogFailure(.cacheWrite)
                    }
                    try postInstallValidation?()
                    if backedUp { try fm.removeItem(at: backup) }
                } catch {
                    do {
                        if installed && fm.fileExists(atPath: url.path) {
                            try fm.removeItem(at: url)
                        }
                        if backedUp && fm.fileExists(atPath: backup.path) {
                            try fm.moveItem(at: backup, to: url)
                        }
                        if fm.fileExists(atPath: staged.path) {
                            try fm.removeItem(at: staged)
                        }
                        if let prior {
                            guard try readBounded(
                                url: url,
                                maxBytes: bounds.maxCacheBytes,
                                failure: .cacheWrite) == prior else {
                                throw CodexCatalogFailure(.cacheWrite)
                            }
                        } else if fm.fileExists(atPath: url.path) {
                            throw CodexCatalogFailure(.cacheWrite)
                        }
                    } catch {
                        throw CodexCatalogFailure(.cacheWrite)
                    }
                    throw CodexCatalogFailure(.cacheWrite)
                }
            })
    }

    static func loadLastKnownGood(
        url: URL = defaultURL,
        bounds: CodexCatalogBounds = CodexCatalogBounds()
    ) -> CodexModelCatalogCache? {
        do {
            guard let data = try io(url: url, bounds: bounds).read() else {
                return nil
            }
            return try CodexModelCatalogCache.decode(
                data, maxBytes: bounds.maxCacheBytes)
        } catch {
            return nil
        }
    }

    private static func readBounded(
        url: URL,
        maxBytes: Int,
        failure: CodexCatalogFailure.Code
    ) throws -> Data {
        var st = stat()
        guard lstat(url.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o777) == 0o600,
              st.st_size >= 0,
              st.st_size <= maxBytes else {
            throw CodexCatalogFailure(failure)
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw CodexCatalogFailure(failure) }
        defer { try? handle.close() }
        do {
            let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            guard data.count <= maxBytes else {
                throw CodexCatalogFailure(failure)
            }
            return data
        } catch let error as CodexCatalogFailure {
            throw error
        } catch {
            throw CodexCatalogFailure(failure)
        }
    }
}

enum CodexModelCatalogProvider {
    static func refresh(
        checkedAt: String,
        runnerPath: String = CodexProviderRuntime.bundledRunnerPath,
        bounds: CodexCatalogBounds = CodexCatalogBounds(),
        processFactory: @escaping CodexCatalogProcessFactory = CodexCatalogPOSIXSession.start,
        cache: CodexCatalogCacheIO = CodexModelCatalogDiskCache.io()
    ) -> ModelCatalogCheckResult {
        do {
            return try CodexProviderRuntime.withPreparedCompatibilityBoundary(
                runnerPath: runnerPath
            ) { paths, receipt in
                let launch = CodexCatalogTransport.productionLaunch(
                    paths: paths,
                    executablePath:
                        try CodexIsolationFoundation.executableSnapshotURL(
                            paths: paths, receipt: receipt).path,
                    executableIdentity: receipt.executable,
                    bounds: bounds)
                return CodexModelCatalogChecker.refresh(
                    checkedAt: checkedAt,
                    provider: {
                        try CodexCatalogTransport.acquire(
                            launch: launch,
                            processFactory: processFactory,
                            bounds: bounds)
                    },
                    cache: cache,
                    bounds: bounds)
            }
        } catch {
            return CodexModelCatalogChecker.refresh(
                checkedAt: checkedAt,
                provider: { throw CodexCatalogFailure(.compatibilityBoundary) },
                cache: cache,
                bounds: bounds)
        }
    }
}
