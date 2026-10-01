import Foundation

/// Byte-level progress for the first-run download (spec B7).
///
/// `ComponentPicker` decided what the rows say and what they cost; `BootstrapInstallCoordinator`
/// decides which row is running. This file is the third thing neither of them owns: how far along a
/// running row actually is, in BYTES, and how fast bytes are arriving.
///
/// **The premise this was built against did not reproduce.** The chain's manifest gives per-row
/// progress reporting to the installer engine link, but the merged engine reports PHASES only -
/// `pending / installing / installed / failed` - and its process runner reads each command's output to
/// EOF, so there is no byte number anywhere in the app to display. B7 asks for `340 MB of 570 MB` and
/// `12.4 MB/s`, and a progress screen with no byte source is theatre. So the observation seam is here,
/// OUTSIDE the engine, and it does not add a second downloader: it measures the download caches the
/// engine already redirects into the app's own Application Support.
///
/// **Why measuring caches is the honest source.** B10 forbids a hand-written downloader, so pip and
/// `huggingface_hub` own the transfer and neither streams a byte count the app can read without
/// parsing a progress bar off a non-tty pipe. What they DO both have is an app-owned cache directory
/// that grows as bytes land, `.incomplete` partials included - which is the same property that makes
/// their resume work. Sampling that directory measures the same bytes the user is waiting for, with
/// nothing to parse and nothing to keep in sync with a vendor's output format.
///
/// **Why two rows can come from one descriptor.** The picker shows `Transcription engine` and
/// `Voice model` separately because that is what the user is waiting on and what B7 lists, while the
/// engine installs them as the single `stt-daemon` descriptor. Presentation splits the row; it does
/// not split the work. The split is observable rather than guessed: wheels land in the package cache
/// and the model lands in the model cache, so the first byte into the model cache is the moment the
/// engine moved from one to the other.
enum InstallProgress {

    // MARK: - Where bytes land

    /// The cache a row's bytes arrive in. This is also how the two rows of one descriptor are told
    /// apart, so it is a fact about the download rather than a label.
    enum ByteSource: String, Equatable, CaseIterable {
        /// pip's own download/wheel cache, redirected to the app's Application Support.
        case packageCache
        /// `huggingface_hub`'s cache, already redirected there by the engine.
        case modelCache
        /// Fetched by a vendor's own installer (LM Studio's DMG, `lms get`), which does not write into
        /// a cache this app owns. Rows here report phase without a byte number rather than inventing one.
        case vendor
    }

    static func source(for id: ComponentPicker.RowID) -> ByteSource {
        switch id {
        case .pythonRuntime: return .packageCache
        case .transcriptionEngine, .webSearch: return .packageCache
        case .voiceModel: return .modelCache
        case .lmStudio, .gemma, .qwen: return .vendor
        }
    }

    /// Which picker rows one installer descriptor is responsible for, in the order the engine does the
    /// work: the venv and its wheels first, then the model artifacts.
    static func rows(forDescriptor id: String) -> [ComponentPicker.RowID] {
        switch id {
        case BootstrapInstallPlan.sttDaemon.id: return [.transcriptionEngine, .voiceModel]
        case BootstrapInstallPlan.webSearch.id: return [.webSearch]
        default: return []
        }
    }

    static func descriptorID(for row: ComponentPicker.RowID) -> String? {
        switch row {
        case .transcriptionEngine, .voiceModel: return BootstrapInstallPlan.sttDaemon.id
        case .webSearch: return BootstrapInstallPlan.webSearch.id
        case .pythonRuntime, .lmStudio, .gemma, .qwen: return nil
        }
    }

    // MARK: - Phase

    enum Phase: String, Equatable {
        case waiting
        case running
        case done
        case failed
    }

    // MARK: - A row

    struct Row: Equatable {
        let id: ComponentPicker.RowID
        let title: String
        let phase: Phase
        /// Measured, never assumed. Clamped to `bytesExpected` so a cache that stores a wheel twice
        /// cannot put 140% on screen.
        let bytesCompleted: UInt64
        let bytesExpected: UInt64?
        /// B10: the vendor's real text, never "Setup failed. Please try again."
        let failureMessage: String?

        init(id: ComponentPicker.RowID, phase: Phase, bytesCompleted: UInt64 = 0,
             bytesExpected: UInt64? = nil, failureMessage: String? = nil) {
            self.id = id
            self.title = ComponentPicker.title(id)
            self.phase = phase
            self.bytesExpected = bytesExpected
            if let bytesExpected { self.bytesCompleted = min(bytesCompleted, bytesExpected) }
            else { self.bytesCompleted = bytesCompleted }
            self.failureMessage = failureMessage
        }

        /// B8: a component is usable the moment its own row lands, which is why this is a per-row
        /// question and not a question about the queue.
        var isLive: Bool { phase == .done }
    }

    // MARK: - The words

    static let waitingText = "waiting"
    static let doneText = "done"

    /// The right-hand side of one row. B7's shape exactly: `done`, `340 MB of 570 MB`, `waiting`.
    ///
    /// A running row whose size was never measured shows what has arrived rather than a fraction of a
    /// number nobody measured - the same rule the picker follows when it says "plus LM Studio" instead
    /// of guessing.
    static func statusText(_ row: Row) -> String {
        statusText(phase: row.phase, bytesCompleted: row.bytesCompleted, bytesExpected: row.bytesExpected)
    }

    /// The same words for a row that is not one of the picker's: B7's shape does not depend on where the
    /// bytes were counted.
    static func statusText(phase: Phase, bytesCompleted: UInt64, bytesExpected: UInt64?) -> String {
        switch phase {
        case .waiting: return waitingText
        case .done: return doneText
        case .failed: return "failed"
        case .running:
            guard let expected = bytesExpected, expected > 0 else {
                return bytesCompleted > 0 ? ComponentPicker.downloadSize(bytesCompleted)
                                          : "starting"
            }
            return "\(ComponentPicker.downloadSize(min(bytesCompleted, expected))) of "
                + ComponentPicker.downloadSize(expected)
        }
    }

    // MARK: - Reported activity

    /// What a local step is waiting on when the thing it waits for is the USER, not a download: a macOS
    /// prompt the app raised on its first launch. Its own words, never "failed" and never a byte count.
    static func awaitingApprovalText(_ backend: LocalBackendID) -> String {
        "waiting for you to approve \(backend.displayName)'s macOS prompt"
    }

    /// The right-hand side of one installer row keyed by its DESCRIPTOR rather than a picker row: Ollama's
    /// app and model rows, which the picker does not list. Phase from the durable bootstrap record, detail
    /// from what the running step reported: real bytes from a streamed pull, or the approval wait.
    ///
    /// The point-of-use panel's running page and the Setup tab's local app rows read
    /// `BootstrapInstallCoordinator.activity(for:)` and render through this.
    /// TODO(S8): the revived first-run window's Ollama rows render through this too.
    static func statusText(for record: BootstrapComponentRecord, activity: InstallerLocalActivity?) -> String {
        switch record.phase {
        case .pending: return waitingText
        case .installed: return doneText
        case .failed: return "failed"
        case .installing:
            switch activity {
            case .awaitingApproval(let backend)?:
                return awaitingApprovalText(backend)
            case .bytes(let reading)?:
                return statusText(phase: .running, bytesCompleted: reading.completed,
                                  bytesExpected: reading.expected)
            case nil:
                return "installing"
            }
        }
    }

    // MARK: - The aggregate

    struct Aggregate: Equatable {
        var bytesCompleted: UInt64
        var bytesExpected: UInt64
        /// nil until two samples are far enough apart to divide by. A speed invented from one sample is
        /// a number that jumps, and the reason B7 wants a speed at all is that it is honest.
        var bytesPerSecond: Double?
        /// Rows whose size is not measurable here, so the total can say so instead of under-reporting.
        var unmeasured: [ComponentPicker.RowID]
        var anyRunning: Bool
    }

    static func aggregate(_ rows: [Row], bytesPerSecond: Double? = nil) -> Aggregate {
        var completed: UInt64 = 0
        var expected: UInt64 = 0
        var unmeasured: [ComponentPicker.RowID] = []
        for row in rows {
            guard let size = row.bytesExpected, size > 0 else {
                if row.phase != .done { unmeasured.append(row.id) }
                continue
            }
            expected &+= size
            completed &+= row.phase == .done ? size : row.bytesCompleted
        }
        return Aggregate(bytesCompleted: min(completed, expected), bytesExpected: expected,
                         bytesPerSecond: bytesPerSecond, unmeasured: unmeasured,
                         anyRunning: rows.contains { $0.phase == .running })
    }

    /// `1.4 GB of 2.1 GB`, with the same "plus LM Studio" honesty the picker's total uses.
    static func totalLine(_ aggregate: Aggregate) -> String {
        var line = "\(ComponentPicker.downloadSize(aggregate.bytesCompleted)) of "
            + ComponentPicker.downloadSize(aggregate.bytesExpected)
        if !aggregate.unmeasured.isEmpty {
            line += ", plus " + aggregate.unmeasured.map(ComponentPicker.title)
                .joined(separator: " and ")
        }
        return line
    }

    /// `12.4 MB/s`, or nothing at all.
    ///
    /// **This is the whole of B7's "no ETA. Ever."** There is no function here that divides bytes
    /// remaining by this number, and `InstallProgressSelfTest` scans every string this file can produce
    /// against a time vocabulary so that adding one reds a gate rather than shipping.
    ///
    /// It does not reuse the picker's size formatter, and the difference is the point: that one rounds
    /// to whole megabytes because "0.1 GB" is a worse way to say 121 MB, while a rate needs its decimal
    /// - B7 writes `12.4 MB/s`, and a speed that only ever moves in whole megabytes reads as a stuck
    /// number on exactly the connections where the user is watching it most closely.
    static func speedLine(_ aggregate: Aggregate) -> String? {
        guard aggregate.anyRunning, let rate = aggregate.bytesPerSecond, rate > 0 else { return nil }
        return speedText(rate)
    }

    static func speedText(_ bytesPerSecond: Double) -> String {
        let megabytes = bytesPerSecond / 1_000_000
        if megabytes >= 100 { return "\(Int(megabytes.rounded())) MB/s" }
        if megabytes >= 1 { return String(format: "%.1f MB/s", megabytes) }
        return "\(Int((bytesPerSecond / 1_000).rounded())) KB/s"
    }

    /// B9, said on the screen rather than left for the user to discover by trying it.
    static let dismissNote =
        "You can close this window. The download keeps going, and each part starts working the moment "
        + "it lands."

    static let headline = "Setting up ViddyDictate"

    // MARK: - Identity

    enum Part: String, CaseIterable {
        case title
        case status
    }

    static func identifier(_ part: Part, _ id: ComponentPicker.RowID) -> String {
        "install-progress-\(id.rawValue)-\(part.rawValue)"
    }

    static func rowIdentifier(_ id: ComponentPicker.RowID) -> String {
        "install-progress-row-\(id.rawValue)"
    }

    static let surfaceIdentifier = "install-progress"
    static let headlineIdentifier = "install-progress-headline"
    static let totalIdentifier = "install-progress-total"
    static let speedIdentifier = "install-progress-speed"
    static let barIdentifier = "install-progress-bar"
    static let dismissNoteIdentifier = "install-progress-dismiss-note"
    static let failureIdentifier = "install-progress-failure"
    static let retryTitle = "Retry"

    static func retryIdentifier(_ id: ComponentPicker.RowID) -> String {
        "install-progress-retry-\(id.rawValue)"
    }
}

// MARK: - Reported bytes

/// A byte count an installer step REPORTED, as opposed to one sampled from a cache this app owns. Ollama's
/// `/api/pull` streams its own byte counts, which is the one vendor download whose progress is real rather
/// than a phase. `completed` never exceeds what a step has seen so far; `expected` is nil while unknown.
struct InstallerByteProgress: Equatable {
    let completed: UInt64
    let expected: UInt64?
}

/// What a running local step is doing that its phase alone cannot say. Never persisted: it lives only while
/// the row runs, so a relaunch cannot find a stale "waiting for approval" on disk.
enum InstallerLocalActivity: Equatable {
    /// Real bytes from the step's own download.
    case bytes(InstallerByteProgress)
    /// The app is up to its macOS prompt, and the step is waiting for the user to answer it.
    case awaitingApproval(LocalBackendID)
}

// MARK: - Speed

/// Bytes per second over a sliding window, from samples of a running total.
///
/// The window exists because an instantaneous rate off two adjacent samples is noise: pip goes quiet
/// while it resolves and `huggingface_hub` writes in bursts, and a number that swings between 0 and
/// 300 MB/s tells the user less than no number at all. The clock is injected so the deterministic gate
/// can assert an actual rate rather than sleep and hope.
struct InstallSpeedMeter: Equatable {
    private struct Sample: Equatable {
        let time: TimeInterval
        let bytes: UInt64
    }

    /// Long enough to ride out a stall, short enough that the number still tracks reality.
    let window: TimeInterval
    /// Below this the two samples are too close together to divide by.
    let minimumSpan: TimeInterval
    private var samples: [Sample] = []

    init(window: TimeInterval = 6, minimumSpan: TimeInterval = 0.75) {
        self.window = window
        self.minimumSpan = minimumSpan
    }

    mutating func record(bytes: UInt64, at time: TimeInterval) {
        // A total that went backwards means the cache was cleared or a partial was rolled back. Keeping
        // the old samples would produce a negative rate, so the window restarts from here.
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        samples.append(Sample(time: time, bytes: bytes))
        samples.removeAll { time - $0.time > window }
    }

    mutating func reset() { samples.removeAll() }

    var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time - first.time
        guard span >= minimumSpan, last.bytes >= first.bytes else { return nil }
        return Double(last.bytes - first.bytes) / span
    }
}

// MARK: - Sampling bytes

protocol InstallByteSampling {
    func bytes(at source: InstallProgress.ByteSource) -> UInt64
}

/// The production sampler: the size of the two caches the engine downloads into.
///
/// Partial files count. `huggingface_hub` writes `.incomplete` blobs and pip writes its HTTP cache as
/// it streams, so counting everything under the directory is counting what has actually arrived - and
/// on a resumed download it correctly starts from what was already there rather than from zero.
struct InstallCacheByteSampler: InstallByteSampling {
    let packageCache: URL
    let modelCache: URL
    let fileManager: FileManager

    init(paths: InstallerPaths = .live, fileManager: FileManager = .default) {
        self.packageCache = paths.packageCache
        self.modelCache = paths.modelCache
        self.fileManager = fileManager
    }

    func bytes(at source: InstallProgress.ByteSource) -> UInt64 {
        switch source {
        case .packageCache: return Self.size(of: packageCache, fileManager: fileManager)
        case .modelCache: return Self.size(of: modelCache, fileManager: fileManager)
        case .vendor: return 0
        }
    }

    /// Logical size, not allocated size: the number being compared against is a published download
    /// size, and allocated size would add this filesystem's block rounding to it.
    static func size(of directory: URL, fileManager: FileManager = .default) -> UInt64 {
        guard let walk = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize else { continue }
            total &+= UInt64(size)
        }
        return total
    }
}

// MARK: - The state machine

/// Turns "which descriptor is installing" plus "how big are the caches" into B7's rows.
///
/// It is a value type with an injected clock and an injected sampler, so every claim it makes is
/// assertable without a download, a timer, or a screenshot.
struct InstallProgressState: Equatable {

    /// The rows the user is waiting on, in the order they were shown in the picker.
    private(set) var order: [ComponentPicker.RowID]
    private var phases: [ComponentPicker.RowID: InstallProgress.Phase] = [:]
    private var bytes: [ComponentPicker.RowID: UInt64] = [:]
    private var failures: [ComponentPicker.RowID: String] = [:]
    private var baselines: [String: [InstallProgress.ByteSource: UInt64]] = [:]
    private var meter = InstallSpeedMeter()
    private let sizes: ComponentPicker.SizeCatalog

    /// Built from the plan the picker handed on, so the progress list IS the list that was ticked.
    init(plan: ComponentPicker.InstallPlan, sizes: ComponentPicker.SizeCatalog = .measured) {
        self.sizes = sizes
        var order: [ComponentPicker.RowID] = [.pythonRuntime]
        for descriptor in plan.components {
            order.append(contentsOf: InstallProgress.rows(forDescriptor: descriptor.id))
        }
        if plan.lmStudio { order.append(.lmStudio) }
        for id in [ComponentPicker.RowID.gemma, .qwen] where plan.models.contains(where: {
            $0 == id.modelID
        }) {
            order.append(id)
        }
        self.order = order
        // B3: the runtime is already on disk inside the .app, so it is done before the queue starts.
        // Saying "waiting" about a thing that shipped would be the picker's Python disclosure undone.
        phases[.pythonRuntime] = .done
        for id in order where id != .pythonRuntime { phases[id] = .waiting }
    }

    /// Fold in the coordinator's phases and one cache measurement.
    ///
    /// `time` is a monotonic timestamp; the caller owns the clock so the gate can drive minutes of
    /// download in microseconds.
    mutating func apply(snapshot: BootstrapSnapshot, sampler: InstallByteSampling,
                        at time: TimeInterval) {
        let sample: [InstallProgress.ByteSource: UInt64] = [
            .packageCache: sampler.bytes(at: .packageCache),
            .modelCache: sampler.bytes(at: .modelCache),
            .vendor: 0,
        ]

        for record in snapshot.components {
            let rows = InstallProgress.rows(forDescriptor: record.id)
            guard !rows.isEmpty else { continue }

            switch record.phase {
            case .pending:
                for row in rows where phases[row] != .done { phases[row] = .waiting }
            case .installing:
                // First sight of this descriptor running: everything already in the caches belongs to
                // work that is not this row's, so it is subtracted out rather than counted as progress.
                if baselines[record.id] == nil { baselines[record.id] = sample }
                let base = baselines[record.id] ?? [:]
                var modelBytes: UInt64 = 0
                for row in rows {
                    let source = InstallProgress.source(for: row)
                    let now = sample[source] ?? 0
                    let delta = now &- min(now, base[source] ?? 0)
                    if source == .modelCache { modelBytes = now }
                    // The two caches need different arithmetic, because they hold different things.
                    //
                    // The package cache is SHARED: both venv rows install wheels into it, so the only
                    // way to say what this row fetched is to subtract what was there when it started.
                    // The model cache holds this row's model and nothing else, so its absolute size IS
                    // this row's progress - and that is what makes B10's resume read correctly. A
                    // baseline there would subtract the partial the resume is building on and show a
                    // download restarting from zero, which is the exact thing B10 promises never happens.
                    bytes[row] = source == .modelCache ? now : delta
                }
                // The engine does wheels first, then models, so a byte in the model cache is proof the
                // wheel step is behind us - including the case where every wheel was already cached and
                // the honest number for that row is zero.
                //
                // The test is the model cache's ABSOLUTE size, not its growth since this row started.
                // Growth would leave a resumed download reading "waiting" beside a row that has 900 MB
                // on disk, and since the total sums what the rows hold, the screen would show a total
                // no row on it accounted for - the exact "the total is a caption" failure the picker's
                // own gate exists to catch.
                for row in rows {
                    guard phases[row] != .done else { continue }
                    switch InstallProgress.source(for: row) {
                    case .packageCache:
                        phases[row] = modelBytes > 0 ? .done : .running
                    case .modelCache:
                        phases[row] = modelBytes > 0 ? .running : .waiting
                    case .vendor:
                        phases[row] = .running
                    }
                }
            case .installed:
                for row in rows { phases[row] = .done; failures[row] = nil }
            case .failed:
                // B10: the row that was actually running takes the failure and shows the real text. A
                // row that had already landed stays landed - one row failing does not un-install its
                // sibling.
                let running = rows.last { phases[$0] == .running } ?? rows.first { phases[$0] != .done }
                for row in rows where phases[row] != .done {
                    phases[row] = row == running ? .failed : .waiting
                }
                if let running { failures[running] = record.failureMessage }
            }
        }

        meter.record(bytes: measuredBytes(), at: time)
    }

    /// Rows driven by something other than the installer queue - LM Studio and the models, which the
    /// vendor's own installer and `lms` fetch. Kept as a supplied phase rather than a second queue.
    mutating func setVendorPhase(_ phase: InstallProgress.Phase, for id: ComponentPicker.RowID,
                                 failureMessage: String? = nil) {
        guard InstallProgress.source(for: id) == .vendor else { return }
        phases[id] = phase
        failures[id] = failureMessage
    }

    private func measuredBytes() -> UInt64 {
        var total: UInt64 = 0
        for id in order {
            guard let size = expected(id), size > 0 else { continue }
            total &+= phases[id] == .done ? size : min(bytes[id] ?? 0, size)
        }
        return total
    }

    private func expected(_ id: ComponentPicker.RowID) -> UInt64? {
        ComponentPicker.bytes(for: id, sizes: sizes)
    }

    var rows: [InstallProgress.Row] {
        order.map { id in
            InstallProgress.Row(id: id, phase: phases[id] ?? .waiting,
                                bytesCompleted: bytes[id] ?? 0, bytesExpected: expected(id),
                                failureMessage: failures[id])
        }
    }

    var aggregate: InstallProgress.Aggregate {
        InstallProgress.aggregate(rows, bytesPerSecond: meter.bytesPerSecond)
    }

    /// B8, asked of one component rather than of the queue.
    func isLive(_ id: ComponentPicker.RowID) -> Bool { phases[id] == .done }

    var failedRows: [InstallProgress.Row] { rows.filter { $0.phase == .failed } }
}
