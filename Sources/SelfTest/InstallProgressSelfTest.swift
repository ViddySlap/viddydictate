import Foundation

/// Deterministic proof for B7's progress readout and B19's permissions model.
///
/// Everything here runs without a download, a timer, or a screen: the byte sampler is a stub, the
/// clock is a number, and the coordinator's phases are constructed. What it asserts is the part a
/// screenshot cannot - that the numbers on the progress screen are a READOUT of bytes that arrived,
/// that no string on it can ever promise a time, and that the Grant buttons point at panes that exist
/// on this OS.
enum InstallProgressSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " - \(detail)")")
        if !ok { failures += 1 }
    }

    /// A cache whose size the test sets by hand, standing in for pip's and huggingface_hub's.
    private final class StubSampler: InstallByteSampling {
        var package: UInt64 = 0
        var model: UInt64 = 0
        func bytes(at source: InstallProgress.ByteSource) -> UInt64 {
            switch source {
            case .packageCache: return package
            case .modelCache: return model
            case .vendor: return 0
            }
        }
    }

    private static let sizes = ComponentPicker.SizeCatalog.measured

    private static func corePlan() -> ComponentPicker.InstallPlan {
        ComponentPicker.InstallPlan(components: BootstrapInstallPlan.mandatoryCore,
                                    lmStudio: false, models: [])
    }

    private static func snapshot(_ phases: [String: BootstrapComponentPhase],
                                 failure: [String: String] = [:]) -> BootstrapSnapshot {
        var state = BootstrapSnapshot.fresh()
        state.components = state.components.map { record in
            var record = record
            if let phase = phases[record.id] { record.phase = phase }
            record.failureMessage = failure[record.id]
            return record
        }
        return state
    }

    private static func row(_ id: ComponentPicker.RowID,
                            in state: InstallProgressState) -> InstallProgress.Row? {
        state.rows.first { $0.id == id }
    }

    static func run() -> Bool {
        failures = 0
        print("[install-progress-selftest] B7 progress readout and B19 permissions")

        testRowsAreTheListThatWasTicked()
        testBytesAreMeasuredNotAssumed()
        testTwoRowsFromOneDescriptor()
        testResumeDoesNotCountSomeoneElsesBytes()
        testFailureKeepsTheRealErrorOnTheRowThatFailed()
        testSpeed()
        testNoETAEver()
        testTotals()
        testPermissionModel()
        testPermissionAnchors()

        print("[install-progress-selftest] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    // MARK: - The list

    /// B7: "the user sees the same list they just ticked".
    private static func testRowsAreTheListThatWasTicked() {
        let core = InstallProgressState(plan: corePlan())
        check("the core plan produces B7's four rows in B7's order",
              core.order == [.pythonRuntime, .transcriptionEngine, .voiceModel, .webSearch],
              core.order.map(\.rawValue).joined(separator: ","))

        let everything = ComponentPicker.InstallPlan(
            components: BootstrapInstallPlan.mandatoryCore, lmStudio: true,
            models: [LLMProviderDefaults.localEmailModelID, LLMProviderDefaults.localCleanupModelID])
        let full = InstallProgressState(plan: everything)
        check("a ticked optional row is a row the user can watch, not a silent extra",
              full.order.contains(.lmStudio) && full.order.contains(.gemma)
                && full.order.contains(.qwen),
              full.order.map(\.rawValue).joined(separator: ","))

        let untickedModels = InstallProgressState(plan: corePlan())
        check("a row the user did NOT tick never appears on the progress screen",
              !untickedModels.order.contains(.gemma) && !untickedModels.order.contains(.qwen))

        // B3: the runtime shipped inside the .app. A "waiting" beside it would undo the picker's
        // disclosure row by implying it is being fetched.
        check("the bundled runtime reads done before anything starts",
              row(.pythonRuntime, in: core)?.phase == .done
                && InstallProgress.statusText(row(.pythonRuntime, in: core)!) == "done")
        check("every other row starts at waiting",
              core.rows.filter { $0.id != .pythonRuntime }.allSatisfy { $0.phase == .waiting })
    }

    // MARK: - Bytes

    /// The claim the whole screen rests on: the number moved because bytes landed.
    private static func testBytesAreMeasuredNotAssumed() {
        var state = InstallProgressState(plan: corePlan())
        let sampler = StubSampler()
        let installing = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])

        state.apply(snapshot: installing, sampler: sampler, at: 0)
        let atZero = InstallProgress.statusText(row(.transcriptionEngine, in: state)!)

        sampler.package = 120_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 1)
        let at120 = InstallProgress.statusText(row(.transcriptionEngine, in: state)!)

        check("a row that has downloaded nothing still states the size it is working toward",
              atZero == "0 MB of \(ComponentPicker.downloadSize(sizes.transcriptionEngine!))", atZero)
        // "starting" is reserved for a row whose size nobody measured, so it cannot show a fraction.
        let unmeasured = InstallProgress.Row(id: .lmStudio, phase: .running)
        check("a row with no measured size says so rather than showing 0 of 0",
              InstallProgress.statusText(unmeasured) == "starting",
              InstallProgress.statusText(unmeasured))
        check("the row reads back the bytes that actually landed in the cache",
              at120 == "120 MB of \(ComponentPicker.downloadSize(sizes.transcriptionEngine!))", at120)
        check("the two readings differ, so the row is a readout and not a caption", atZero != at120)

        // A cache that stores a wheel twice must not put 140% on screen.
        sampler.package = 900_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 2)
        let clamped = row(.transcriptionEngine, in: state)!
        check("a row cannot report more than its measured size",
              clamped.bytesCompleted == sizes.transcriptionEngine,
              "\(clamped.bytesCompleted)")
    }

    /// The engine installs `stt-daemon` as one descriptor; B7 lists two rows. The split is observed
    /// from WHERE bytes land, not guessed from elapsed time.
    private static func testTwoRowsFromOneDescriptor() {
        var state = InstallProgressState(plan: corePlan())
        let sampler = StubSampler()
        let installing = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])

        sampler.package = 50_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 0)
        check("while wheels are landing, the engine row runs and the model row waits",
              row(.transcriptionEngine, in: state)?.phase == .running
                && row(.voiceModel, in: state)?.phase == .waiting)

        sampler.model = 400_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 1)
        check("the first byte into the model cache flips the engine row to done and starts the model",
              row(.transcriptionEngine, in: state)?.phase == .done
                && row(.voiceModel, in: state)?.phase == .running)
        check("the model row counts model bytes, not the wheels that came before it",
              row(.voiceModel, in: state)?.bytesCompleted == 400_000_000,
              "\(row(.voiceModel, in: state)?.bytesCompleted ?? 0)")

        state.apply(snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .installed]),
                    sampler: sampler, at: 2)
        check("when the descriptor lands, both of its rows are done",
              row(.transcriptionEngine, in: state)?.phase == .done
                && row(.voiceModel, in: state)?.phase == .done)
    }

    /// B10 resumes from a partial rather than restarting, so the cache is NOT empty when a row starts.
    /// Counting what was already there would show a download that began at 40%.
    private static func testResumeDoesNotCountSomeoneElsesBytes() {
        var state = InstallProgressState(plan: corePlan())
        let sampler = StubSampler()
        sampler.package = 242_000_000  // the transcription engine's wheels, already installed

        let webSearch = snapshot([BootstrapInstallPlan.sttDaemon.id: .installed,
                                  BootstrapInstallPlan.webSearch.id: .installing])
        state.apply(snapshot: webSearch, sampler: sampler, at: 0)
        check("a row starting against a full cache starts at zero, not at what was already there",
              row(.webSearch, in: state)?.bytesCompleted == 0,
              "\(row(.webSearch, in: state)?.bytesCompleted ?? 0)")

        sampler.package = 242_000_000 + 7_000_000
        state.apply(snapshot: webSearch, sampler: sampler, at: 1)
        check("it then counts only its own bytes",
              row(.webSearch, in: state)?.bytesCompleted == 7_000_000,
              "\(row(.webSearch, in: state)?.bytesCompleted ?? 0)")

        // The model cache is single-tenant, so the opposite rule applies and B10's promise depends on
        // it: a resumed model download must show the partial it is building on, not restart at zero.
        var resumed = InstallProgressState(plan: corePlan())
        let partial = StubSampler()
        partial.package = 242_000_000
        partial.model = 900_000_000  // an interrupted attempt, already on disk
        let sttInstalling = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])
        resumed.apply(snapshot: sttInstalling, sampler: partial, at: 0)
        partial.model = 950_000_000
        resumed.apply(snapshot: sttInstalling, sampler: partial, at: 1)
        check("a resumed model download counts the partial it is resuming from",
              row(.voiceModel, in: resumed)?.bytesCompleted == 950_000_000,
              "\(row(.voiceModel, in: resumed)?.bytesCompleted ?? 0)")
        // Found by looking at the render: a row can hold bytes and still read "waiting", and because
        // the total sums what the rows hold, the screen then showed 900 MB that no row accounted for.
        check("a row holding bytes never reads waiting", resumed.rows.allSatisfy {
            $0.phase != .waiting || $0.bytesCompleted == 0
        }, resumed.rows.map { "\($0.id.rawValue)=\($0.phase.rawValue)/\($0.bytesCompleted)" }
            .joined(separator: " "))
        check("the total never exceeds what the rows themselves display",
              resumed.aggregate.bytesCompleted
                <= resumed.rows.reduce(UInt64(0)) { sum, row in
                    sum &+ (row.phase == .done ? (row.bytesExpected ?? 0) : row.bytesCompleted)
                },
              "\(resumed.aggregate.bytesCompleted)")
    }

    // MARK: - Failure

    private static func testFailureKeepsTheRealErrorOnTheRowThatFailed() {
        var state = InstallProgressState(plan: corePlan())
        let sampler = StubSampler()
        let installing = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])
        sampler.package = 50_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 0)
        sampler.model = 10_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 1)

        let vendorText = "Could not resolve huggingface.co"
        state.apply(snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .failed],
                                       failure: [BootstrapInstallPlan.sttDaemon.id: vendorText]),
                    sampler: sampler, at: 2)

        check("the row that was running is the row that failed",
              row(.voiceModel, in: state)?.phase == .failed)
        check("a sibling that had already landed stays landed",
              row(.transcriptionEngine, in: state)?.phase == .done)
        // B10, and the reasoning Ben already settled once on redacted provider stderr: a stranger who
        // reads "Could not resolve huggingface.co" checks their wifi.
        check("the failed row carries the vendor's own words, not a generic setup message",
              row(.voiceModel, in: state)?.failureMessage == vendorText,
              row(.voiceModel, in: state)?.failureMessage ?? "nil")
        check("only the failed row is listed as failed", state.failedRows.map(\.id) == [.voiceModel])
        // B8: the whole point of per-row failure is that the rest of the app still arrives.
        check("a failed row does not un-install a component that already went live",
              state.isLive(.transcriptionEngine))
    }

    // MARK: - Speed

    private static func testSpeed() {
        var meter = InstallSpeedMeter()
        check("one sample is not a speed", meter.bytesPerSecond == nil)
        meter.record(bytes: 0, at: 0)
        meter.record(bytes: 12_400_000, at: 1)
        check("two samples a second apart give the rate between them",
              meter.bytesPerSecond.map { abs($0 - 12_400_000) < 1 } == true,
              "\(meter.bytesPerSecond ?? -1)")

        // Samples closer together than the minimum span are noise, not a measurement.
        var tight = InstallSpeedMeter()
        tight.record(bytes: 0, at: 0)
        tight.record(bytes: 5_000_000, at: 0.1)
        check("samples too close together do not produce a number", tight.bytesPerSecond == nil)

        // A cleared cache or a rolled-back partial must not read as negative speed.
        var backwards = InstallSpeedMeter()
        backwards.record(bytes: 500_000_000, at: 0)
        backwards.record(bytes: 1_000_000, at: 1)
        backwards.record(bytes: 3_000_000, at: 2)
        check("a total that went backwards restarts the window instead of going negative",
              (backwards.bytesPerSecond ?? 0) >= 0, "\(backwards.bytesPerSecond ?? -1)")

        // The window slides, so a long-finished burst stops inflating the current number.
        var sliding = InstallSpeedMeter(window: 6)
        sliding.record(bytes: 0, at: 0)
        sliding.record(bytes: 600_000_000, at: 1)
        sliding.record(bytes: 601_000_000, at: 20)
        sliding.record(bytes: 602_000_000, at: 21)
        check("a burst that has fallen out of the window no longer counts toward the rate",
              sliding.bytesPerSecond.map { abs($0 - 1_000_000) < 1 } == true,
              "\(sliding.bytesPerSecond ?? -1)")

        // B7 writes 12.4 MB/s. A rate is the one number here that needs its decimal.
        check("a rate keeps one decimal where the picker's size formatter would round it away",
              InstallProgress.speedText(12_400_000) == "12.4 MB/s"
                && ComponentPicker.downloadSize(12_400_000) == "12 MB",
              InstallProgress.speedText(12_400_000))
        check("a slow connection reads in KB/s rather than as 0.0 MB/s",
              InstallProgress.speedText(240_000) == "240 KB/s",
              InstallProgress.speedText(240_000))

        let stalled = InstallProgress.aggregate(
            [InstallProgress.Row(id: .voiceModel, phase: .done, bytesExpected: 100)],
            bytesPerSecond: 12_400_000)
        check("no speed is shown when nothing is running",
              InstallProgress.speedLine(stalled) == nil)
        let running = InstallProgress.aggregate(
            [InstallProgress.Row(id: .voiceModel, phase: .running, bytesCompleted: 10,
                                 bytesExpected: 100)],
            bytesPerSecond: 12_400_000)
        check("a running download shows bytes per second in B7's spelling",
              InstallProgress.speedLine(running) == "12.4 MB/s",
              InstallProgress.speedLine(running) ?? "nil")
    }

    // MARK: - No ETA

    /// **B7: "No time estimate. Ever."**
    ///
    /// Pinned the way B16's cloud hop is pinned - as a property of the whole surface rather than a
    /// review note. Every string this screen can produce, across every state it can reach, is swept for
    /// a time vocabulary. Adding "about 2 minutes remaining" anywhere reds this gate.
    private static func testNoETAEver() {
        var strings: [String] = [
            InstallProgress.headline, InstallProgress.dismissNote, InstallProgress.waitingText,
            InstallProgress.doneText, PermissionsScreen.headline, PermissionsScreen.subtitle,
            PermissionsScreen.grantTitle, PermissionsScreen.grantedText,
            PermissionsScreen.pendingText, PermissionsScreen.continueTitle,
            PermissionsScreen.allGrantedNote,
        ]
        strings += SetupPermission.allCases.flatMap { [$0.title, $0.detail] }

        // Every row state, at a spread of byte counts, on every row the picker knows about.
        for id in ComponentPicker.RowID.allCases {
            for phase in [InstallProgress.Phase.waiting, .running, .done, .failed] {
                for bytes in [UInt64(0), 1, 1_000, 340_000_000, 1_400_000_000] {
                    for expected in [nil, UInt64(0), 570_000_000, 1_610_000_000] as [UInt64?] {
                        let row = InstallProgress.Row(id: id, phase: phase, bytesCompleted: bytes,
                                                      bytesExpected: expected)
                        strings.append(InstallProgress.statusText(row))
                        let aggregate = InstallProgress.aggregate([row], bytesPerSecond: 12_400_000)
                        strings.append(InstallProgress.totalLine(aggregate))
                        if let speed = InstallProgress.speedLine(aggregate) { strings.append(speed) }
                    }
                }
            }
        }
        for status in permutations() {
            if let banner = status.bannerLine { strings.append(banner) }
        }

        // "s" alone is excluded deliberately: "MB/s" is a rate, which is the thing B7 asked FOR.
        let timeWords = ["second", "seconds", "minute", "minutes", "hour", "hours", "remaining",
                         "left", "eta", "time", "estimate", "until", "finish", "finishes",
                         "sec", "min", "hr", "ago", "soon"]
        var offenders: [String] = []
        for value in strings {
            let lower = value.lowercased()
            for word in timeWords where lower.range(of: "\\b\(word)\\b", options: .regularExpression)
                != nil {
                offenders.append("\(value) [\(word)]")
            }
            // A clock-shaped number is an ETA even without a word beside it.
            if lower.range(of: "\\b\\d+:\\d\\d\\b", options: .regularExpression) != nil {
                offenders.append("\(value) [clock]")
            }
        }
        check("no string this surface can produce promises a time (B7: no ETA, ever)",
              offenders.isEmpty, offenders.prefix(3).joined(separator: " | "))
        check("the sweep actually looked at a real spread of strings", strings.count > 500,
              "\(strings.count)")
    }

    // MARK: - Totals

    private static func testTotals() {
        var state = InstallProgressState(plan: corePlan())
        let sampler = StubSampler()
        let installing = snapshot([BootstrapInstallPlan.sttDaemon.id: .installing])
        // The row has to START before bytes land, or the baseline correctly treats them as somebody
        // else's - which is the resume behaviour proved above, not a total that fails to count.
        state.apply(snapshot: installing, sampler: sampler, at: 0)
        sampler.package = 100_000_000
        state.apply(snapshot: installing, sampler: sampler, at: 1)
        let aggregate = state.aggregate
        let core = (sizes.transcriptionEngine ?? 0) + (sizes.voiceModel ?? 0) + (sizes.webSearch ?? 0)
        check("the total's denominator is the measured core, and excludes the bundled runtime",
              aggregate.bytesExpected == core,
              "\(aggregate.bytesExpected) vs \(core)")
        check("the total's numerator is what has landed", aggregate.bytesCompleted == 100_000_000,
              "\(aggregate.bytesCompleted)")
        check("the total line reads as B7 writes it",
              InstallProgress.totalLine(aggregate)
                == "100 MB of \(ComponentPicker.downloadSize(core))",
              InstallProgress.totalLine(aggregate))

        // The same honesty the picker's total uses: LM Studio's size is not known until L3 resolves its
        // installer, so the total says so instead of quietly under-reporting.
        let withVendor = InstallProgressState(
            plan: ComponentPicker.InstallPlan(components: BootstrapInstallPlan.mandatoryCore,
                                              lmStudio: true, models: []))
        check("an unmeasured row is named in the total rather than counted as zero",
              InstallProgress.totalLine(withVendor.aggregate).hasSuffix("plus LM Studio"),
              InstallProgress.totalLine(withVendor.aggregate))

        // B8, as the number the user watches: a finished row contributes its whole size.
        var finished = InstallProgressState(plan: corePlan())
        finished.apply(snapshot: snapshot([BootstrapInstallPlan.sttDaemon.id: .installed,
                                           BootstrapInstallPlan.webSearch.id: .installed]),
                       sampler: sampler, at: 0)
        check("a completed queue reads as complete", finished.aggregate.bytesCompleted == core,
              "\(finished.aggregate.bytesCompleted) vs \(core)")
    }

    // MARK: - B19

    private static func permutations() -> [PermissionsStatus] {
        var all: [PermissionsStatus] = []
        for mic in [false, true] {
            for ax in [false, true] {
                for im in [false, true] {
                    all.append(PermissionsStatus(microphone: mic, accessibility: ax,
                                                 inputMonitoring: im))
                }
            }
        }
        return all
    }

    private static func testPermissionModel() {
        check("B19's three permissions, and only those three",
              SetupPermission.allCases == [.microphone, .accessibility, .inputMonitoring])

        let none = PermissionsStatus()
        check("with nothing granted, all three are outstanding", none.ungranted.count == 3
                && !none.allGranted)
        let all = PermissionsStatus(microphone: true, accessibility: true, inputMonitoring: true)
        check("with everything granted there is nothing left to ask for", all.allGranted
                && all.bannerLine == nil)

        // B19: each row flips on its own as its own grant lands.
        var partial = PermissionsStatus(microphone: true)
        check("one grant landing flips one row and leaves the others alone",
              partial.isGranted(.microphone) && !partial.isGranted(.accessibility)
                && !partial.isGranted(.inputMonitoring))
        partial.set(.inputMonitoring, true)
        check("a second grant landing does not disturb the first",
              partial.isGranted(.microphone) && partial.isGranted(.inputMonitoring)
                && partial.ungranted == [.accessibility])

        // B19: ungranted permissions are NAMED, the way an unfinished download is.
        check("the banner names the permission that is missing",
              partial.bannerLine?.contains("Accessibility") == true, partial.bannerLine ?? "nil")
        check("the banner lists all three readably when none are granted",
              none.bannerLine == "ViddyDictate still needs Microphone, Accessibility and Input "
                + "Monitoring - Open setup", none.bannerLine ?? "nil")

        // The microphone is the one grant macOS will hand over from a prompt the app can raise.
        check("an undetermined microphone asks, rather than sending the user to System Settings",
              PermissionsGrant.action(for: .microphone, microphoneAuthorization: .notDetermined)
                == .requestMicrophonePrompt)
        check("a refused microphone goes to the pane, because the prompt is spent",
              PermissionsGrant.action(for: .microphone, microphoneAuthorization: .denied)
                == .openSettings(.microphone))
        for permission in [SetupPermission.accessibility, .inputMonitoring] {
            check("\(permission.title) always goes to the pane, at any microphone state",
                  [MicrophoneAuthorization.notDetermined, .denied, .authorized].allSatisfy {
                      PermissionsGrant.action(for: permission, microphoneAuthorization: $0)
                          == .openSettings(permission)
                  })
        }

        var opened: [URL] = []
        _ = PermissionsGrant.perform(.openSettings(.accessibility), opener: { opened.append($0); return true })
        check("performing the action opens exactly that permission's pane",
              opened == [SetupPermission.accessibility.settingsURL],
              opened.map(\.absoluteString).joined())
    }

    /// The Grant button's whole promise is that it lands on the EXACT pane, so the anchors are checked
    /// against the OS rather than against memory.
    private static func testPermissionAnchors() {
        let expected: [SetupPermission: String] = [
            .microphone: "Privacy_Microphone",
            .accessibility: "Privacy_Accessibility",
            .inputMonitoring: "Privacy_ListenEvent",
        ]
        for (permission, anchor) in expected {
            check("\(permission.title) uses the \(anchor) anchor",
                  permission.settingsAnchor == anchor, permission.settingsAnchor)
        }

        // Every snippet on the internet still says com.apple.preference.security, which was System
        // Preferences' pane id and is gone. Measured on 15.6.1: it appears nowhere in System Settings.
        check("the pane id is the extension System Settings actually ships",
              SetupPermission.privacyPaneIdentifier == "com.apple.settings.PrivacySecurity.extension",
              SetupPermission.privacyPaneIdentifier)
        check("no row uses the retired System Preferences pane id",
              SetupPermission.allCases.allSatisfy {
                  !$0.settingsURL.absoluteString.contains("com.apple.preference.security")
              })
        for permission in SetupPermission.allCases {
            let url = permission.settingsURL.absoluteString
            check("\(permission.title)'s deep link is well formed",
                  url == "x-apple.systempreferences:"
                    + "\(SetupPermission.privacyPaneIdentifier)?\(permission.settingsAnchor)", url)
        }
        check("the three rows point at three different panes",
              Set(SetupPermission.allCases.map(\.settingsURL)).count == 3)

        // Apple's own declaration of the Input Monitoring anchor, read from the OS at test time. If a
        // future macOS renames it, this reds here rather than shipping a button that opens nothing.
        let list = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/"
            + "SecurityPrivacyExtension.appex/Contents/Resources/TCCServiceList.plist")
        if let data = try? Data(contentsOf: list),
           let entries = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [[String: Any]] {
            let declared = entries.compactMap { $0["revealElementKeyName"] as? String }
            check("this macOS still declares Privacy_ListenEvent as the Input Monitoring anchor",
                  declared.contains(SetupPermission.inputMonitoring.settingsAnchor),
                  "declared=\(declared.count) anchors")
        } else {
            print("  [INFO] TCCServiceList.plist not readable here; anchor cross-check skipped")
        }
    }
}
