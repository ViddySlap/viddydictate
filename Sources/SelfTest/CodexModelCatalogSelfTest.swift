import Darwin
import Foundation

/// Fixture-only characterization for the stable Codex app-server catalog surface. The fake session
/// never launches a process, reads auth, touches a live cache, uses the network, or carries user text.
enum CodexModelCatalogSelfTest {
    private final class FakeSession: CodexCatalogProcessSession {
        var reads: [CodexCatalogReadResult]
        var writes: [Data] = []
        var closedInput = false
        var finished = false
        var terminated = false
        var finishDeadlines: [TimeInterval] = []
        var terminationDeadlines: [TimeInterval] = []
        var exit: CodexCatalogProcessExit
        var terminationExits: [CodexCatalogProcessExit]
        var readCount = 0
        var readDeadlines: [TimeInterval] = []
        var beforeRead: ((Int) -> Void)?

        init(_ reads: [CodexCatalogReadResult],
             exit: CodexCatalogProcessExit = .clean,
             terminationExits: [CodexCatalogProcessExit] = []) {
            self.reads = reads
            self.exit = exit
            self.terminationExits = terminationExits
        }

        func writeLine(_ data: Data) throws {
            writes.append(data)
        }

        func readLine(
            absoluteDeadline: TimeInterval
        ) -> CodexCatalogReadResult {
            readCount += 1
            readDeadlines.append(absoluteDeadline)
            beforeRead?(readCount)
            return reads.isEmpty ? .eof : reads.removeFirst()
        }

        func closeInput() {
            closedInput = true
        }

        func finishAndReap(
            absoluteDeadline: TimeInterval
        ) -> CodexCatalogProcessExit {
            finished = true
            finishDeadlines.append(absoluteDeadline)
            return exit
        }

        func terminateAndReap(
            absoluteDeadline: TimeInterval
        ) -> CodexCatalogProcessExit {
            terminated = true
            terminationDeadlines.append(absoluteDeadline)
            if !terminationExits.isEmpty {
                return terminationExits.removeFirst()
            }
            return exit
        }
    }

    private struct CacheWriteFault: Error {}

    static func run() -> Bool {
        print("=== Codex app-server model catalog transport/cache - fixture selftest ===")
        let reporter = SelfTestReporter()

        checkHandshakeAndDTO(reporter.record)
        checkProtocolFailures(reporter.record)
        checkBoundsAndProcessFailures(reporter.record)
        checkRealProcessDeadline(reporter.record)
        checkLaunchIdentityAndRetryableReap(reporter.record)
        checkLaunchTimeSharesOverallDeadline(reporter.record)
        checkCacheAndSeams(reporter.record)
        CodexModelMigrationPlannerSelfTest.run(reporter.record)

        print(reporter.passed
              ? "[codex-model-catalog-selftest] PASS"
              : "[codex-model-catalog-selftest] FAIL")
        return reporter.passed
    }

    private static func checkHandshakeAndDTO(_ check: (String, Bool) -> Void) {
        print("--- stable handshake, pagination, and exact DTO identities ---")
        let session = FakeSession([
            line(#"{"id":1,"result":{"userAgent":"fixture","futureInit":{"ok":true}}}"#),
            line(#"{"method":"server/heartbeat","params":{"future":1}}"#),
            line(#"{"id":2,"result":{"data":[{"id":"preset-retired","model":"gpt-executable-old","displayName":"untrusted display","description":"untrusted description","hidden":true,"defaultReasoningEffort":"future-ultra","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"low copy","futureEffort":7},{"reasoningEffort":"future-ultra","description":"future copy"}],"inputModalities":["text","future-modality"],"supportsPersonality":false,"isDefault":false,"upgrade":"preset-current","upgradeInfo":{"model":"preset-current","upgradeCopy":"untrusted copy","modelLink":"https://example.invalid","futureUpgrade":true},"futureRow":{"nested":["kept"]}}],"nextCursor":"opaque+/cursor==","futurePage":"kept"}}"#),
            line(#"{"id":3,"result":{"data":[{"id":"preset-current","model":"gpt-executable-current","hidden":false,"defaultReasoningEffort":"future-ultra","supportedReasoningEfforts":[{"reasoningEffort":"future-ultra","description":"future copy"},{"reasoningEffort":"low","description":"low copy"}],"inputModalities":["text"],"futureRow":42}],"nextCursor":null}}"#),
            .eof,
        ])
        // No allow-list: the interleaved server/heartbeat notification above is an
        // UNKNOWN notification carrying a payload, and the catalog must skip it
        // without interpreting it rather than failing closed on vendor drift.
        let bounds = CodexCatalogBounds()
        let result = try? CodexCatalogTransport.acquire(
            session: session, bounds: bounds, monotonicNow: { 1 })

        check("minimal handshake plus two model/list pages succeeds",
              result?.rows.count == 2)
        check("an unknown interleaved notification is skipped, not fatal, and its "
                + "payload never reaches the catalog",
              result?.rows.count == 2
                && result?.pageMetadata.allSatisfy {
                    $0.unknownFields["future"] == nil
                } == true)
        check("preset id and executable model remain distinct",
              result?.rows.first?.id == "preset-retired"
                && result?.rows.first?.model == "gpt-executable-old")
        check("open effort strings and advertised order are preserved",
              result?.rows.first?.supportedReasoningEfforts.map(\.reasoningEffort)
                == ["low", "future-ultra"])
        check("modalities, hidden state, and default effort are exact",
              result?.rows.first?.hidden == true
                && result?.rows.first?.inputModalities == ["text", "future-modality"]
                && result?.rows.first?.defaultReasoningEffort == "future-ultra")
        check("legacy and structured upgrade forms are both retained",
              result?.rows.first?.upgrade == "preset-current"
                && result?.rows.first?.upgradeInfo?.model == "preset-current")
        check("unknown additive row/effort/upgrade/page fields survive decoding",
              result?.rows.first?.unknownFields["futureRow"] != nil
                && result?.rows.first?.supportedReasoningEfforts.first?
                    .unknownFields["futureEffort"] != nil
                && result?.rows.first?.upgradeInfo?.unknownFields["futureUpgrade"] != nil
                && result?.pageMetadata.first?.unknownFields["futurePage"] != nil)

        let sent = session.writes.compactMap(object)
        check("outbound order is initialize, initialized, model/list, model/list",
              sent.compactMap { $0["method"] as? String }
                == ["initialize", "initialized", "model/list", "model/list"])
        let initialize = sent.first
        let initializeParams = initialize?["params"] as? [String: Any]
        check("initialize has minimal clientInfo and no capabilities",
              initialize?["id"] as? Int == 1
                && initializeParams?["clientInfo"] is [String: Any]
                && initializeParams?["capabilities"] == nil)
        let initialized = sent.count > 1 ? sent[1] : [:]
        check("initialized is a notification with empty params",
              initialized["id"] == nil
                && (initialized["params"] as? [String: Any])?.isEmpty == true)
        let firstList = sent.count > 2 ? sent[2] : [:]
        let secondList = sent.count > 3 ? sent[3] : [:]
        let firstParams = firstList["params"] as? [String: Any]
        let secondParams = secondList["params"] as? [String: Any]
        check("every list request includes hidden models and only the opaque cursor advances",
              firstParams?["includeHidden"] as? Bool == true
                && firstParams?["cursor"] == nil
                && secondParams?["includeHidden"] as? Bool == true
                && secondParams?["cursor"] as? String == "opaque+/cursor==")
        check("success closes stdin and reaps without the failure path",
              session.closedInput && session.finished && !session.terminated)
    }

    private static func checkProtocolFailures(_ check: (String, Bool) -> Void) {
        print("--- fail-closed method, id, catalog, and pagination rules ---")
        expectFailure(
            "mismatched response id fails closed", .protocolViolation, check,
            [line(#"{"id":99,"result":{}}"#)])
        expectFailure(
            "server request injection fails closed", .protocolViolation, check,
            [line(#"{"id":7,"method":"item/commandExecution/requestApproval","params":{}}"#)])
        // An unknown NOTIFICATION is tolerated (skipped unparsed) rather than fatal; a
        // server REQUEST - a method WITH an id - still fails closed above, which is what
        // actually prevents injection. Pinned as a positive case in
        // checkUnknownNotificationsAreTolerated().
        expectFailure(
            "premature EOF after an unknown notification still fails closed",
            .prematureEOF, check,
            [line(#"{"method":"thread/started","params":{}}"#), .eof])
        expectFailure(
            "malformed JSONL fails closed", .protocolViolation, check,
            [.line(Data("{".utf8))])
        expectFailure(
            "numeric hidden state is not accepted as a boolean", .invalidCatalog, check,
            [line(#"{"id":1,"result":{}}"#),
             line(#"{"id":2,"result":{"data":[{"id":"a","model":"ma","hidden":1,"supportedReasoningEfforts":[]}],"nextCursor":null}}"#)])
        expectFailure(
            "premature EOF fails closed", .prematureEOF, check, [.eof])
        for (label, trailing) in [
            ("trailing server request", line(#"{"id":9,"method":"item/request","params":{}}"#)),
            ("trailing notification", line(#"{"method":"server/heartbeat","params":{}}"#)),
            ("trailing JSONL", line(#"{"future":"payload"}"#)),
        ] {
            expectFailure(
                "valid final response rejects \(label)", .protocolViolation, check,
                Array(validCatalogReads().dropLast()) + [trailing, .eof])
        }
        expectFailure(
            "valid final response rejects trailing partial output", .processFailure, check,
            Array(validCatalogReads().dropLast()) + [.failure])
        expectFailure(
            "valid final response rejects trailing stdout overflow", .boundExceeded, check,
            Array(validCatalogReads().dropLast()) + [.overflow])

        let initOK = line(#"{"id":1,"result":{}}"#)
        expectFailure(
            "empty catalog fails closed", .invalidCatalog, check,
            [initOK, line(#"{"id":2,"result":{"data":[],"nextCursor":null}}"#)])
        expectFailure(
            "cursor cycle fails closed", .paginationViolation, check,
            [initOK,
             line(#"{"id":2,"result":{"data":[{"id":"a","model":"ma","hidden":false,"supportedReasoningEfforts":[]}],"nextCursor":"same"}}"#),
             line(#"{"id":3,"result":{"data":[{"id":"b","model":"mb","hidden":false,"supportedReasoningEfforts":[]}],"nextCursor":"same"}}"#)])
        expectFailure(
            "duplicate preset ids fail closed", .invalidCatalog, check,
            [initOK,
             line(#"{"id":2,"result":{"data":[{"id":"same","model":"ma","hidden":false,"supportedReasoningEfforts":[]},{"id":"same","model":"mb","hidden":false,"supportedReasoningEfforts":[]}],"nextCursor":null}}"#)])
        expectFailure(
            "duplicate executable models fail closed", .invalidCatalog, check,
            [initOK,
             line(#"{"id":2,"result":{"data":[{"id":"a","model":"same","hidden":false,"supportedReasoningEfforts":[]},{"id":"b","model":"same","hidden":false,"supportedReasoningEfforts":[]}],"nextCursor":null}}"#)])
        expectFailure(
            "conflicting upgrade forms fail closed", .invalidCatalog, check,
            [initOK,
             line(#"{"id":2,"result":{"data":[{"id":"a","model":"ma","hidden":true,"supportedReasoningEfforts":[],"upgrade":"b","upgradeInfo":{"model":"c"}}],"nextCursor":null}}"#)])
    }

    private static func checkBoundsAndProcessFailures(_ check: (String, Bool) -> Void) {
        print("--- line/byte/page/item/notification/time/process/stderr bounds ---")
        expectFailure(
            "oversized line fails closed", .boundExceeded, check,
            [.line(Data(repeating: 0x20, count: 65))],
            bounds: CodexCatalogBounds(maxLineBytes: 64))
        expectFailure(
            "read timeout fails closed", .timeout, check, [.timeout])
        expectFailure(
            "notification overflow fails closed", .boundExceeded, check,
            [line(#"{"method":"server/heartbeat","params":{}}"#),
             line(#"{"method":"server/heartbeat","params":{}}"#)],
            bounds: CodexCatalogBounds(maxNotifications: 1))
        expectFailure(
            "page overflow fails closed", .boundExceeded, check,
            [line(#"{"id":1,"result":{}}"#),
             line(#"{"id":2,"result":{"data":[{"id":"a","model":"ma","hidden":false,"supportedReasoningEfforts":[]}],"nextCursor":"more"}}"#)],
            bounds: CodexCatalogBounds(maxPages: 1))
        expectFailure(
            "item overflow fails closed", .boundExceeded, check,
            [line(#"{"id":1,"result":{}}"#),
             line(#"{"id":2,"result":{"data":[{"id":"a","model":"ma","hidden":false,"supportedReasoningEfforts":[]},{"id":"b","model":"mb","hidden":false,"supportedReasoningEfforts":[]}],"nextCursor":null}}"#)],
            bounds: CodexCatalogBounds(maxItems: 1, pageSize: 1))
        expectFailure(
            "opaque cursor byte overflow fails closed", .paginationViolation, check,
            [line(#"{"id":1,"result":{}}"#),
             line(#"{"id":2,"result":{"data":[{"id":"a","model":"ma","hidden":false,"supportedReasoningEfforts":[]}],"nextCursor":"long"}}"#)],
            bounds: CodexCatalogBounds(maxCursorBytes: 3))
        expectFailure(
            "stdout line-count overflow fails closed", .boundExceeded, check,
            validCatalogReads(),
            bounds: CodexCatalogBounds(maxLines: 1))
        expectFailure(
            "stdout total-byte overflow fails closed", .boundExceeded, check,
            [line(#"{"id":1,"result":{}}"#),
             line(#"{"method":"server/heartbeat","params":{"n":1}}"#),
             line(#"{"method":"server/heartbeat","params":{"n":2}}"#),
             line(#"{"method":"server/heartbeat","params":{"n":3}}"#),
             line(#"{"method":"server/heartbeat","params":{"n":4}}"#),
             line(#"{"method":"server/heartbeat","params":{"n":5}}"#),
             line(#"{"method":"server/heartbeat","params":{"n":6}}"#)],
            bounds: CodexCatalogBounds(
                maxLineBytes: 256,
                maxTotalStdoutBytes: 256))
        expectFailure(
            "process reader overflow fails closed", .boundExceeded, check,
            [.overflow])

        let nonzero = CodexCatalogProcessExit(
            exitCode: 9, timedOut: false, terminatedBySignal: false,
            leaderReaped: true, residualProcessGroup: false,
            stderrBytes: 0, stderrOverflow: false)
        expectFailure(
            "nonzero app-server exit fails closed", .processFailure, check,
            validCatalogReads(), exit: nonzero)
        let stderr = CodexCatalogProcessExit(
            exitCode: 0, timedOut: false, terminatedBySignal: false,
            leaderReaped: true, residualProcessGroup: false,
            stderrBytes: 1, stderrOverflow: false)
        expectFailure(
            "any stderr diagnostic is content-free and fails closed", .processFailure, check,
            validCatalogReads(), exit: stderr)
        let stderrOverflow = CodexCatalogProcessExit(
            exitCode: 0, timedOut: false, terminatedBySignal: false,
            leaderReaped: true, residualProcessGroup: false,
            stderrBytes: 131_072, stderrOverflow: true)
        expectFailure(
            "stderr overflow fails closed without retaining payload", .processFailure, check,
            validCatalogReads(), exit: stderrOverflow)
        let residual = CodexCatalogProcessExit(
            exitCode: 0, timedOut: false, terminatedBySignal: false,
            leaderReaped: true, residualProcessGroup: true,
            stderrBytes: 0, stderrOverflow: false)
        expectFailure(
            "residual process group fails closed", .processFailure, check,
            validCatalogReads(), exit: residual)
        for (label, exit) in [
            ("exit evidence stdout overflow",
             CodexCatalogProcessExit(
                exitCode: 0, timedOut: false, terminatedBySignal: false,
                leaderReaped: true, residualProcessGroup: false,
                stderrBytes: 0, stderrOverflow: false,
                stdoutOverflow: true)),
            ("exit evidence pending partial bytes",
             CodexCatalogProcessExit(
                exitCode: 0, timedOut: false, terminatedBySignal: false,
                leaderReaped: true, residualProcessGroup: false,
                stderrBytes: 0, stderrOverflow: false,
                stdoutPendingBytes: 1)),
            ("exit evidence stdout reader failure",
             CodexCatalogProcessExit(
                exitCode: 0, timedOut: false, terminatedBySignal: false,
                leaderReaped: true, residualProcessGroup: false,
                stderrBytes: 0, stderrOverflow: false,
                stdoutFailure: true)),
        ] {
            expectFailure(
                "\(label) fails closed", .processFailure, check,
                validCatalogReads(), exit: exit)
        }

        var ticks: [TimeInterval] = [0, 0, 99]
        let wallSession = FakeSession(validCatalogReads())
        do {
            _ = try CodexCatalogTransport.acquire(
                session: wallSession,
                bounds: CodexCatalogBounds(
                    wallClockSeconds: 1,
                    processGraceSeconds: 0.2),
                monotonicNow: { ticks.isEmpty ? 99 : ticks.removeFirst() })
            check("wall-clock overflow fails closed", false)
        } catch let failure as CodexCatalogFailure {
            check("wall-clock overflow fails closed",
                  failure.code == .timeout && wallSession.terminated)
        } catch {
            check("wall-clock overflow fails closed", false)
        }

        let zeroGraceSession = FakeSession(validCatalogReads())
        do {
            _ = try CodexCatalogTransport.acquire(
                session: zeroGraceSession,
                bounds: CodexCatalogBounds(processGraceSeconds: 0),
                monotonicNow: { 1 })
            check("catalog cleanup grace must be positive", false)
        } catch let failure as CodexCatalogFailure {
            check("catalog cleanup grace must be positive",
                  failure.code == .boundExceeded
                    && zeroGraceSession.writes.isEmpty
                    && zeroGraceSession.terminationDeadlines.isEmpty)
        } catch {
            check("catalog cleanup grace must be positive", false)
        }

        var protocolClock: TimeInterval = 0
        let lateLineSession = FakeSession(validCatalogReads())
        lateLineSession.beforeRead = { readCount in
            if readCount == 2 {
                protocolClock = 0.150_001
            }
        }
        do {
            _ = try CodexCatalogTransport.acquire(
                session: lateLineSession,
                bounds: CodexCatalogBounds(
                    wallClockSeconds: 0.2,
                    lineReadSeconds: 0.1,
                    processGraceSeconds: 0.05),
                monotonicNow: { protocolClock })
            check(
                "valid protocol line delivered after operation deadline is rejected with reserve",
                false)
        } catch let failure as CodexCatalogFailure {
            check(
                "valid protocol line delivered after operation deadline is rejected with reserve",
                failure.code == .timeout
                    && lateLineSession.terminated
                    && lateLineSession.terminationDeadlines == [0.2]
                    && lateLineSession.readDeadlines.allSatisfy {
                        $0 <= 0.15
                    })
        } catch {
            check(
                "valid protocol line delivered after operation deadline is rejected with reserve",
                false)
        }

        let incompleteCleanup = CodexCatalogProcessExit(
            exitCode: 137,
            timedOut: true,
            terminatedBySignal: true,
            leaderReaped: true,
            residualProcessGroup: false,
            stderrBytes: 0,
            stderrOverflow: false,
            drainsComplete: false)
        let retrySession = FakeSession(
            [.timeout],
            terminationExits: [incompleteCleanup, .clean])
        do {
            _ = try CodexCatalogTransport.acquire(
                session: retrySession,
                bounds: CodexCatalogBounds(
                    wallClockSeconds: 1,
                    processGraceSeconds: 0.4),
                monotonicNow: { 1 })
            check(
                "catch-path cleanup retries incomplete reap evidence",
                false)
        } catch let failure as CodexCatalogFailure {
            check(
                "catch-path cleanup retries incomplete reap evidence",
                failure.code == .timeout
                    && retrySession.terminationDeadlines.count == 2
                    && retrySession.terminationDeadlines
                        == [2, 2])
        } catch {
            check(
                "catch-path cleanup retries incomplete reap evidence",
                false)
        }
    }

    private static func checkCacheAndSeams(_ check: (String, Bool) -> Void) {
        print("--- injectable provider/cache seams and last-known-good rollback ---")
        guard let catalog = try? CodexCatalogTransport.acquire(
            session: FakeSession(validCatalogReads()),
            monotonicNow: { 1 }) else {
            check("catalog fixture for cache tests parses", false)
            return
        }
        var stored: Data?
        var writeCount = 0
        let cache = CodexCatalogCacheIO(
            read: { stored },
            replaceAtomically: { data in stored = data; writeCount += 1 })
        var serialized = false
        let fresh = CodexModelCatalogChecker.refresh(
            checkedAt: "2026-07-27T00:00:00Z",
            provider: { catalog },
            cache: cache,
            serialize: { body in serialized = true; return body() })
        check("successful acquisition is serialized and atomically cached",
              serialized && !fresh.isStale && writeCount == 1 && stored != nil)
        check("cache round-trip preserves the exact catalog",
              stored.flatMap { try? CodexModelCatalogCache.decode($0).catalog } == catalog)

        let lastKnownBytes = stored
        let failed = CodexModelCatalogChecker.refresh(
            checkedAt: "2026-07-27T00:01:00Z",
            provider: { throw CodexCatalogFailure(.timeout) },
            cache: cache)
        check("failed acquisition returns stale last-known-good and performs no write",
              failed.isStale && failed.catalog == catalog
                && failed.diagnostic == .timeout
                && writeCount == 1 && stored == lastKnownBytes)

        let rollbackCache = CodexCatalogCacheIO(
            read: { lastKnownBytes },
            replaceAtomically: { _ in throw CacheWriteFault() })
        let writeFailed = CodexModelCatalogChecker.refresh(
            checkedAt: "2026-07-27T00:02:00Z",
            provider: { catalog },
            cache: rollbackCache)
        check("cache-write failure returns the prior catalog without exposing new state",
              writeFailed.isStale && writeFailed.catalog == catalog
                && writeFailed.diagnostic == .cacheWrite
                && stored == lastKnownBytes)

        var boundedWriteCount = 0
        let boundedCache = CodexCatalogCacheIO(
            read: { lastKnownBytes },
            replaceAtomically: { _ in boundedWriteCount += 1 })
        let cacheBound = CodexModelCatalogChecker.refresh(
            checkedAt: "2026-07-27T00:03:00Z",
            provider: { catalog },
            cache: boundedCache,
            bounds: CodexCatalogBounds(maxCacheBytes: 64))
        check("cache byte overflow fails closed before atomic replacement",
              cacheBound.isStale && cacheBound.catalog == nil
                && cacheBound.diagnostic == .cacheRead
                && boundedWriteCount == 0)

        let diskRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "viddydictate-catalog-cache-\(UUID().uuidString)", isDirectory: true)
        let diskURL = diskRoot.appendingPathComponent("catalog.json")
        var diskRoundTrip = false
        var diskRollback = false
        var sparseRejectedWithoutOverwrite = false
        do {
            try CodexIsolationFoundation.secureDirectory(diskRoot)
            defer { try? FileManager.default.removeItem(at: diskRoot) }
            let disk = CodexModelCatalogDiskCache.io(url: diskURL)
            if let bytes = lastKnownBytes {
                try disk.replaceAtomically(bytes)
                var st = stat()
                diskRoundTrip = try disk.read() == bytes
                    && lstat(diskURL.path, &st) == 0
                    && (st.st_mode & 0o777) == 0o600

                let injected = CodexModelCatalogDiskCache.io(
                    url: diskURL,
                    postInstallValidation: { throw CacheWriteFault() })
                let replacement = Data("replacement".utf8)
                do { try injected.replaceAtomically(replacement) }
                catch {
                    diskRollback = try disk.read() == bytes
                }

                try FileManager.default.removeItem(at: diskURL)
                FileManager.default.createFile(
                    atPath: diskURL.path, contents: Data(), attributes: [
                        .posixPermissions: NSNumber(value: 0o600),
                    ])
                let sparse = try FileHandle(forWritingTo: diskURL)
                try sparse.truncate(
                    atOffset: UInt64(CodexCatalogBounds().maxCacheBytes + 1))
                try sparse.close()
                var providerCalls = 0
                let sparseSize = (try FileManager.default.attributesOfItem(
                    atPath: diskURL.path)[.size] as? NSNumber)?.intValue
                let sparseResult = CodexModelCatalogChecker.refresh(
                    checkedAt: "2026-07-27T00:04:00Z",
                    provider: { providerCalls += 1; return catalog },
                    cache: disk)
                let sizeAfter = (try FileManager.default.attributesOfItem(
                    atPath: diskURL.path)[.size] as? NSNumber)?.intValue
                sparseRejectedWithoutOverwrite =
                    sparseResult.diagnostic == .cacheRead
                    && providerCalls == 0
                    && sparseSize == CodexCatalogBounds().maxCacheBytes + 1
                    && sizeAfter == sparseSize
            }
        } catch {
            try? FileManager.default.removeItem(at: diskRoot)
        }
        check("app-local disk cache round-trips atomically with mode 0600",
              diskRoundTrip)
        check("real disk post-install fault restores prior last-known-good bytes",
              diskRollback)
        check("oversized sparse cache is metadata-rejected without provider/write/read allocation",
              sparseRejectedWithoutOverwrite)

        let paths = CodexIsolationFoundation.scratchPaths(
            root: URL(fileURLWithPath: "/private/tmp/viddydictate-catalog-fixture",
                      isDirectory: true))
        let cheap = CodexIsolationFoundation.CheapFileIdentity(
            device: 1, inode: 2, size: 3,
            modifiedSeconds: 4, modifiedNanoseconds: 5, mode: 0o755)
        let strong = CodexIsolationFoundation.StrongFileIdentity(
            cheap: cheap, sha256: String(repeating: "a", count: 64), codeSigning: nil)
        let launch = CodexCatalogTransport.productionLaunch(
            paths: paths,
            executablePath: "/synthetic/codex-\(String(repeating: "a", count: 64))",
            executableIdentity: strong,
            hostHome: "/synthetic-home")
        check("production process seam uses only app-server in the sterile cwd",
              launch.executable
                == "/synthetic/codex-\(String(repeating: "a", count: 64))"
                && launch.arguments == ["app-server"]
                && launch.currentDirectory == paths.cwd
                && launch.expectedExecutableIdentity == strong)
        check("production environment is an exact allowlist without auth/token variables",
              Set(launch.environment.keys)
                == ["HOME", "CODEX_HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "TERM"]
                && !launch.environment.keys.contains(where: {
                    $0.contains("TOKEN") || $0.contains("API_KEY")
                }))
    }

    private static func checkRealProcessDeadline(_ check: (String, Bool) -> Void) {
        print("--- real process-group descendant/pipe-holder deadline ---")
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "viddydictate-catalog-process-\(UUID().uuidString)",
                isDirectory: true)
        var leaderPID: pid_t?
        var descendantPID: pid_t?
        defer {
            forceFixtureCleanup(
                pids: [leaderPID, descendantPID].compactMap { $0 })
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try CodexIsolationFoundation.secureDirectory(root)
            let executable = root.appendingPathComponent(
                "catalog-fixture", isDirectory: false)
            let pidFile = root.appendingPathComponent(
                "descendant.pid", isDirectory: false)
            let readyFile = root.appendingPathComponent(
                "descendant.ready", isDirectory: false)
            let leaderPIDFile = root.appendingPathComponent(
                "leader.pid", isDirectory: false)
            let script = """
            #!/bin/sh
            trap '' TERM INT HUP
            printf '%s\\n' "$$" > \(leaderPIDFile.path)
            (
              trap '' TERM INT HUP
              printf 'ready\\n' > \(readyFile.path)
              while :; do /bin/sleep 1; done
            ) &
            printf '%s\\n' "$!" > \(pidFile.path)
            while [ ! -s \(readyFile.path) ]; do /bin/sleep 0.01; done
            printf '%s\\n' '{"id":1,"result":{}}'
            printf '%s\\n' '{"id":2,"result":{"data":[{"id":"preset","model":"executable","hidden":false,"supportedReasoningEfforts":[]}],"nextCursor":null}}'
            exit 0
            """
            try Data(script.utf8).write(to: executable)
            guard chmod(executable.path, 0o500) == 0 else {
                throw CacheWriteFault()
            }
            let identity = try CodexIsolationFoundation.strongFileIdentity(
                at: executable, includeCodeSigning: false)
            let launch = CodexCatalogProcessLaunch(
                executable: executable.path,
                arguments: ["app-server"],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": root.path,
                    "LANG": "C",
                    "LC_ALL": "C",
                ],
                currentDirectory: root,
                expectedExecutableIdentity: identity,
                stdoutLineLimit: 65_536,
                stdoutTotalLimit: 262_144,
                stderrLimit: 65_536,
                spawnedPIDRecorder: { leaderPID = $0 })
            let started = Date()
            var timedOut = false
            do {
                _ = try CodexCatalogTransport.acquire(
                    launch: launch,
                    bounds: CodexCatalogBounds(
                        wallClockSeconds: 0.8,
                        lineReadSeconds: 0.2,
                        processGraceSeconds: 0.4))
            } catch let failure as CodexCatalogFailure {
                timedOut = failure.code == .timeout
            }
            let elapsed = Date().timeIntervalSince(started)
            let leaderPIDText = try String(
                contentsOf: leaderPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let descendantPIDText = try String(
                contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var leaderWasAlreadyReaped = false
            if let reportedLeaderPID = pid_t(leaderPIDText) {
                var status: Int32 = 0
                errno = 0
                let waited = waitpid(reportedLeaderPID, &status, WNOHANG)
                leaderWasAlreadyReaped = waited < 0 && errno == ECHILD
                if waited == 0 {
                    _ = kill(reportedLeaderPID, SIGKILL)
                    _ = waitpid(reportedLeaderPID, &status, 0)
                }
            }
            var descendantGone = false
            if let pid = pid_t(descendantPIDText) {
                descendantPID = pid
                for _ in 0..<40 {
                    if kill(pid, 0) != 0 && errno == ESRCH {
                        descendantGone = true
                        break
                    }
                    usleep(25_000)
                }
                if !descendantGone { _ = kill(pid, SIGKILL) }
            }
            let passed =
                timedOut
                && elapsed < 1.1
                && leaderWasAlreadyReaped
                && descendantGone
            if !passed {
                print(
                    "  [diag] deadline_fixture timeout=\(timedOut) "
                    + "elapsed_ms=\(Int(elapsed * 1_000)) "
                    + "leader_reaped=\(leaderWasAlreadyReaped) "
                    + "descendant_gone=\(descendantGone)")
            }
            check("operation deadline reserves bounded leader/group cleanup evidence",
                  passed)
        } catch {
            check("operation deadline reserves bounded leader/group cleanup evidence",
                  false)
        }
    }

    private static func checkLaunchIdentityAndRetryableReap(
        _ check: (String, Bool) -> Void
    ) {
        print("--- launch-identity cleanup evidence and retryable reap ---")
        checkLaunchIdentityCleanup(check)
        checkRetryableReap(check)
        checkEscalationLatch(check)
        checkEscalationLatchWaitTimeoutCleanup(check)
        checkImmediateCleanupCap(check)
    }

    private static func checkLaunchIdentityCleanup(
        _ check: (String, Bool) -> Void
    ) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "viddydictate-catalog-launch-race-\(UUID().uuidString)",
                isDirectory: true)
        var leaderPID: pid_t?
        var childPID: pid_t?
        defer {
            forceFixtureCleanup(
                pids: [leaderPID, childPID].compactMap { $0 })
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try CodexIsolationFoundation.secureDirectory(root)
            let executable = root.appendingPathComponent("catalog-fixture")
            let replacement = root.appendingPathComponent(
                "catalog-replacement")
            let leaderFile = root.appendingPathComponent("leader.pid")
            let childFile = root.appendingPathComponent("child.pid")
            let script = """
            #!/bin/sh
            trap '' TERM INT
            printf '%s\\n' "$$" > \(leaderFile.path)
            printf 'bounded-launch-stdout\\n'
            printf 'bounded-launch-stderr\\n' >&2
            (
              trap '' TERM INT
              while :; do /bin/sleep 1; done
            ) &
            printf '%s\\n' "$!" > \(childFile.path)
            while :; do /bin/sleep 1; done
            """
            try Data(script.utf8).write(to: executable)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: replacement)
            guard chmod(executable.path, 0o500) == 0,
                  chmod(replacement.path, 0o500) == 0 else {
                throw CacheWriteFault()
            }
            let identity = try CodexIsolationFoundation.strongFileIdentity(
                at: executable, includeCodeSigning: false)
            var replacementInstalled = false
            var cleanupEvidence: CodexCatalogProcessExit?
            let launch = CodexCatalogProcessLaunch(
                executable: executable.path,
                arguments: ["app-server"],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": root.path,
                    "LANG": "C",
                    "LC_ALL": "C",
                ],
                currentDirectory: root,
                expectedExecutableIdentity: identity,
                stdoutLineLimit: 65_536,
                stdoutTotalLimit: 262_144,
                stderrLimit: 65_536,
                spawnedPIDRecorder: { leaderPID = $0 },
                postSpawnBeforeIdentityValidation: {
                    guard waitForFixtureFile(leaderFile),
                          waitForFixtureFile(childFile) else {
                        return
                    }
                    replacementInstalled =
                        rename(replacement.path, executable.path) == 0
                },
                launchCleanupEvidenceRecorder: {
                    cleanupEvidence = $0
                },
                absoluteDeadline:
                    ProcessInfo.processInfo.systemUptime + 1.5,
                immediateCleanupSeconds: 1)
            var rejected = false
            do {
                _ = try CodexCatalogPOSIXSession.start(launch)
            } catch let failure as CodexCatalogFailure {
                rejected = failure.code == .processLaunch
            }
            let reportedLeaderPID = try fixturePID(leaderFile)
            childPID = try fixturePID(childFile)
            let processesGone = waitForFixtureProcessesGone(
                [leaderPID, childPID].compactMap { $0 })
            check(
                "post-launch identity race returns explicit leader/group cleanup evidence",
                leaderPID == reportedLeaderPID
                    && replacementInstalled
                    && rejected
                    && cleanupEvidence?.leaderReaped == true
                    && cleanupEvidence?.residualProcessGroup == false
                    && cleanupEvidence?.stdoutEOF == true
                    && cleanupEvidence?.stderrEOF == true
                    && (cleanupEvidence?.stdoutBytes ?? 0) > 0
                    && (cleanupEvidence?.stderrBytes ?? 0) > 0
                    && cleanupEvidence?.drainsComplete == true
                    && processesGone)
        } catch {
            check(
                "post-launch identity race returns explicit leader/group cleanup evidence",
                false)
        }
    }

    private static func checkRetryableReap(
        _ check: (String, Bool) -> Void
    ) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "viddydictate-catalog-reap-retry-\(UUID().uuidString)",
                isDirectory: true)
        var leaderPID: pid_t?
        var childPID: pid_t?
        defer {
            forceFixtureCleanup(
                pids: [leaderPID, childPID].compactMap { $0 })
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try CodexIsolationFoundation.secureDirectory(root)
            let executable = root.appendingPathComponent("catalog-fixture")
            let leaderFile = root.appendingPathComponent("leader.pid")
            let childFile = root.appendingPathComponent("child.pid")
            let script = """
            #!/bin/sh
            trap '' TERM INT
            printf '%s\\n' "$$" > \(leaderFile.path)
            (
              trap '' TERM INT
              while :; do /bin/sleep 1; done
            ) &
            printf '%s\\n' "$!" > \(childFile.path)
            while :; do /bin/sleep 1; done
            """
            try Data(script.utf8).write(to: executable)
            guard chmod(executable.path, 0o500) == 0 else {
                throw CacheWriteFault()
            }
            let identity = try CodexIsolationFoundation.strongFileIdentity(
                at: executable, includeCodeSigning: false)
            var processOperations: [CodexCatalogProcessOperation] = []
            var numericIdentityReused = false
            var replacementTouched = false
            let overallDeadline =
                ProcessInfo.processInfo.systemUptime + 3
            let launch = CodexCatalogProcessLaunch(
                executable: executable.path,
                arguments: ["app-server"],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": root.path,
                    "LANG": "C",
                    "LC_ALL": "C",
                ],
                currentDirectory: root,
                expectedExecutableIdentity: identity,
                stdoutLineLimit: 65_536,
                stdoutTotalLimit: 262_144,
                stderrLimit: 65_536,
                spawnedPIDRecorder: { leaderPID = $0 },
                drainCompletionDelayForTesting: 1,
                processOperationRecorder: {
                    processOperations.append($0)
                    if numericIdentityReused {
                        replacementTouched = true
                    }
                },
                absoluteDeadline: overallDeadline)
            let session = try CodexCatalogPOSIXSession.start(launch)
            guard waitForFixtureFile(leaderFile),
                  waitForFixtureFile(childFile) else {
                throw CacheWriteFault()
            }
            let reportedLeaderPID = try fixturePID(leaderFile)
            childPID = try fixturePID(childFile)
            let first = session.terminateAndReap(
                absoluteDeadline: min(
                    overallDeadline,
                    ProcessInfo.processInfo.systemUptime + 0.5))
            let processOperationsAfterTreeGone = processOperations.count
            numericIdentityReused = true
            let second = session.terminateAndReap(
                absoluteDeadline: overallDeadline)
            let processesGone = waitForFixtureProcessesGone(
                [leaderPID, childPID].compactMap { $0 })
            let retryPassed =
                leaderPID == reportedLeaderPID
                && !first.drainsComplete
                && first.leaderReaped
                && !first.residualProcessGroup
                && second.leaderReaped
                && !second.residualProcessGroup
                && second.drainsComplete
                && processOperations.count
                    == processOperationsAfterTreeGone
                && !replacementTouched
                && processOperations.filter { $0 == .termSignal }.count == 1
                && processOperations.filter { $0 == .killSignal }.count == 1
                && processesGone
            if !retryPassed {
                print(
                    "  [diag] drain_retry first_reaped=\(first.leaderReaped) "
                        + "first_residual=\(first.residualProcessGroup) "
                        + "first_drains=\(first.drainsComplete) "
                        + "second_reaped=\(second.leaderReaped) "
                        + "second_residual=\(second.residualProcessGroup) "
                        + "second_drains=\(second.drainsComplete) "
                        + "ops_before=\(processOperationsAfterTreeGone) "
                        + "ops_after=\(processOperations.count)")
            }
            check(
                "incomplete first reap remains retryable with positive cleanup grace",
                retryPassed)
        } catch {
            check(
                "incomplete first reap remains retryable with positive cleanup grace",
                false)
        }
    }

    private static func checkEscalationLatch(
        _ check: (String, Bool) -> Void
    ) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "viddydictate-catalog-escalation-latch-\(UUID().uuidString)",
                isDirectory: true)
        var leaderPID: pid_t?
        defer {
            forceFixtureCleanup(pids: [leaderPID].compactMap { $0 })
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try CodexIsolationFoundation.secureDirectory(root)
            let executable = root.appendingPathComponent("catalog-fixture")
            let leaderFile = root.appendingPathComponent("leader.pid")
            let script = """
            #!/bin/sh
            trap '' TERM INT HUP
            printf '%s\n' "$$" > \(leaderFile.path)
            while :; do :; done
            """
            try Data(script.utf8).write(to: executable)
            guard chmod(executable.path, 0o500) == 0 else {
                throw CacheWriteFault()
            }
            let identity = try CodexIsolationFoundation.strongFileIdentity(
                at: executable, includeCodeSigning: false)
            var processOperations: [CodexCatalogProcessOperation] = []
            var useInjectedClock = false
            var injectedClock: TimeInterval = 0
            let launch = CodexCatalogProcessLaunch(
                executable: executable.path,
                arguments: ["app-server"],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": root.path,
                    "LANG": "C",
                    "LC_ALL": "C",
                ],
                currentDirectory: root,
                expectedExecutableIdentity: identity,
                stdoutLineLimit: 65_536,
                stdoutTotalLimit: 262_144,
                stderrLimit: 65_536,
                spawnedPIDRecorder: { leaderPID = $0 },
                processOperationRecorder: {
                    processOperations.append($0)
                },
                processSignal: { _, _ in 0 },
                absoluteDeadline:
                    ProcessInfo.processInfo.systemUptime + 3,
                monotonicNow: {
                    guard useInjectedClock else {
                        return ProcessInfo.processInfo.systemUptime
                    }
                    defer { injectedClock += 0.01 }
                    return injectedClock
                })
            let session = try CodexCatalogPOSIXSession.start(launch)
            guard waitForFixtureFile(leaderFile) else {
                throw CacheWriteFault()
            }
            let reportedLeaderPID = try fixturePID(leaderFile)
            useInjectedClock = true
            let first = session.terminateAndReap(
                absoluteDeadline: 0.2)
            let operationsAfterFirst = processOperations
            let second = session.terminateAndReap(
                absoluteDeadline: 1)
            let retryPerformedNoProcessOperation =
                processOperations == operationsAfterFirst
            let passed =
                leaderPID == reportedLeaderPID
                && !first.leaderReaped
                && first.residualProcessGroup
                && !second.leaderReaped
                && second.residualProcessGroup
                && operationsAfterFirst.filter {
                    $0 == .termSignal
                }.count == 1
                && operationsAfterFirst.filter {
                    $0 == .killSignal
                }.count == 1
                && retryPerformedNoProcessOperation
                && processOperations.filter {
                    $0 == .termSignal
                }.count == 1
                && processOperations.filter {
                    $0 == .killSignal
                }.count == 1
            if !passed {
                print(
                    "  [diag] escalation_latch "
                        + "first_reaped=\(first.leaderReaped) "
                        + "second_reaped=\(second.leaderReaped) "
                        + "first_ops=\(operationsAfterFirst.count) "
                        + "all_ops=\(processOperations.count) "
                        + "first_terms=\(operationsAfterFirst.filter { $0 == .termSignal }.count) "
                        + "first_kills=\(operationsAfterFirst.filter { $0 == .killSignal }.count) "
                        + "terms=\(processOperations.filter { $0 == .termSignal }.count) "
                        + "kills=\(processOperations.filter { $0 == .killSignal }.count)")
            }
            check(
                "short-then-long retry latches exactly one TERM and one KILL",
                passed)
        } catch {
            check(
                "short-then-long retry latches exactly one TERM and one KILL",
                false)
        }
    }

    private static func checkEscalationLatchWaitTimeoutCleanup(
        _ check: (String, Bool) -> Void
    ) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "viddydictate-catalog-escalation-timeout-\(UUID().uuidString)",
                isDirectory: true)
        let leaderFile = root.appendingPathComponent("leader.pid")
        var leaderPID: pid_t?
        var capturedAtSpawn = false
        var waitTimedOut = false
        var cleanupReapedLeader = false

        func exerciseTimeoutPath() {
            defer {
                if leaderPID == nil,
                   waitForFixtureFile(leaderFile, timeout: 1) {
                    leaderPID = try? fixturePID(leaderFile)
                }
                if let leaderPID {
                    forceFixtureCleanup(pids: [leaderPID])
                    cleanupReapedLeader =
                        fixtureProcessIsGone(leaderPID)
                }
                try? FileManager.default.removeItem(at: root)
            }

            do {
                try CodexIsolationFoundation.secureDirectory(root)
                let executable =
                    root.appendingPathComponent("catalog-fixture")
                let script = """
                #!/bin/sh
                trap '' TERM INT HUP
                /bin/sleep 0.2
                printf '%s\n' "$$" > \(leaderFile.path)
                while :; do :; done
                """
                try Data(script.utf8).write(to: executable)
                guard chmod(executable.path, 0o500) == 0 else {
                    throw CacheWriteFault()
                }
                let identity =
                    try CodexIsolationFoundation.strongFileIdentity(
                        at: executable, includeCodeSigning: false)
                let launch = CodexCatalogProcessLaunch(
                    executable: executable.path,
                    arguments: ["app-server"],
                    environment: [
                        "PATH": "/usr/bin:/bin",
                        "HOME": root.path,
                        "LANG": "C",
                        "LC_ALL": "C",
                    ],
                    currentDirectory: root,
                    expectedExecutableIdentity: identity,
                    stdoutLineLimit: 65_536,
                    stdoutTotalLimit: 262_144,
                    stderrLimit: 65_536,
                    spawnedPIDRecorder: { leaderPID = $0 },
                    absoluteDeadline:
                        ProcessInfo.processInfo.systemUptime + 1)
                _ = try CodexCatalogPOSIXSession.start(launch)
                capturedAtSpawn = leaderPID != nil
                guard waitForFixtureFile(
                    leaderFile, timeout: 0.02
                ) else {
                    waitTimedOut = true
                    return
                }
            } catch {
                return
            }
        }

        exerciseTimeoutPath()
        check(
            "fixture PID-file wait timeout reaps the spawn-captured leader",
            capturedAtSpawn
                && waitTimedOut
                && cleanupReapedLeader)
    }

    private static func checkImmediateCleanupCap(
        _ check: (String, Bool) -> Void
    ) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "viddydictate-catalog-immediate-cap-\(UUID().uuidString)",
                isDirectory: true)
        var leaderPID: pid_t?
        defer {
            forceFixtureCleanup(pids: [leaderPID].compactMap { $0 })
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try CodexIsolationFoundation.secureDirectory(root)
            let executable = root.appendingPathComponent("catalog-fixture")
            let replacement =
                root.appendingPathComponent("catalog-replacement")
            let leaderFile = root.appendingPathComponent("leader.pid")
            let script = """
            #!/bin/sh
            trap '' TERM INT HUP
            printf '%s\n' "$$" > \(leaderFile.path)
            while :; do :; done
            """
            try Data(script.utf8).write(to: executable)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: replacement)
            guard chmod(executable.path, 0o500) == 0,
                  chmod(replacement.path, 0o500) == 0 else {
                throw CacheWriteFault()
            }
            let identity = try CodexIsolationFoundation.strongFileIdentity(
                at: executable, includeCodeSigning: false)
            var postSpawn = false
            var cleanupClock: TimeInterval = 3
            var cleanupDeadline: TimeInterval?
            var cleanupEvidence: CodexCatalogProcessExit?
            var processOperations: [CodexCatalogProcessOperation] = []
            var replacementInstalled = false
            let started = ProcessInfo.processInfo.systemUptime
            let launch = CodexCatalogProcessLaunch(
                executable: executable.path,
                arguments: ["app-server"],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": root.path,
                    "LANG": "C",
                    "LC_ALL": "C",
                ],
                currentDirectory: root,
                expectedExecutableIdentity: identity,
                stdoutLineLimit: 65_536,
                stdoutTotalLimit: 262_144,
                stderrLimit: 65_536,
                spawnedPIDRecorder: { leaderPID = $0 },
                postSpawnBeforeIdentityValidation: {
                    guard waitForFixtureFile(leaderFile) else {
                        return
                    }
                    replacementInstalled =
                        rename(replacement.path, executable.path) == 0
                    postSpawn = true
                },
                launchCleanupEvidenceRecorder: {
                    cleanupEvidence = $0
                },
                launchCleanupDeadlineRecorder: {
                    cleanupDeadline = $0
                },
                processOperationRecorder: {
                    processOperations.append($0)
                },
                absoluteDeadline: 10,
                operationDeadline: 5,
                monotonicNow: {
                    guard postSpawn else { return 0 }
                    defer { cleanupClock += 3 }
                    return cleanupClock
                },
                immediateCleanupSeconds: 5)
            var rejected = false
            do {
                _ = try CodexCatalogPOSIXSession.start(launch)
            } catch let failure as CodexCatalogFailure {
                rejected = failure.code == .processLaunch
            }
            let reportedLeaderPID = try fixturePID(leaderFile)
            let elapsed =
                ProcessInfo.processInfo.systemUptime - started
            let passed =
                leaderPID == reportedLeaderPID
                && replacementInstalled
                && rejected
                && cleanupDeadline == 5
                && cleanupDeadline.map { $0 <= 10 } == true
                && cleanupEvidence?.leaderReaped == false
                && cleanupEvidence?.residualProcessGroup == true
                && cleanupEvidence?.drainsComplete == false
                && processOperations.filter {
                    $0 == .termSignal || $0 == .killSignal
                }.isEmpty
                && elapsed < 0.5
            if !passed {
                print(
                    "  [diag] immediate_cap "
                        + "swapped=\(replacementInstalled) "
                        + "rejected=\(rejected) "
                        + "deadline=\(cleanupDeadline ?? -1) "
                        + "leader_reaped=\(cleanupEvidence?.leaderReaped == true) "
                        + "residual=\(cleanupEvidence?.residualProcessGroup == true) "
                        + "drains=\(cleanupEvidence?.drainsComplete == true) "
                        + "ops=\(processOperations.count) "
                        + "elapsed_ms=\(Int(elapsed * 1_000))")
            }
            check(
                "identity rejection clamps configured cleanup above two seconds and fails closed",
                passed)
        } catch {
            check(
                "identity rejection clamps configured cleanup above two seconds and fails closed",
                false)
        }
    }

    private static func checkLaunchTimeSharesOverallDeadline(
        _ check: (String, Bool) -> Void
    ) {
        print("--- one absolute deadline includes process creation ---")
        let session = FakeSession(validCatalogReads())
        var clock: TimeInterval = 0
        var launchDeadline: TimeInterval?
        var unexpectedlySucceeded = false
        var failureCode: CodexCatalogFailure.Code?
        do {
            _ = try CodexCatalogTransport.acquire(
                launch: syntheticLaunch(),
                processFactory: { launch in
                    launchDeadline = launch.absoluteDeadline
                    clock = 0.18
                    return session
                },
                bounds: CodexCatalogBounds(
                    wallClockSeconds: 0.2,
                    lineReadSeconds: 0.05,
                    processGraceSeconds: 0.05),
                monotonicNow: { clock })
            unexpectedlySucceeded = true
        } catch let failure as CodexCatalogFailure {
            failureCode = failure.code
        } catch {}
        let passed =
            !unexpectedlySucceeded
            && failureCode == .timeout
            && launchDeadline == 0.2
            && clock <= 0.2
            && session.reads.count == validCatalogReads().count
            && session.writes.isEmpty
        if !passed {
            print(
                "  [diag] launch_deadline succeeded=\(unexpectedlySucceeded) "
                    + "failure=\(failureCode?.rawValue ?? "none") "
                    + "deadline=\(launchDeadline ?? -1) "
                    + "clock=\(clock) reads=\(session.reads.count)")
        }
        check(
            "launch time consumes the original catalog wall-clock bound",
            passed)

        let reserveSession = FakeSession(validCatalogReads())
        var reserveClockReads = 0
        var reserveFactoryInvoked = false
        var configuredLaunchReserve: TimeInterval?
        var reserveFailureCode: CodexCatalogFailure.Code?
        let reserveLaunch = syntheticLaunch().bounded(
            absoluteDeadline: 0.2,
            operationDeadline: 0.15,
            monotonicNow: { 0.151 },
            immediateCleanupSeconds: 0.05)
        do {
            _ = try CodexCatalogTransport.acquire(
                launch: syntheticLaunch(),
                processFactory: { launch in
                    reserveFactoryInvoked = true
                    configuredLaunchReserve =
                        launch.immediateCleanupSeconds
                    return reserveSession
                },
                bounds: CodexCatalogBounds(
                    wallClockSeconds: 0.2,
                    lineReadSeconds: 0.05,
                    processGraceSeconds: 0.05),
                monotonicNow: {
                    reserveClockReads += 1
                    return reserveClockReads == 1 ? 0 : 0.151
                })
        } catch let failure as CodexCatalogFailure {
            reserveFailureCode = failure.code
        } catch {}
        check(
            "pre-spawn operation deadline preserves the full configured reserve",
            reserveFailureCode == .timeout
                && !reserveFactoryInvoked
                && configuredLaunchReserve == nil
                && reserveClockReads == 2
                && abs(
                    reserveLaunch.absoluteDeadline
                        - reserveLaunch.operationDeadline
                        - 0.05) < 0.000_001
                && reserveLaunch.immediateCleanupSeconds == 0.05
                && reserveSession.writes.isEmpty
                && reserveSession.readCount == 0)
    }

    private static func syntheticLaunch() -> CodexCatalogProcessLaunch {
        let cheap = CodexIsolationFoundation.CheapFileIdentity(
            device: 1, inode: 2, size: 3,
            modifiedSeconds: 4, modifiedNanoseconds: 5, mode: 0o755)
        let strong = CodexIsolationFoundation.StrongFileIdentity(
            cheap: cheap,
            sha256: String(repeating: "a", count: 64),
            codeSigning: nil)
        return CodexCatalogProcessLaunch(
            executable: "/synthetic/catalog",
            arguments: ["app-server"],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: URL(fileURLWithPath: "/private/tmp"),
            expectedExecutableIdentity: strong,
            stdoutLineLimit: 65_536,
            stdoutTotalLimit: 262_144,
            stderrLimit: 65_536)
    }

    private static func waitForFixtureFile(
        _ url: URL,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path),
              Date() < deadline {
            usleep(5_000)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func fixturePID(_ url: URL) throws -> pid_t {
        guard let pid = pid_t(
            try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            throw CacheWriteFault()
        }
        return pid
    }

    private static func waitForFixtureProcessesGone(
        _ pids: [pid_t]
    ) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if pids.allSatisfy(fixtureProcessIsGone) { return true }
            usleep(5_000)
        }
        return pids.allSatisfy(fixtureProcessIsGone)
    }

    private static func fixtureProcessIsGone(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    private static func forceFixtureCleanup(pids: [pid_t]) {
        for pid in pids where pid > 0 {
            _ = kill(-pid, SIGKILL)
            _ = kill(pid, SIGKILL)
        }
        for pid in pids where pid > 0 {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }

    private static func expectFailure(
        _ label: String,
        _ expected: CodexCatalogFailure.Code,
        _ check: (String, Bool) -> Void,
        _ reads: [CodexCatalogReadResult],
        bounds: CodexCatalogBounds = CodexCatalogBounds(),
        exit: CodexCatalogProcessExit = .clean
    ) {
        let session = FakeSession(reads, exit: exit)
        do {
            _ = try CodexCatalogTransport.acquire(
                session: session, bounds: bounds, monotonicNow: { 1 })
            check(label, false)
        } catch let failure as CodexCatalogFailure {
            check(label, failure.code == expected && session.terminated)
        } catch {
            check(label, false)
        }
    }

    private static func validCatalogReads() -> [CodexCatalogReadResult] {
        [
            line(#"{"id":1,"result":{}}"#),
            line(#"{"id":2,"result":{"data":[{"id":"preset","model":"executable","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"future-open","description":"copy"}],"defaultReasoningEffort":"future-open","inputModalities":["text"]}],"nextCursor":null}}"#),
            .eof,
        ]
    }

    private static func line(_ string: String) -> CodexCatalogReadResult {
        .line(Data(string.utf8))
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
