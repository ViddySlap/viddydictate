import Foundation

/// Characterizes the Local models section's pure layer: the slider's two renderings, the LM Studio JIT
/// reader, and what each reading is reported as.
///
/// It touches no view and no real settings file. The one thing it does open is a fixture written into this
/// run's own `TMPDIR`, because `readJITSettings` is the only part of the section that parses somebody else's
/// format and the machine running this gate has a scratch home with no LM Studio in it.
///
/// Two assertions here are the reason the file exists rather than being folded into the render gate.
///
/// **No percent sign, anywhere on the level.** The slider's face is 0...100 and maps onto 25...90% of the
/// user-wire ceiling, so position 60 is really 64% of it. A `%` on that number would state something false,
/// and this asserts it over the whole range rather than at one position someone happened to screenshot.
///
/// **The level and the gigabytes come from ONE number.** A fractional slider value must not be able to
/// render "54" above the gigabytes for 53.6. That is checked by driving fractional positions rather than by
/// reading the code.
enum LocalModelSetupSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate local model setup - selftest ===")
        let reporter = SelfTestReporter()

        checkSliderRendering(reporter)
        checkBudgetLine(reporter)
        checkTimerCopy(reporter)
        checkResidencyReadout(reporter)
        checkJITReader(reporter)
        checkJITStatus(reporter)
        checkJITCopy(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "local model setup"))
        return reporter.passed
    }

    /// Ben's machine's numbers, frozen as a fixture so this gate asserts the RENDERING on a known ceiling
    /// rather than on whatever the host reports. The live values are asserted by `SystemMemorySelfTest` and
    /// rendered for real by `--setup-render`.
    private static let fixtureFacts = LocalModelSetup.MemoryFacts(
        userWireLimitBytes: 56_349_970_923, noUserWireBytes: 12_369_505_813)

    private static let noFacts = LocalModelSetup.MemoryFacts(
        userWireLimitBytes: nil, noUserWireBytes: nil)

    // MARK: - the slider's two renderings

    private static func checkSliderRendering(_ check: SelfTestReporter) {
        let levels = stride(from: 0.0, through: 100.0, by: 1.0).map(LocalModelSetup.budgetLevelText)
        check("the slider's own number never carries a percent sign",
              levels.allSatisfy { !$0.contains("%") })
        check("the slider's own number never carries a unit either",
              levels.allSatisfy { Int($0) != nil })
        check("the slider's own number spans the whole face",
              levels.first == "0" && levels.last == "100" && levels.count == 101)

        // The level and the gigabytes are two renderings of one integer. A fractional handle must round
        // both, not one.
        var agreeing = true
        for raw in [53.4, 53.5, 53.6, 54.0, 54.4, 0.4, 99.6] {
            let level = LocalModelSetup.budgetLevelText(raw)
            let line = LocalModelSetup.budgetLine(position: raw, facts: fixtureFacts)
            let rounded = LocalModelSetup.normalized(raw)
            if level != String(Int(rounded))
                || line != LocalModelSetup.budgetLine(position: rounded, facts: fixtureFacts) {
                agreeing = false
            }
        }
        check("a fractional handle rounds the level and the gigabytes to the same integer", agreeing)

        check("a position outside the face is clamped rather than rendered",
              LocalModelSetup.normalized(-40) == 0 && LocalModelSetup.normalized(400) == 100)
        check("an infinite position is clamped to the face like any other out-of-range one",
              LocalModelSetup.normalized(.infinity) == 100 && LocalModelSetup.normalized(-.infinity) == 0)
        check("a position that is not a number takes the floor rather than the ceiling",
              LocalModelSetup.normalized(.nan) == 0)
    }

    // MARK: - the gigabyte line

    private static func checkBudgetLine(_ check: SelfTestReporter) {
        // The three positions LOCKED DECISION 6 names, against the ceiling it names them for.
        let floor = LocalModelSetup.budgetLine(position: 0, facts: fixtureFacts)
        let shipped = LocalModelSetup.budgetLine(position: 54, facts: fixtureFacts)
        let ceiling = LocalModelSetup.budgetLine(position: 100, facts: fixtureFacts)
        check("position 0 states the 25% floor", floor == "14.1 GB of 56.3 GB available to local models",
              floor)
        // 0.601 x 56,349,970,923 = 33,866,332,524 B. The baton's orientation text rounds that DOWN to
        // "33.8 GB"; `SystemMemory.formatGB` rounds, as %.1f does, so the shipped rendering is 33.9 GB.
        // Asserted here so the one-digit disagreement is a recorded fact rather than a surprise on screen.
        check("the shipped default states 33.9 GB, the rounded value of the locked 0.601 fraction",
              shipped == "33.9 GB of 56.3 GB available to local models", shipped)
        check("position 100 states the 90% ceiling and cannot express the crash",
              ceiling == "50.7 GB of 56.3 GB available to local models", ceiling)

        check("the reserved line names what macOS keeps",
              LocalModelSetup.reservedLine(facts: fixtureFacts)
                == "macOS reserves 12.4 GB that models cannot use.")

        // The line is strictly increasing across the face, which is the property that makes it a readout of
        // the handle rather than a caption beside it.
        var previous = UInt64(0)
        var rising = true
        for position in stride(from: 0.0, through: 100.0, by: 1.0) {
            guard let bytes = SystemMemory.budgetBytes(forSliderPosition: position) else { continue }
            if position > 0, bytes <= previous { rising = false }
            previous = bytes
        }
        check("every step of the slider buys strictly more memory than the one below it", rising)

        // An unreadable kernel ceiling has to stay unreadable. Substituting hw.memsize would hand models the
        // 12 GB macOS reserves and can never lend out.
        let unavailable = LocalModelSetup.budgetLine(position: 54, facts: noFacts)
        check("an unreadable ceiling states no budget at all",
              !unavailable.contains("GB of") && unavailable.contains("not loaded"), unavailable)
        check("an unreadable ceiling omits the reserved line rather than guessing it",
              LocalModelSetup.reservedLine(facts: noFacts) == nil)
    }

    // MARK: - the idle timer

    private static func checkTimerCopy(_ check: SelfTestReporter) {
        // Read through the public accessor rather than the private defaults table: on the scratch home this
        // gate runs under, nothing has been written, so this IS the shipped default.
        check("the shipped default is one of the offered choices",
              Settings.modelIdleUnloadSeconds == 600
                && LocalModelSetup.timerChoicesMinutes.contains(Settings.modelIdleUnloadSeconds / 60))
        check("the choices are offered in minutes, ascending, without duplicates",
              LocalModelSetup.timerChoicesMinutes == LocalModelSetup.timerChoicesMinutes.sorted()
                && Set(LocalModelSetup.timerChoicesMinutes).count
                    == LocalModelSetup.timerChoicesMinutes.count)
        check("a whole number of minutes is said in minutes",
              LocalModelSetup.duration(600) == "10 min" && LocalModelSetup.duration(3600) == "60 min")
        check("a value that is not whole minutes is said in seconds rather than rounded silently",
              LocalModelSetup.duration(90) == "90 sec" && LocalModelSetup.duration(45) == "45 sec")
    }

    // MARK: - the live residency readout (LOCKED DECISION 2)

    /// A fixed clock. Every TTL below is measured against it rather than against `Date()`, so the gate
    /// asserts the arithmetic instead of racing the wall.
    private static let clock = Date(timeIntervalSince1970: 1_787_849_000)

    private static func model(_ identifier: String, gb: Double, status: String = "idle",
                              ttl: Int? = 600, usedSecondsAgo: Double = 0)
        -> ModelResidency.ResidentModel {
        .init(identifier: identifier,
              sizeBytes: UInt64(gb * 1_000_000_000),
              lastUsedTime: UInt64((clock.timeIntervalSince1970 - usedSecondsAgo) * 1000),
              status: status,
              ttlSeconds: ttl)
    }

    private static func checkResidencyReadout(_ check: SelfTestReporter) {
        // The sentence the whole item exists for, pinned verbatim rather than by keyword. Ben lost a hand
        // test on 2026-08-27 to its absence: he dragged the budget to 0 with a 17.19 GB model resident,
        // the next dictation ran with no refusal, and nothing ever said why.
        check("the section states that lowering the budget does not evict what is already loaded",
              LocalModelSetup.residencyNote
                == "Lowering the budget applies to the next model load. Models already in memory keep "
                    + "running.",
              LocalModelSetup.residencyNote)

        // --- what a row says ---
        let coder = model("qwen3-coder-30b-a3b-instruct-mlx", gb: 17.19, usedSecondsAgo: 120)
        check("a row names the model, its size, its state and when it goes",
              LocalModelSetup.residencyRow(coder, nameWidth: 0, now: clock)
                == "qwen3-coder-30b-a3b-instruct-mlx   17.2 GB  idle  unloads in 8 min",
              LocalModelSetup.residencyRow(coder, nameWidth: 0, now: clock))
        check("a busy model reads as busy rather than idle",
              LocalModelSetup.residencyRow(model("m", gb: 1, status: "loading"), nameWidth: 0, now: clock)
                .contains("busy"))

        // --- the TTL, which is idle-based and can be absent ---
        check("a model LM Studio holds with no TTL says so rather than rendering blank",
              LocalModelSetup.residencyTTL(model("m", gb: 1, ttl: nil), now: clock) == "no timeout")
        check("the countdown runs from the model's LAST USE, not from its load",
              LocalModelSetup.residencyTTL(model("m", gb: 1, ttl: 600, usedSecondsAgo: 540), now: clock)
                == "unloads in 1 min")
        check("a TTL that has already run out reads as due rather than as a negative countdown",
              LocalModelSetup.residencyTTL(model("m", gb: 1, ttl: 600, usedSecondsAgo: 900), now: clock)
                == "due to unload")
        check("less than a minute left is said in words rather than rounded to zero",
              LocalModelSetup.residencyTTL(model("m", gb: 1, ttl: 600, usedSecondsAgo: 570), now: clock)
                == "unloads in under a minute")
        // A machine whose clock moved (timezone change, NTP step) must not be able to promise more time
        // than LM Studio ever granted.
        check("a last-use time in the future cannot promise more than the TTL itself",
              LocalModelSetup.residencyTTL(model("m", gb: 1, ttl: 600, usedSecondsAgo: -9_000),
                                           now: clock) == "unloads in 10 min")

        // --- the list ---
        let set = LocalModelSetup.Residency.models([
            model("small-model", gb: 0.63, ttl: nil),
            model("huge-model", gb: 17.19, usedSecondsAgo: 120),
        ])
        let rendered = LocalModelSetup.residencyList(set, now: clock)
        check("the list puts the biggest model first, because that is the one holding the memory",
              rendered.hasPrefix("huge-model"), rendered.replacingOccurrences(of: "\n", with: " / "))
        // Two names of different lengths, two sizes of different lengths: the "GB" has to land on the same
        // column in both rows, or the padding is decorative rather than structural.
        let rows = rendered.split(separator: "\n")
        let gbColumns = Set(rows.map { row -> Int in
            guard let found = row.range(of: "GB") else { return -1 }
            return row.distance(from: row.startIndex, to: found.lowerBound)
        })
        check("the list pads the names so the size column lines up across rows",
              rows.count == 2 && gbColumns.count == 1 && !gbColumns.contains(-1),
              rendered.replacingOccurrences(of: "\n", with: " / "))

        // Three different facts, three different sentences. An app that could not ask LM Studio has not
        // learned that nothing is loaded.
        check("a machine with nothing loaded says so",
              LocalModelSetup.residencyList(.models([]), now: clock)
                .hasPrefix("Nothing is loaded right now."))
        check("a reading that has not landed yet reads as pending, not as an empty machine",
              LocalModelSetup.residencyList(.pending, now: clock) == "Reading LM Studio...")
        check("an unreadable LM Studio says it could not ask, not that nothing is loaded",
              LocalModelSetup.residencyList(.unavailable, now: clock).contains("could not ask LM Studio")
                && !LocalModelSetup.residencyList(.unavailable, now: clock).contains("Nothing is loaded"))
        check("only a non-empty resident set is rendered as columns",
              LocalModelSetup.residencyIsTabular(set)
                && !LocalModelSetup.residencyIsTabular(.models([]))
                && !LocalModelSetup.residencyIsTabular(.pending)
                && !LocalModelSetup.residencyIsTabular(.unavailable))

        // --- Unload all ---
        check("Unload all is offered only when there is something resident to unload",
              LocalModelSetup.canUnloadAll(set)
                && !LocalModelSetup.canUnloadAll(.models([]))
                && !LocalModelSetup.canUnloadAll(.pending)
                && !LocalModelSetup.canUnloadAll(.unavailable))
        // It has to reach `lms unload --all` rather than a loop over this app's own models: the budget
        // counts every wired byte on the Mac, so freeing only ViddyDictate's models would leave the very
        // number the button exists to fix unchanged.
        check("Unload all unloads everything LM Studio holds, not just this app's own models",
              ModelResidency.unloadAllArguments == ["unload", "--all"],
              ModelResidency.unloadAllArguments.joined(separator: " "))

        // --- the summary ---
        // The numerator is whole-machine WIRED memory, which is exactly what `ModelManager` compares
        // against the budget. Anything else and this line could read comfortable while a load was refused.
        check("the in-use summary reads in the established GB-of-GB style",
              LocalModelSetup.residencySummary(position: 54, facts: fixtureFacts,
                                               wiredBytes: 21_400_000_000)
                == "21.4 GB of 33.9 GB budget in use",
              LocalModelSetup.residencySummary(position: 54, facts: fixtureFacts,
                                               wiredBytes: 21_400_000_000) ?? "nil")
        check("the summary's denominator is the slider position, not a constant",
              LocalModelSetup.residencySummary(position: 0, facts: fixtureFacts, wiredBytes: 21_400_000_000)
                != LocalModelSetup.residencySummary(position: 100, facts: fixtureFacts,
                                                    wiredBytes: 21_400_000_000))
        check("the summary's denominator is the SAME budget the capacity policy compares against",
              LocalModelSetup.residencySummary(position: 54, facts: fixtureFacts, wiredBytes: 1)
                == "0.0 GB of "
                    + SystemMemory.formatGB(SystemMemory.budgetBytes(forSliderPosition: 54) ?? 0)
                    + " budget in use")
        check("a fractional handle rounds the summary the way it rounds the gigabyte line",
              LocalModelSetup.residencySummary(position: 53.6, facts: fixtureFacts, wiredBytes: 1)
                == LocalModelSetup.residencySummary(position: 54, facts: fixtureFacts, wiredBytes: 1))
        check("the summary is omitted rather than stated against a ceiling nobody could read",
              LocalModelSetup.residencySummary(position: 54, facts: noFacts,
                                               wiredBytes: 21_400_000_000) == nil)
        check("the summary is omitted rather than guessed when the wired total is unreadable",
              LocalModelSetup.residencySummary(position: 54, facts: fixtureFacts, wiredBytes: nil) == nil)

        // Over budget is a READING, not a refusal: a resident model allocates nothing new, which is why
        // the policy correctly let Ben's dictation run at 07:40 on 2026-08-27. The section says it; it
        // does not act on it.
        check("a budget set below what is already in use reads as over",
              LocalModelSetup.residencyOverBudget(position: 0, facts: fixtureFacts,
                                                  wiredBytes: 21_400_000_000))
        check("a budget with room to spare does not read as over",
              !LocalModelSetup.residencyOverBudget(position: 100, facts: fixtureFacts,
                                                   wiredBytes: 21_400_000_000))
        check("a machine whose ceiling or wired total is unreadable claims nothing about being over",
              !LocalModelSetup.residencyOverBudget(position: 0, facts: noFacts,
                                                   wiredBytes: 21_400_000_000)
                && !LocalModelSetup.residencyOverBudget(position: 0, facts: fixtureFacts,
                                                        wiredBytes: nil))
    }

    // MARK: - reading LM Studio's settings

    private static func checkJITReader(_ check: SelfTestReporter) {
        let directory = NSTemporaryDirectory() + "local-model-setup-selftest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        func write(_ json: String) -> String {
            let path = directory + "/settings-\(UUID().uuidString).json"
            try? json.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }

        // The real shape, taken from a live `~/.lmstudio/settings.json` on 2026-08-24.
        let real = write("""
        {"language":"en","developerMode":true,
         "developer":{"unloadPreviousJITModelOnLoad":true,
                      "jitModelTTL":{"enabled":true,"ttlSeconds":3600}},
         "defaultContextLength":16384}
        """)
        check("the real file shape parses to the timeout and whether it is on",
              LocalModelSetup.readJITSettings(path: real)
                == LocalModelSetup.JITSettings(ttlSeconds: 3600, enabled: true))

        // The path production actually reads. Asserted as a STRING rather than by planting a file at it:
        // writing into any `~/.lmstudio` from a gate is the one thing LOCKED DECISION 4 forbids outright,
        // and a "only if it does not already exist" guard is not a strong enough seatbelt for it. The
        // reading behaviour at that path is covered by the explicit-path fixtures around this line, so the
        // composition is covered without a gate ever creating an LM Studio settings file.
        check("the default path is this user's own LM Studio settings file",
              LocalModelSetup.jitSettingsPath == NSHomeDirectory() + "/.lmstudio/settings.json",
              LocalModelSetup.jitSettingsPath)

        check("a missing file reads as unknown rather than as a zero",
              LocalModelSetup.readJITSettings(path: directory + "/absent.json") == nil)
        check("a file that is not JSON reads as unknown",
              LocalModelSetup.readJITSettings(path: write("not json at all")) == nil)
        check("a settings file with no developer section reads as unknown",
              LocalModelSetup.readJITSettings(path: write(#"{"language":"en"}"#)) == nil)
        check("a developer section with no jitModelTTL reads as unknown",
              LocalModelSetup.readJITSettings(path: write(#"{"developer":{"appUpdateChannel":"stable"}}"#))
                == nil)
        check("a jitModelTTL carrying neither field reads as unknown rather than as a default",
              LocalModelSetup.readJITSettings(path: write(#"{"developer":{"jitModelTTL":{}}}"#)) == nil)
        check("a switched-off timeout is read as switched off, not as absent",
              LocalModelSetup.readJITSettings(path: write(#"{"developer":{"jitModelTTL":{"enabled":false}}}"#))
                == LocalModelSetup.JITSettings(ttlSeconds: nil, enabled: false))

        // The whole point of LOCKED DECISION 4: this file is READ, never written. LM Studio holds it in
        // memory and rewrites it, so a write here is clobbered on its next save.
        let untouched = write(#"{"developer":{"jitModelTTL":{"enabled":true,"ttlSeconds":3600}}}"#)
        let before = try? String(contentsOfFile: untouched, encoding: .utf8)
        _ = LocalModelSetup.readJITSettings(path: untouched)
        _ = LocalModelSetup.jitStatus(LocalModelSetup.readJITSettings(path: untouched), appIdleSeconds: 600)
        let after = try? String(contentsOfFile: untouched, encoding: .utf8)
        check("reading LM Studio's settings leaves the file byte-for-byte unchanged",
              before != nil && before == after)
    }

    // MARK: - what a reading means

    private static func checkJITStatus(_ check: SelfTestReporter) {
        check("an unreadable file is unknown, not fine",
              LocalModelSetup.jitStatus(nil, appIdleSeconds: 600) == .unknown)
        check("the hour that pinned 28.7 GB reads as too long",
              LocalModelSetup.jitStatus(.init(ttlSeconds: 3600, enabled: true), appIdleSeconds: 600)
                == .tooLong(ttlSeconds: 3600, appSeconds: 600))
        check("a timeout equal to the app's own is not flagged",
              LocalModelSetup.jitStatus(.init(ttlSeconds: 600, enabled: true), appIdleSeconds: 600)
                == .matched(ttlSeconds: 600))
        check("a shorter timeout is not flagged either",
              LocalModelSetup.jitStatus(.init(ttlSeconds: 60, enabled: true), appIdleSeconds: 600)
                == .matched(ttlSeconds: 60))
        check("a switched-off timeout is its own state, not a long one",
              LocalModelSetup.jitStatus(.init(ttlSeconds: 3600, enabled: false), appIdleSeconds: 600)
                == .noTimeout(appSeconds: 600))
        check("a missing or nonsensical number is unknown rather than zero",
              LocalModelSetup.jitStatus(.init(ttlSeconds: nil, enabled: true), appIdleSeconds: 600)
                == .unknown
                && LocalModelSetup.jitStatus(.init(ttlSeconds: 0, enabled: true), appIdleSeconds: 600)
                    == .unknown)

        // It is measured against the app's OWN timer, not against a constant. Raising ViddyDictate's timer
        // above LM Studio's has to settle the row.
        check("the comparison follows the app's own timer",
              LocalModelSetup.jitStatus(.init(ttlSeconds: 900, enabled: true), appIdleSeconds: 600)
                == .tooLong(ttlSeconds: 900, appSeconds: 600)
                && LocalModelSetup.jitStatus(.init(ttlSeconds: 900, enabled: true), appIdleSeconds: 1800)
                    == .matched(ttlSeconds: 900))

        check("only the two states that cost something ask to be acted on",
              LocalModelSetup.jitNeedsAttention(.tooLong(ttlSeconds: 3600, appSeconds: 600))
                && LocalModelSetup.jitNeedsAttention(.noTimeout(appSeconds: 600))
                && !LocalModelSetup.jitNeedsAttention(.matched(ttlSeconds: 600))
                && !LocalModelSetup.jitNeedsAttention(.unknown))
    }

    // MARK: - what the row says

    private static func checkJITCopy(_ check: SelfTestReporter) {
        let states: [LocalModelSetup.JITStatus] = [
            .matched(ttlSeconds: 600),
            .tooLong(ttlSeconds: 3600, appSeconds: 600),
            .noTimeout(appSeconds: 600),
            .unknown,
        ]
        check("every state has a state word, and it is readable without relying on hue",
              states.allSatisfy { !LocalModelSetup.jitStatusText($0).isEmpty })
        check("every state says what it found, in one line",
              states.allSatisfy { !LocalModelSetup.jitSummary($0).isEmpty })

        let tooLong = LocalModelSetup.JITStatus.tooLong(ttlSeconds: 3600, appSeconds: 600)
        check("the too-long row states both numbers in the unit they are set in",
              LocalModelSetup.jitSummary(tooLong)
                == "LM Studio holds JIT-loaded models for 60 min; recommended 10 min.",
              LocalModelSetup.jitSummary(tooLong))
        check("the too-long row says where to change it",
              LocalModelSetup.jitRemedy(tooLong)?.contains("Settings > Developer") == true)
        check("the too-long row says why ViddyDictate does not change it itself",
              LocalModelSetup.jitRemedy(tooLong)?.contains("overwrite the change") == true)
        check("the too-long row says what it costs while it stays this way",
              LocalModelSetup.jitConsequence(tooLong)?.contains("never unloads a model it did not load")
                == true)

        check("a settled row offers no fix and no consequence to read",
              LocalModelSetup.jitRemedy(.matched(ttlSeconds: 600)) == nil
                && LocalModelSetup.jitConsequence(.matched(ttlSeconds: 600)) == nil)

        // An app that could not read a file has learned nothing about the machine, and must not raise an
        // alarm about a number it does not have.
        check("an unreadable file does not read as a warning",
              !LocalModelSetup.jitNeedsAttention(.unknown)
                && LocalModelSetup.jitStatusText(.unknown) == "NOT READ")
        check("an unreadable file still says what to look at if models start being refused",
              LocalModelSetup.jitRemedy(.unknown)?.contains("Settings > Developer") == true)
        check("an unreadable file claims no consequence, because none was measured",
              LocalModelSetup.jitConsequence(.unknown) == nil)

        // Ben ships plain ASCII: no em dashes and no emoji anywhere the section can render.
        let everything = [LocalModelSetup.header, LocalModelSetup.headline, LocalModelSetup.purpose,
                          LocalModelSetup.budgetTitle, LocalModelSetup.timerTitle,
                          LocalModelSetup.timerHint, LocalModelSetup.jitTitle,
                          LocalModelSetup.budgetLine(position: 54, facts: fixtureFacts),
                          LocalModelSetup.budgetLine(position: 54, facts: noFacts),
                          LocalModelSetup.reservedLine(facts: fixtureFacts) ?? "",
                          LocalModelSetup.residencyTitle, LocalModelSetup.unloadAllTitle,
                          LocalModelSetup.unloadingTitle, LocalModelSetup.residencyNote,
                          LocalModelSetup.residencyList(.pending, now: clock),
                          LocalModelSetup.residencyList(.unavailable, now: clock),
                          LocalModelSetup.residencyList(.models([]), now: clock),
                          LocalModelSetup.residencyList(
                            .models([model("m", gb: 1), model("n", gb: 2, ttl: nil)]), now: clock),
                          LocalModelSetup.residencySummary(position: 54, facts: fixtureFacts,
                                                           wiredBytes: 21_400_000_000) ?? ""]
            + states.map(LocalModelSetup.jitStatusText)
            + states.map(LocalModelSetup.jitSummary)
            + states.compactMap(LocalModelSetup.jitRemedy)
            + states.compactMap(LocalModelSetup.jitConsequence)
        check("nothing the section renders is empty", everything.allSatisfy { !$0.isEmpty })
        check("nothing the section renders carries a character outside plain ASCII",
              everything.allSatisfy { $0.allSatisfy(\.isASCII) },
              everything.filter { !$0.allSatisfy(\.isASCII) }.joined(separator: " | "))
    }
}
