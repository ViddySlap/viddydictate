import Foundation

/// Live gate for the Setup tab's resident-models readout (item L4, LOCKED DECISION 2).
///
/// The offscreen render gate drives that readout through a stub, which proves the wiring, the copy, and
/// the layout but cannot prove the one thing the readout claims: that it is reporting THIS machine. So
/// this gate takes the reading through the exact production entry point the section uses,
/// `ModelResidency.residentModels()`, and cross-checks it against a SEPARATE, raw `lms ps --json` taken
/// here — a second observation of the CLI, deliberately not a second production parser.
///
/// It then prints the block exactly as the section renders it, so the numbers on screen can be compared
/// against the numbers the CLI reports at the same moment rather than against a description of them.
///
/// **Read-only by default.** `--unload-all` is opt-in and is the only path here that changes the machine;
/// nothing in `verify.sh` passes it. It exists because the Unload all button's promise — that a lowered
/// budget can be made true immediately — is not provable from a fixture, and a button whose only proof is
/// a mocked seam is exactly the kind of thing this project has three times shipped as green and broken.
enum LocalModelsReadoutLiveGate {
    private static let tag = "[local-models-readout-live]"

    static func run(arguments: [String]) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CODEX_SANDBOX"]?.isEmpty == false
            || environment["CODEX_PERMISSION_PROFILE"]?.isEmpty == false {
            print("\(tag) [skip] SKIPPED: managed sandbox denies live LM Studio access")
            return true
        }
        guard ModelResidency.isInstalled else {
            print("\(tag) [skip] SKIPPED: lms CLI is not installed")
            return true
        }
        guard ModelResidency.serverResponds() else {
            print("\(tag) [skip] SKIPPED: LM Studio is not answering, so there is no resident set to read")
            return true
        }

        // The production entry point. Nil here is a real regression: the section would render
        // "could not ask LM Studio" on a machine whose LM Studio is plainly answering.
        guard let models = ModelResidency.residentModels() else {
            print("\(tag) FAIL: an answering LM Studio produced no parseable resident set, so the Setup "
                  + "tab would report that it could not ask")
            return false
        }

        var failures: [String] = []

        for model in models {
            if model.identifier.isEmpty { failures.append("a resident row carries a blank identifier") }
            if model.sizeBytes == 0 { failures.append("\(model.identifier) reports a zero footprint") }
            if let ttl = model.ttlSeconds, ttl <= 0 {
                failures.append("\(model.identifier) reports a non-positive TTL of \(ttl)s")
            }
        }

        // The independent observation. Compared only on the models present in BOTH readings: LM Studio is
        // a live server and a model can legitimately load or unload between two calls a moment apart, and
        // a gate that failed on that would be a coin toss rather than a check.
        switch rawResidentRows() {
        case .none:
            failures.append("a raw lms ps --json could not be read back for cross-checking")
        case .some(let raw):
            let rawByIdentifier = Dictionary(raw.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
            var compared = 0
            for model in models {
                guard let counterpart = rawByIdentifier[model.identifier] else { continue }
                compared += 1
                if counterpart.sizeBytes != model.sizeBytes {
                    failures.append("\(model.identifier): the readout says \(model.sizeBytes) bytes, "
                                    + "lms ps says \(counterpart.sizeBytes)")
                }
                if counterpart.ttlSeconds != model.ttlSeconds {
                    failures.append("\(model.identifier): the readout says TTL "
                                    + "\(describe(model.ttlSeconds)), lms ps says "
                                    + "\(describe(counterpart.ttlSeconds))")
                }
                if counterpart.status != model.status {
                    failures.append("\(model.identifier): the readout says '\(model.status)', "
                                    + "lms ps says '\(counterpart.status)'")
                }
            }
            let both = Set(models.map(\.identifier)).intersection(Set(raw.map(\.identifier)))
            if models.isEmpty && raw.isEmpty {
                print("\(tag) both readings agree the machine is empty")
            } else if both.isEmpty && !models.isEmpty {
                print("\(tag) [note] the resident set changed between the two readings "
                      + "(\(models.count) then \(raw.count)); nothing to cross-check")
            } else {
                print("\(tag) cross-checked \(compared) model(s) against a raw lms ps --json")
            }
        }

        printReadout(models: models)

        if arguments.contains("--unload-all") {
            failures.append(contentsOf: exerciseUnloadAll(startingFrom: models))
        }

        guard failures.isEmpty else {
            for failure in failures { print("\(tag) FAIL: \(failure)") }
            return false
        }
        print("\(tag) PASS: the readout matches what lms ps reports for \(models.count) resident model(s)")
        return true
    }

    /// The opt-in half: press the button's own code path and confirm the machine actually changed.
    private static func exerciseUnloadAll(startingFrom before: [ModelResidency.ResidentModel]) -> [String] {
        guard !before.isEmpty else {
            print("\(tag) [skip] SKIPPED --unload-all: nothing was resident to unload")
            return []
        }
        print("\(tag) --unload-all: unloading \(before.count) model(s) through ModelResidency.unloadAll()")
        ModelResidency.unloadAll()

        guard let after = ModelResidency.residentModels() else {
            return ["the resident set could not be read back after unloading"]
        }
        printReadout(models: after)

        // Deliberately "none of the models that were there are still there" rather than "the list is
        // empty": another process can load a model in the same second, and that is not this button
        // failing. A model that survives its own unload is.
        let survivors = Set(after.map(\.identifier)).intersection(Set(before.map(\.identifier)))
        guard survivors.isEmpty else {
            return ["unload all left \(survivors.sorted().joined(separator: ", ")) resident"]
        }
        print("\(tag) --unload-all: every model that was resident is gone, and lms ps agrees")
        return []
    }

    /// The block exactly as `LocalModelsSectionView` draws it, so a human can compare it with `lms ps`.
    private static func printReadout(models: [ModelResidency.ResidentModel]) {
        let position = Settings.modelMemoryBudgetSliderPosition
        let facts = LocalModelSetup.MemoryFacts.live
        print("\(tag) --- the Setup tab would show ---")
        print("\(tag) \(LocalModelSetup.budgetLine(position: position, facts: facts))")
        for line in LocalModelSetup.residencyList(.models(models), now: Date())
            .split(separator: "\n", omittingEmptySubsequences: false) {
            print("\(tag)   \(line)")
        }
        let summary = LocalModelSetup.residencySummary(position: position, facts: facts,
                                                       wiredBytes: SystemMemory.wiredBytes)
        print("\(tag) \(summary ?? "(no in-use summary: the kernel ceiling is unreadable)")")
        print("\(tag) \(LocalModelSetup.residencyNote)")
        print("\(tag) -------------------------------")
    }

    private static func describe(_ ttl: Int?) -> String { ttl.map { "\($0)s" } ?? "none" }

    /// This gate's OWN observation of `lms ps --json`: a separate process, decoded here, so a bug in the
    /// production parser cannot hide behind itself. Only the fields the readout claims are lifted out.
    private static func rawResidentRows() -> [(identifier: String, sizeBytes: UInt64,
                                               ttlSeconds: Int?, status: String)]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.lmstudio/bin/lms")
        process.arguments = ["ps", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }

        var parsed: [(identifier: String, sizeBytes: UInt64, ttlSeconds: Int?, status: String)] = []
        for row in rows {
            guard let identifier = row["identifier"] as? String,
                  let size = (row["sizeBytes"] as? NSNumber)?.uint64Value,
                  let status = row["status"] as? String else { return nil }
            let ttl = (row["ttlMs"] as? NSNumber).map { Int(($0.doubleValue / 1000).rounded()) }
            parsed.append((identifier: identifier, sizeBytes: size,
                           ttlSeconds: ttl.flatMap { $0 > 0 ? $0 : nil }, status: status))
        }
        return parsed
    }
}
