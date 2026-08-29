import Foundation

/// The first-run component picker (spec B1-B6, and the resolutions of O1 and O2).
///
/// This file holds the judgement, the words, and the measured numbers; `ComponentPickerView` draws
/// them and `FirstRunSetupWindowController` hosts it. Everything here is a pure function of a
/// `Selection` and a `MachineFacts`/`Environment` pair, so what the picker CLAIMS about a machine can
/// be asserted without a screenshot - which matters more here than anywhere else in the app, because
/// the picker's whole job is to make a promise about what a download will cost and whether it will
/// run.
///
/// **B1: this is a picker, not a wall.** Nothing here can express "block the app". The only outputs
/// are a set of rows, a byte total, and a plan; there is no refusal state and no gate.
///
/// **B2/B3: the mandatory core is not a checkbox.** Core rows carry no tick and no availability, so a
/// caller cannot switch one off even by mistake - `RowState.included` and `RowState.bundled` have no
/// boolean in them. The bundled Python runtime is a DISCLOSURE row (B3): it states that the runtime
/// lives inside the app bundle and vanishes with it, and it contributes ZERO to the download total,
/// because it ships in the .app rather than being fetched.
enum ComponentPicker {

    // MARK: - Measured sizes (O1)

    /// What each row actually costs to download, MEASURED on 2026-08-27 rather than estimated.
    ///
    /// O1 exists because the spec's `~4 GB` and `~18 GB` were figures stated during a grill, and it
    /// says plainly: do not ship an estimate as a user-facing byte count. Every number below was
    /// measured, and the two that the spec guessed at were both wrong - gemma by 1.7x. The method for
    /// each is recorded beside it so the next person can re-measure the same way rather than inventing
    /// a third number:
    ///
    /// - **Transcription engine, web search:** the exact package lists in `BootstrapInstallPlan`,
    ///   resolved with `pip install --dry-run --report` using the app's own bundled 3.12.14
    ///   interpreter on arm64, then every resolved wheel's `Content-Length` summed from
    ///   files.pythonhosted.org. That is transfer bytes, NOT installed footprint: after B20's torch
    ///   cut the STT environment downloads 121 MB of wheels and expands to about 494 MB on disk (it
    ///   was 242 MB expanding to 1.1 GB with torch, both re-measured cold on 2026-08-29), and quoting
    ///   the larger number in a line that says "download" would be its own kind of lie.
    /// - **Voice model:** the published blob sizes of `mlx-community/whisper-large-v3-turbo` from the
    ///   Hugging Face model API, which is exactly what `snapshot_download` transfers.
    /// - **gemma / qwen:** `lms ls --llm --json` `sizeBytes` for the two model keys production already
    ///   routes to, cross-checked twice - against the on-disk byte sum of each model directory and
    ///   against the publisher's file sizes on Hugging Face. All three agree to within 0.001%.
    ///
    /// These are a shipped baseline, not a live reading: a later pip resolve pulls whatever versions
    /// exist then. `SizeCatalog` is therefore injectable, so a link that wants to measure at runtime
    /// can supply the same shape without touching the picker, and `--component-picker-selftest` pins
    /// the baseline so a change to it is deliberate.
    struct SizeCatalog: Equatable {
        /// nil means "not measurable here", never zero. See `lmStudio` below.
        var transcriptionEngine: UInt64?
        var voiceModel: UInt64?
        var webSearch: UInt64?
        var gemma: UInt64?
        var qwen: UInt64?
        /// **Deliberately nil.** The LM Studio DMG's size cannot be known until its URL is resolved,
        /// and resolving that URL is open item O4, which belongs to the LM Studio link, not to this
        /// one. A picker that filled this in with a guess would be doing the exact thing O1 forbids,
        /// so the row and the total say "plus LM Studio" instead of quoting a number nobody measured.
        var lmStudio: UInt64?

        static let measured = SizeCatalog(
            // Re-measured 2026-08-29 after B20's torch cut landed. The with-torch closure was
            // 242_159_990 bytes across 35 wheels - reproduced to the byte on that date, independently
            // of L5 - and the torch-free closure is 121_077_755 across 28. Both sums are every
            // wheel's Content-Length from a real pip resolve on the app's own bundled interpreter.
            transcriptionEngine: 121_077_755,
            voiceModel: 1_613_979_758,
            webSearch: 14_028_533,
            gemma: 6_861_935_454,
            qwen: 17_190_793_452,
            lmStudio: nil)
    }

    /// The bundled runtime's footprint INSIDE the app, measured from the staged bundle on 2026-08-27.
    /// It is quoted on the disclosure row and is deliberately not part of any download total.
    static let bundledPythonInAppBytes: UInt64 = 82_663_004

    // MARK: - Rows

    enum RowID: String, CaseIterable {
        case pythonRuntime
        case transcriptionEngine
        case voiceModel
        case webSearch
        case lmStudio
        case gemma
        case qwen

        /// B2's core versus B4's tick rows. The split is a property of the row, so a core row cannot
        /// acquire a checkbox by being rendered in the wrong loop.
        var isCore: Bool {
            switch self {
            case .pythonRuntime, .transcriptionEngine, .voiceModel, .webSearch: return true
            case .lmStudio, .gemma, .qwen: return false
            }
        }

        /// The LM Studio model this row installs, if it is a model row. `lms get` takes these
        /// identifiers unchanged; they are the same ones production already routes to.
        var modelID: String? {
            switch self {
            case .gemma: return LLMProviderDefaults.localEmailModelID
            case .qwen: return LLMProviderDefaults.localCleanupModelID
            default: return nil
            }
        }
    }

    /// Whether a model can run on THIS Mac, decided by the same arithmetic the loader uses.
    ///
    /// **This is the O2 resolution and it is not cosmetic.** B5's table keyed the three tiers to
    /// installed RAM - 8 / 16 / 32 GB - as an admitted starting point, and O2 says to adjust the
    /// boundaries if the measured footprints disagree. They disagree badly, in the direction that
    /// costs a user an 18 GB download for nothing:
    ///
    /// `ModelManager.prepareCapacity` refuses a cold load unless
    /// `wired + size * 1.15 <= budget`, where the budget is the memory-budget slider's fraction of
    /// `vm.global_user_wire_limit` - about 60% of a ceiling that is itself about 82% of installed RAM
    /// at the shipped default. So the real question is never "how much RAM is fitted", it is "does
    /// this model clear the bar the loader will hold it to". Keyed to RAM, B5's table would pre-tick
    /// qwen on a 32 GB Mac whose model budget is about 15.8 GB against a measured 17.19 GB model, and
    /// pre-tick gemma on a 16 GB Mac that cannot hold it either. Both are the precise failure B5
    /// exists to prevent: a checkbox whose stated consequence is not the consequence on that machine.
    ///
    /// The three tiers and their strings are kept exactly as B5 wrote them; only what decides between
    /// them changed, from a table to the machine's own kernel facts:
    ///
    /// - `tooLarge` - it does not fit even at the budget slider's ceiling. Disabled, because no
    ///   setting the user can reach makes this work.
    /// - `tightFit` - it fits at the ceiling, but not at the shipped budget with the machine as it
    ///   stands right now. Offered, unticked, with the consequence stated.
    /// - `fits` - it clears the bar as the machine stands. Pre-ticked.
    /// - `memoryUnknown` - a kernel fact was unreadable. NOT a fourth tier and NOT a warning about the
    ///   model: the app could not measure, which is a different sentence from either verdict, and it
    ///   fails toward offering the row unticked rather than pre-ticking on an unmeasured machine.
    enum Availability: Equatable {
        case fits
        case tightFit
        case tooLarge
        case memoryUnknown

        var isSelectable: Bool { self != .tooLarge }
        var isPreTicked: Bool { self == .fits }
    }

    /// How a third-party row is to be installed (B4). Ben's explicit ruling was that every row
    /// involving a third-party install offers both, rather than the app detecting and linking out.
    ///
    /// `myself` is a real choice and not a synonym for "off": the user wants the feature and has said
    /// the app should not fetch it, so it contributes nothing to the download total and produces no
    /// queue entry, while the row stays ticked so the choice is visible on screen.
    enum InstallChoice: String, Equatable, CaseIterable {
        case forMe
        case myself

        var title: String {
            switch self {
            case .forMe: return "Install it for me"
            case .myself: return "I'll install it myself"
            }
        }
    }

    enum RowState: Equatable {
        /// B3's disclosure row. Ships inside the .app; there is nothing to choose and nothing to fetch.
        case bundled
        /// B2's mandatory core. No tick, by construction.
        case included
        /// Already on this Mac. Nothing to download, and nothing to decide.
        case alreadyInstalled
        /// B4's tick row.
        case optional(ticked: Bool, choice: InstallChoice, availability: Availability)

        var isTicked: Bool {
            if case .optional(let ticked, _, _) = self { return ticked }
            return false
        }

        /// The row's own state word. A word rather than a colour alone, for the reason every other
        /// surface in this app has one: a screenshot in a bug report has to be readable without hue.
        var statusText: String {
            switch self {
            case .bundled: return "INCLUDED"
            case .included: return "REQUIRED"
            case .alreadyInstalled: return "INSTALLED"
            case .optional(let ticked, _, let availability):
                if availability == .tooLarge { return "TOO BIG" }
                return ticked ? "SELECTED" : "OPTIONAL"
            }
        }
    }

    /// One row, fully resolved: what it is, what it costs, what happens if it is left off, and what
    /// this machine can do with it. The view renders this and decides nothing.
    struct Row: Equatable {
        let id: RowID
        let title: String
        let detail: String
        /// What the user gives up by leaving it off (B4). Core rows have none; there is nothing to give up.
        let consequence: String?
        /// nil is "not measured", never zero. Only the LM Studio row is nil today (O4).
        let downloadBytes: UInt64?
        let state: RowState
        /// The one line that names this machine's own verdict, when there is one to name.
        let machineNote: String?

        /// Whether this row's bytes belong in the running total (B6).
        var countsTowardTotal: Bool {
            switch state {
            case .bundled, .alreadyInstalled: return false
            case .included: return true
            case .optional(let ticked, let choice, _): return ticked && choice == .forMe
            }
        }
    }

    // MARK: - What the machine says

    /// The measured facts the picker reasons from. All optional for the reason `SystemMemory` made
    /// them optional: an unreadable kernel ceiling must stay unreadable rather than fall back to
    /// `hw.memsize`, which would hand models the memory macOS reserves and can never lend out.
    struct MachineFacts: Equatable {
        var physicalBytes: UInt64?
        /// The model budget at the slider position in force. On first launch that is the shipped default.
        var budgetBytes: UInt64?
        /// The model budget at the slider's ceiling: the most memory this Mac could ever be told to
        /// give a model. `tooLarge` is measured against this, so "disabled" means genuinely impossible
        /// here rather than "not at today's setting".
        var maxBudgetBytes: UInt64?
        var wiredBytes: UInt64?

        static var live: MachineFacts {
            MachineFacts(
                physicalBytes: SystemMemory.physicalBytes,
                budgetBytes: SystemMemory.budgetBytes(
                    forSliderPosition: Settings.modelMemoryBudgetSliderPosition),
                maxBudgetBytes: SystemMemory.budgetBytes(
                    forSliderPosition: Settings.modelMemoryBudgetSliderRange.upperBound),
                wiredBytes: SystemMemory.wiredBytes)
        }
    }

    /// What is already on this Mac. Measured elsewhere and injected, so the picker owns no detection
    /// of its own: `lmStudioInstalled` is `ModelResidency.isInstalled`, and `installedModelIDs` comes
    /// from the same `lms` catalog the router already reads.
    struct Environment: Equatable {
        var lmStudioInstalled: Bool
        var installedModelIDs: Set<String>

        init(lmStudioInstalled: Bool = false, installedModelIDs: Set<String> = []) {
            self.lmStudioInstalled = lmStudioInstalled
            self.installedModelIDs = installedModelIDs
        }
    }

    /// The user's choices. Core rows are absent by construction - there is nothing to store for them.
    struct Selection: Equatable {
        var lmStudio: Bool
        var gemma: Bool
        var qwen: Bool
        var lmStudioChoice: InstallChoice
        var gemmaChoice: InstallChoice
        var qwenChoice: InstallChoice

        init(lmStudio: Bool = false, gemma: Bool = false, qwen: Bool = false,
             lmStudioChoice: InstallChoice = .forMe,
             gemmaChoice: InstallChoice = .forMe,
             qwenChoice: InstallChoice = .forMe) {
            self.lmStudio = lmStudio
            self.gemma = gemma
            self.qwen = qwen
            self.lmStudioChoice = lmStudioChoice
            self.gemmaChoice = gemmaChoice
            self.qwenChoice = qwenChoice
        }

        func isTicked(_ id: RowID) -> Bool {
            switch id {
            case .lmStudio: return lmStudio
            case .gemma: return gemma
            case .qwen: return qwen
            default: return false
            }
        }

        func choice(_ id: RowID) -> InstallChoice {
            switch id {
            case .lmStudio: return lmStudioChoice
            case .gemma: return gemmaChoice
            case .qwen: return qwenChoice
            default: return .forMe
            }
        }

        mutating func setTicked(_ id: RowID, _ value: Bool) {
            switch id {
            case .lmStudio: lmStudio = value
            case .gemma: gemma = value
            case .qwen: qwen = value
            default: break
            }
        }

        mutating func setChoice(_ id: RowID, _ value: InstallChoice) {
            switch id {
            case .lmStudio: lmStudioChoice = value
            case .gemma: gemmaChoice = value
            case .qwen: qwenChoice = value
            default: break
            }
        }
    }

    /// The pre-ticked state B5 asks for, computed from this machine rather than assumed.
    static func defaultSelection(facts: MachineFacts, environment: Environment,
                                 sizes: SizeCatalog = .measured) -> Selection {
        var selection = Selection()
        for id in [RowID.gemma, RowID.qwen] where !isInstalled(id, environment: environment) {
            selection.setTicked(id, availability(id, facts: facts, sizes: sizes).isPreTicked)
        }
        return selection
    }

    // MARK: - Availability

    static func availability(_ id: RowID, facts: MachineFacts,
                             sizes: SizeCatalog = .measured) -> Availability {
        guard let modelBytes = bytes(for: id, sizes: sizes), id.modelID != nil else { return .fits }
        guard let budget = facts.budgetBytes,
              let maxBudget = facts.maxBudgetBytes,
              let wired = facts.wiredBytes else { return .memoryUnknown }
        guard let signed = Int64(exactly: modelBytes),
              let incoming = ModelManager.estimatedIncomingBytes(sizeBytes: signed)
        else { return .memoryUnknown }
        // The loader's own predicate, called rather than reimplemented. `tooLarge` asks it against an
        // idle machine at the budget ceiling, which is the only honest basis for disabling a row: it
        // means no setting the user can reach makes this model loadable here.
        if !ModelManager.fits(wiredBytes: 0, incomingBytes: incoming, budgetBytes: maxBudget) {
            return .tooLarge
        }
        if !ModelManager.fits(wiredBytes: wired, incomingBytes: incoming, budgetBytes: budget) {
            return .tightFit
        }
        return .fits
    }

    // MARK: - Row construction

    static func rows(selection: Selection, facts: MachineFacts, environment: Environment,
                     sizes: SizeCatalog = .measured) -> [Row] {
        RowID.allCases.map { row($0, selection: selection, facts: facts,
                                 environment: environment, sizes: sizes) }
    }

    static func row(_ id: RowID, selection: Selection, facts: MachineFacts,
                    environment: Environment, sizes: SizeCatalog = .measured) -> Row {
        Row(id: id,
            title: title(id),
            detail: detail(id, installed: isInstalled(id, environment: environment)),
            // A row that is already on the Mac has no "without it" to state: the user cannot incur it,
            // and printing it anyway is the surface telling someone what they would lose by not having
            // the thing they have.
            consequence: isInstalled(id, environment: environment) ? nil : consequence(id),
            downloadBytes: bytes(for: id, sizes: sizes),
            state: state(id, selection: selection, facts: facts, environment: environment,
                         sizes: sizes),
            machineNote: machineNote(id, facts: facts, environment: environment,
                                     selection: selection, sizes: sizes))
    }

    private static func state(_ id: RowID, selection: Selection, facts: MachineFacts,
                              environment: Environment, sizes: SizeCatalog) -> RowState {
        switch id {
        case .pythonRuntime: return .bundled
        case .transcriptionEngine, .voiceModel, .webSearch: return .included
        case .lmStudio, .gemma, .qwen:
            if isInstalled(id, environment: environment) { return .alreadyInstalled }
            let availability = availability(id, facts: facts, sizes: sizes)
            let ticked = availability.isSelectable
                && (selection.isTicked(id) || (id == .lmStudio && needsLMStudio(selection,
                                                                               environment: environment)))
            return .optional(ticked: ticked, choice: selection.choice(id), availability: availability)
        }
    }

    /// Whether a model row has forced LM Studio on. Ticking a model implies its runtime: the
    /// alternative is a queue that downloads a 6.9 GB model with nothing to load it into, and a user
    /// who has to work out the dependency for themselves.
    static func needsLMStudio(_ selection: Selection, environment: Environment) -> Bool {
        guard !environment.lmStudioInstalled else { return false }
        return (selection.gemma && !environment.installedModelIDs.contains(RowID.gemma.modelID ?? ""))
            || (selection.qwen && !environment.installedModelIDs.contains(RowID.qwen.modelID ?? ""))
    }

    static func isInstalled(_ id: RowID, environment: Environment) -> Bool {
        switch id {
        case .lmStudio: return environment.lmStudioInstalled
        case .gemma, .qwen:
            guard let modelID = id.modelID else { return false }
            return environment.installedModelIDs.contains(modelID)
        default: return false
        }
    }

    static func bytes(for id: RowID, sizes: SizeCatalog = .measured) -> UInt64? {
        switch id {
        case .pythonRuntime: return nil
        case .transcriptionEngine: return sizes.transcriptionEngine
        case .voiceModel: return sizes.voiceModel
        case .webSearch: return sizes.webSearch
        case .lmStudio: return sizes.lmStudio
        case .gemma: return sizes.gemma
        case .qwen: return sizes.qwen
        }
    }

    // MARK: - The running total (B6)

    /// The sum of everything that will actually be fetched, plus the names of any rows whose size is
    /// not known. Summed in BYTES and formatted once, so the line can never be the sum of rounded
    /// numbers.
    struct Total: Equatable {
        var bytes: UInt64
        /// Rows that will be downloaded but whose size nobody has measured. Named rather than dropped:
        /// silently omitting one would understate the total, which is the one direction this line must
        /// never be wrong in.
        var unmeasured: [RowID]
    }

    static func total(_ rows: [Row]) -> Total {
        var bytes: UInt64 = 0
        var unmeasured: [RowID] = []
        for row in rows where row.countsTowardTotal {
            guard let size = row.downloadBytes else {
                unmeasured.append(row.id)
                continue
            }
            let (sum, overflow) = bytes.addingReportingOverflow(size)
            bytes = overflow ? UInt64.max : sum
        }
        return Total(bytes: bytes, unmeasured: unmeasured)
    }

    /// B6's one line above Continue. Names what it could not count instead of hiding it.
    static func totalLine(_ rows: [Row]) -> String {
        let total = total(rows)
        var line = "Total download: \(downloadSize(total.bytes))"
        if !total.unmeasured.isEmpty {
            line += ", plus " + total.unmeasured.map(title).joined(separator: " and ")
        }
        return line
    }

    /// Decimal gigabytes, the unit downloads are always quoted in, delegating to `SystemMemory` above
    /// a gigabyte so there is one spelling of "GB" in the app. Whole megabytes below it, because
    /// "0.1 GB" for a 121 MB download tells the user less than the number they would see anywhere else.
    static func downloadSize(_ bytes: UInt64) -> String {
        guard bytes >= 1_000_000_000 else {
            return "\(Int((Double(bytes) / 1_000_000.0).rounded())) MB"
        }
        return SystemMemory.formatGB(bytes)
    }

    /// What the size column says. A row that fetches nothing says so rather than showing a zero, and
    /// a row whose size nobody has measured says THAT rather than showing a number nobody stands behind.
    static func sizeText(_ row: Row) -> String {
        switch row.state {
        case .bundled, .alreadyInstalled: return "no download"
        case .included, .optional:
            guard let bytes = row.downloadBytes else { return "not counted yet" }
            return downloadSize(bytes)
        }
    }

    /// Installed memory as the user's own Mac reports it. Binary gigabytes here and ONLY here: this is
    /// the number on the About This Mac panel a user would check against, and telling someone with a
    /// 16 GB Mac that they have 17.2 GB would make the sentence read as a different machine's.
    static func installedMemory(_ bytes: UInt64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return "\(Int((Double(bytes) / 1_073_741_824.0).rounded())) GB"
    }

    // MARK: - The plan handed on

    /// What the picker's outcome means to the machinery that executes it.
    ///
    /// It is deliberately split three ways, because three different links own the three mechanisms and
    /// none of them should have to re-derive the user's choices. `components` are the venv rows the
    /// headless installer engine already knows how to run; `lmStudio` and `models` name work whose
    /// mechanism belongs to the LM Studio link. The picker decides WHAT was chosen and nothing about
    /// HOW any of it is fetched - there is no queue, no retry policy, and no progress reporting here.
    struct InstallPlan: Equatable {
        var components: [InstallerComponentDescriptor]
        var lmStudio: Bool
        var models: [String]
    }

    /// The mandatory core is always in the plan (B2), so a caller cannot produce a plan that skips it.
    ///
    /// The core is `BootstrapInstallPlan.mandatoryCore` unchanged: the picker shows the transcription
    /// engine and the voice model as two rows because that is what the user is waiting on and what B7
    /// lists, while the engine installs them as the one descriptor that owns both. Presentation splits
    /// the row; it does not split the work, and this is the only place the two shapes meet.
    static func installPlan(selection: Selection, facts: MachineFacts, environment: Environment,
                            sizes: SizeCatalog = .measured) -> InstallPlan {
        let rows = rows(selection: selection, facts: facts, environment: environment, sizes: sizes)
        var models: [String] = []
        var lmStudio = false
        for row in rows where row.countsTowardTotal && !row.id.isCore {
            if row.id == .lmStudio { lmStudio = true }
            if let modelID = row.id.modelID { models.append(modelID) }
        }
        return InstallPlan(components: BootstrapInstallPlan.mandatoryCore,
                           lmStudio: lmStudio, models: models)
    }

    // MARK: - Copy (O7: the spec's intent, in the spec's voice)

    static let headline = "Welcome to ViddyDictate"

    // Precise rather than sweeping. Your VOICE never leaves this Mac - transcription is entirely local -
    // and that is the claim B16 is built to protect. Dictated TEXT can be sent to Claude or Codex, but
    // only ever by an explicit press, so an absolute "nothing leaves this Mac" would be the first thing
    // on screen and also the first thing that is not quite true.
    static let subtitle =
        "ViddyDictate transcribes what you say on this Mac. Your voice never leaves it. It needs to "
        + "fetch the parts that do the transcribing; everything else below is yours to pick, now or later."

    static let coreHeader = "REQUIRED TO TRANSCRIBE"

    static let optionalHeader = "OPTIONAL"

    /// B2 in one line, so the absence of checkboxes on the core reads as a statement rather than an
    /// oversight.
    static let coreNote =
        "These are what dictation is. They are not optional, so they have no checkbox."

    static let optionalNote =
        "Each of these can be added later, from Settings or the moment you first reach for it."

    static let continueTitle = "Continue"

    static func title(_ id: RowID) -> String {
        switch id {
        case .pythonRuntime: return "Python runtime"
        case .transcriptionEngine: return "Transcription engine"
        case .voiceModel: return "Voice model"
        case .webSearch: return "Web search"
        case .lmStudio: return "LM Studio"
        case .gemma: return "Email model"
        case .qwen: return "Cleanup model"
        }
    }

    static func detail(_ id: RowID, installed: Bool = false) -> String {
        switch id {
        case .pythonRuntime:
            // B3, stated as the spec states it. The point is not reassurance, it is that the objection
            // a cautious user would raise to "install Python on my Mac" does not apply here.
            return "Included in the app. Nothing is added to /usr/local, nothing runs when you log in, "
                + "and deleting ViddyDictate deletes it. It is about "
                + "\(downloadSize(bundledPythonInAppBytes)) of the app you already have."
        case .transcriptionEngine:
            return "The local speech-to-text engine that turns your voice into text."
        case .voiceModel:
            return "whisper-large-v3-turbo, the model that does the listening."
        case .webSearch:
            return "The search helper behind Option+L and Option+G."
        case .lmStudio:
            let base = "The app that runs local models on this Mac. ViddyDictate talks to it over "
                + "your own machine."
            // The installer sentence exists to explain an uncounted row. On a Mac that already has LM
            // Studio there is nothing to fetch and nothing uncounted, so saying it would be describing
            // work that will not happen.
            guard !installed else { return base }
            return "The app that runs local models on this Mac. ViddyDictate installs it from LM "
                + "Studio's own installer and talks to it over your own machine. Its size is read "
                + "from that installer before anything is fetched, so it is not in the total yet."
        case .gemma:
            return "\(LLMProviderDefaults.localEmailModelID), which writes email from a dictated note (Option+M)."
        case .qwen:
            return "\(LLMProviderDefaults.localCleanupModelID), which cleans up dictated text "
                + "(Option+P and the ? slider)."
        }
    }

    /// What is given up by leaving the row off (B4). Written against the fallback ladder the app
    /// already ships, not against an imagined all-or-nothing: a mode whose preferred model is missing
    /// runs on the best local model present, so promising the mode is simply "off" would be wrong.
    static func consequence(_ id: RowID) -> String? {
        switch id {
        case .pythonRuntime, .transcriptionEngine, .voiceModel, .webSearch: return nil
        case .lmStudio:
            return "Without it: email and cleanup modes have nothing to run on, and say so when you "
                + "press their keys."
        case .gemma:
            return "Without it: Option+M runs on the best local model you have, or offers to install "
                + "this one if you have none."
        case .qwen:
            return "Without it: cleanup runs on the best local model you have, and offers this one "
                + "beside the result rather than in front of it."
        }
    }

    /// The sentence that names THIS machine's verdict on a model row. B5's strings, kept.
    static func machineNote(_ id: RowID, facts: MachineFacts, environment: Environment,
                            selection: Selection = .init(),
                            sizes: SizeCatalog = .measured) -> String? {
        // The one row that can turn itself on. Its box is checked and locked, which without a reason on
        // screen reads as a control that is broken rather than one that is already decided.
        if id == .lmStudio, !selection.lmStudio, !isInstalled(id, environment: environment),
           needsLMStudio(selection, environment: environment) {
            return "Required by the models you picked."
        }
        guard id.modelID != nil, !isInstalled(id, environment: environment) else { return nil }
        switch availability(id, facts: facts, sizes: sizes) {
        case .fits:
            return nil
        case .tightFit:
            return "Will run, but slowly, and will squeeze everything else."
        case .tooLarge:
            guard let ram = installedMemory(facts.physicalBytes) else {
                return "This model needs more memory than this Mac can give it."
            }
            return "Your Mac has \(ram) - this model needs more."
        case .memoryUnknown:
            // The same sentence the Local models section already uses for the same unreadable fact, so
            // the app does not grow a second way of saying "macOS did not tell me".
            return "macOS did not report how much memory it lets a process wire, so ViddyDictate "
                + "cannot say whether this model will run here."
        }
    }

    // MARK: - Identity

    /// The addressable parts of the surface, so the offscreen render gate drives the same identifiers
    /// the view builds and a line that silently stopped rendering reds a gate instead of shipping a gap.
    enum Part: String, CaseIterable {
        case status
        case title
        case detail
        case consequence
        case machineNote
        case size
        case tick
        case choice
    }

    static func identifier(_ part: Part, _ id: RowID) -> String {
        "component-picker-\(id.rawValue)-\(part.rawValue)"
    }

    static func cardIdentifier(_ id: RowID) -> String { "component-picker-card-\(id.rawValue)" }

    static let surfaceIdentifier = "component-picker"
    static let headlineIdentifier = "component-picker-headline"
    static let subtitleIdentifier = "component-picker-subtitle"
    static let totalIdentifier = "component-picker-total"
    static let continueIdentifier = "component-picker-continue"
    static let waitForWiFiIdentifier = "component-picker-wait-for-wifi"
    static let setUpLaterIdentifier = "component-picker-set-up-later"
    static let networkNoteIdentifier = "component-picker-network-note"
}
