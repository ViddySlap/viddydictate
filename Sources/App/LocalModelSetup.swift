import Foundation

/// The Local models section on the Setup tab: what the two controls are called, what the numbers under the
/// budget slider actually say, and what ViddyDictate reports about LM Studio's own JIT model timeout.
///
/// This file holds the judgement and the words; `LocalModelsSectionView` draws them. Every line is a pure
/// function of a slider position, a timer value, or a reading, so what the section claims can be asserted
/// without a screenshot - and the one claim a screenshot could not check at all, that the gigabyte line
/// tracks the slider, is a function here rather than a binding someone has to remember to wire.
///
/// Two properties are load-bearing and are enforced by the shapes below rather than by discipline.
///
/// **The slider's own number carries NO percent sign.** Its face is 0...100 but it maps onto 25...90% of the
/// user-wire ceiling, so position 60 is really 64% of that ceiling - a `%` on the level would state
/// something false. `budgetLevelText` returns a bare integer and there is no code path here that can append
/// a unit to it. The gigabyte line is the only quantitative claim on the row.
///
/// **The level and the gigabytes are computed from the SAME integer.** Both renderers run the position
/// through `normalized` first, so a slider resting on 53.6 cannot show "54" above "33.6 GB".
enum LocalModelSetup {

    static let header = "LOCAL MODELS"

    // MARK: - Memory facts, injected

    /// The two kernel facts the budget is built from, carried as a value so the section can be rendered on a
    /// machine whose sysctls are unreadable without reaching for the real ones.
    ///
    /// Both are `Optional` for the reason `SystemMemory` made them optional: an unavailable kernel ceiling
    /// must stay unavailable rather than fall back to `hw.memsize`, which would silently hand models the
    /// 12 GB macOS reserves and can never lend out.
    struct MemoryFacts: Equatable {
        var userWireLimitBytes: UInt64?
        var noUserWireBytes: UInt64?

        static var live: MemoryFacts {
            MemoryFacts(userWireLimitBytes: SystemMemory.userWireLimitBytes,
                        noUserWireBytes: SystemMemory.noUserWireBytes)
        }

        var isAvailable: Bool { userWireLimitBytes != nil }
    }

    // MARK: - The budget slider

    static let budgetTitle = "Model memory budget"

    /// The visible face of the slider. Deliberately the raw 0...100 level and NOT a percentage - see the
    /// type note above.
    static func budgetLevelText(_ position: Double) -> String {
        String(Int(normalized(position)))
    }

    /// The one quantitative line on the row: what this position actually buys, and out of what.
    ///
    /// `SystemMemory` owns both the mapping and the formatter, so this cannot drift from the number the
    /// capacity policy compares against.
    static func budgetLine(position: Double, facts: MemoryFacts) -> String {
        guard let limit = facts.userWireLimitBytes,
              let budget = SystemMemory.budgetBytes(forSliderPosition: normalized(position)) else {
            return "macOS did not report how much memory it lets a process wire, so ViddyDictate cannot "
                + "size a budget. Local models are not loaded until it can read that limit."
        }
        return "\(SystemMemory.formatGB(budget)) of \(SystemMemory.formatGB(limit)) available to local models"
    }

    /// Why the denominator is not the machine's RAM. Omitted rather than guessed when the kernel did not say.
    static func reservedLine(facts: MemoryFacts) -> String? {
        guard facts.isAvailable, let reserved = facts.noUserWireBytes else { return nil }
        return "macOS reserves \(SystemMemory.formatGB(reserved)) that models cannot use."
    }

    /// Slider positions are whole numbers. Every renderer runs the position through this first, so the level
    /// on screen and the gigabytes under it are always computed from one value.
    ///
    /// NaN takes the floor because there is no defensible clamp for "not a number"; everything else,
    /// infinities included, is clamped to the face the way any out-of-range position is.
    static func normalized(_ position: Double) -> Double {
        guard !position.isNaN else { return Settings.modelMemoryBudgetSliderRange.lowerBound }
        return min(Settings.modelMemoryBudgetSliderRange.upperBound,
                   max(Settings.modelMemoryBudgetSliderRange.lowerBound, position.rounded()))
    }

    // MARK: - The live residency readout (LOCKED DECISION 2)

    /// What is loaded right now and how much room is left, directly under the knob that governs it.
    ///
    /// This exists because the budget was correct and silent. On 2026-08-27 the slider was dragged from 54
    /// to 0 with a 17.19 GB model already resident; `ModelManager.prepareCapacity` returns `.alreadyResident`
    /// before any budget check, so the next dictation ran with no refusal and nothing on screen ever said
    /// why. The policy is right - a resident model allocates nothing new, and the kernel-panic risk is at
    /// wire time - so what this section adds is the telling, not a change of mind.
    ///
    /// LOCKED DECISION 2 puts it here rather than on a tab of its own: the only control it explains is the
    /// budget slider, and separating the number from the knob is what made the budget feel like a lie.

    static let residencyTitle = "Loaded now"

    static let unloadAllTitle = "Unload all"

    /// The button's own title while the unload is running. `lms unload --all` is a subprocess and is not
    /// instant, so the control says what it is doing rather than sitting dead for a second.
    static let unloadingTitle = "Unloading..."

    /// The sentence the whole item is for. Ben lost a hand test to its absence: the app knew a lowered
    /// budget would not evict anything and told nobody.
    static let residencyNote =
        "Lowering the budget applies to the next model load. Models already in memory keep running."

    /// What the app currently knows about LM Studio's resident set.
    ///
    /// `pending` and `unavailable` are separate cases for the same reason `JITStatus` separates `unknown`
    /// from the rest: a reading that has not arrived yet, a reading that could not be taken, and a machine
    /// with nothing loaded are three different facts, and only one of them means "nothing is loaded".
    enum Residency: Equatable {
        /// No reading has come back yet. `lms ps` costs about a sixth of a second and is run off the main
        /// thread, so this state is always on screen for a moment rather than being a theoretical one.
        case pending
        /// `lms ps` could not be read: LM Studio is not installed, its server is not up, or the CLI failed.
        case unavailable
        case models([ModelResidency.ResidentModel])
    }

    /// The resident set as one block, biggest first.
    ///
    /// Sorted by footprint rather than by whatever order the CLI happened to print, because the question
    /// this readout answers is "what is holding my memory" and the answer should be on the first line.
    /// Ties break on the identifier so the order cannot flicker between two refreshes of an unchanged set.
    static func residencyList(_ reading: Residency, now: Date) -> String {
        switch reading {
        case .pending:
            return "Reading LM Studio..."
        case .unavailable:
            return "ViddyDictate could not ask LM Studio what is loaded, so it cannot say what is holding "
                + "memory right now. The budget still applies to every load it attempts."
        case .models(let models):
            guard !models.isEmpty else {
                return "Nothing is loaded right now. The budget applies to the next model load."
            }
            let sorted = models.sorted {
                $0.sizeBytes == $1.sizeBytes ? $0.identifier < $1.identifier : $0.sizeBytes > $1.sizeBytes
            }
            let nameWidth = sorted.map(\.identifier.count).max() ?? 0
            return sorted.map { residencyRow($0, nameWidth: nameWidth, now: now) }
                .joined(separator: "\n")
        }
    }

    /// One model: what it is called, what it costs, whether it is working, and whether anything will take
    /// it away on its own.
    ///
    /// Padded to the widest name in THIS set rather than to a constant, so the columns line up without a
    /// cap that could truncate the one part of the row that identifies the model. A set holding an unusually
    /// long identifier wraps instead of hiding it.
    static func residencyRow(_ model: ModelResidency.ResidentModel, nameWidth: Int,
                             now: Date) -> String {
        let name = model.identifier.padding(toLength: max(nameWidth, model.identifier.count),
                                            withPad: " ", startingAt: 0)
        let size = SystemMemory.formatGB(model.sizeBytes)
        let padded = String(repeating: " ", count: max(0, 8 - size.count)) + size
        let state = (model.isIdle ? "idle" : "busy").padding(toLength: 4, withPad: " ", startingAt: 0)
        return "\(name)  \(padded)  \(state)  \(residencyTTL(model, now: now))"
    }

    /// How long LM Studio will keep this model without further use.
    ///
    /// LM Studio's TTL is idle-based, so it is measured from the model's last use rather than from its
    /// load. A model with no TTL is the state that pinned 28.7 GB for an hour on 2026-08-21 and is said
    /// plainly rather than left blank.
    static func residencyTTL(_ model: ModelResidency.ResidentModel, now: Date) -> String {
        guard let ttl = model.ttlSeconds else { return "no timeout" }
        guard let lastUsedTime = model.lastUsedTime else { return "unload time unavailable" }
        let lastUsed = Date(timeIntervalSince1970: Double(lastUsedTime) / 1000.0)
        // Clamped to the TTL itself: a `lastUsedTime` in the future (clock skew, or a machine that just
        // moved timezone) must not be able to promise more time than LM Studio ever granted.
        let remaining = min(Double(ttl), Double(ttl) - now.timeIntervalSince(lastUsed))
        if remaining <= 0 { return "due to unload" }
        if remaining < 60 { return "unloads in under a minute" }
        return "unloads in \(Int((remaining / 60).rounded(.up))) min"
    }

    /// What the machine is currently spending against the budget the slider just set.
    ///
    /// The numerator is whole-machine WIRED memory, not the sum of the rows above, and that is deliberate:
    /// it is the exact quantity `ModelManager` compares against the budget before a cold load, so this line
    /// and a capacity refusal can never disagree. The card's own purpose copy states the rule this rests on
    /// - the budget counts everything on the Mac holding wired memory, not just ViddyDictate's models - so
    /// a total larger than the listed models is the truth rather than an arithmetic error.
    ///
    /// Omitted rather than guessed when the kernel ceiling is unreadable, exactly like `reservedLine`:
    /// `budgetLine` has already said there is no budget, and a lone "in use" figure against nothing would
    /// be the second half of a sentence whose first half does not exist.
    static func residencySummary(position: Double, facts: MemoryFacts, wiredBytes: UInt64?) -> String? {
        guard facts.isAvailable,
              let wired = wiredBytes,
              let budget = SystemMemory.budgetBytes(forSliderPosition: normalized(position))
        else { return nil }
        return "\(SystemMemory.formatGB(wired)) of \(SystemMemory.formatGB(budget)) budget in use"
    }

    /// Whether what is in use has already passed the budget the handle is set to.
    ///
    /// This is exactly the state Ben was in at 07:40 on 2026-08-27 and could not see: a 17.19 GB model
    /// resident, the slider dragged down to 14.1 GB, and nothing anywhere saying the machine was over.
    /// It is NOT a refusal and NOT an error - a resident model allocates nothing new, which is why the
    /// policy correctly let the dictation run - so this earns the card's existing "needs attention"
    /// orange, the same one the LM Studio row and the unreadable-ceiling line already use, and nothing
    /// stronger.
    static func residencyOverBudget(position: Double, facts: MemoryFacts, wiredBytes: UInt64?) -> Bool {
        guard facts.isAvailable,
              let wired = wiredBytes,
              let budget = SystemMemory.budgetBytes(forSliderPosition: normalized(position))
        else { return false }
        return wired > budget
    }

    /// Whether the block is COLUMNS or a SENTENCE. The rows are padded to a common width and only line up
    /// in a monospaced face; the pending, unreadable and empty states are ordinary prose and read as a code
    /// dump in one. The view asks this rather than deciding for itself, so the padding and the font that
    /// makes the padding mean anything stay one decision.
    static func residencyIsTabular(_ reading: Residency) -> Bool {
        guard case .models(let models) = reading else { return false }
        return !models.isEmpty
    }

    /// Whether Unload all has anything to act on. A button that cannot change the machine is disabled
    /// rather than hidden, so the section does not change shape between two refreshes.
    static func canUnloadAll(_ reading: Residency) -> Bool {
        guard case .models(let models) = reading else { return false }
        return !models.isEmpty
    }

    // MARK: - The idle-unload timer

    static let timerTitle = "Unload idle models after"

    /// The choices offered, in minutes. Discrete rather than a second slider: the exact number of seconds
    /// does not matter, and a fixed menu makes the setting readable at a glance in a screenshot.
    static let timerChoicesMinutes = [1, 2, 5, 10, 15, 30, 60]

    static let timerHint =
        "ViddyDictate asks LM Studio to drop a model it loaded once it has gone this long unused. It applies "
        + "to every model ViddyDictate loads, and never to one another app loaded."

    // MARK: - LM Studio's own JIT model timeout (LOCKED DECISION 4)

    /// What `~/.lmstudio/settings.json` says about `developer.jitModelTTL`. Read only, always: LM Studio
    /// holds this file in memory and rewrites it, so a write from here is clobbered on its next save. That
    /// makes writing it unreliable BY CONSTRUCTION, not merely impolite, which is why this is a report
    /// rather than a control.
    struct JITSettings: Equatable {
        var ttlSeconds: Int?
        var enabled: Bool?
    }

    /// The reading, injected. Production is `readJITSettings`; the offscreen render gate passes each state
    /// directly, because the file on the machine running the gate says whatever it happens to say.
    typealias JITReader = () -> JITSettings?

    static var jitSettingsPath: String { "\(NSHomeDirectory())/.lmstudio/settings.json" }

    /// Read the JIT timeout out of LM Studio's settings file. `nil` means "could not read it", which is a
    /// materially different answer from "it is fine" and is reported as such.
    ///
    /// Nothing in this file opens that path for writing. There is no writer here to call.
    static func readJITSettings(path: String = jitSettingsPath) -> JITSettings? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let developer = root["developer"] as? [String: Any],
              let jit = developer["jitModelTTL"] as? [String: Any] else { return nil }
        let seconds = (jit["ttlSeconds"] as? NSNumber).map { $0.intValue }
        let enabled = (jit["enabled"] as? NSNumber).map { $0.boolValue }
        guard seconds != nil || enabled != nil else { return nil }
        return JITSettings(ttlSeconds: seconds, enabled: enabled)
    }

    /// What the reading means, measured against ViddyDictate's own idle timer.
    ///
    /// "Fine" and "could not read it" are separate cases on purpose: an unreadable file must not render as a
    /// warning about a number nobody has, and it must not render as an all-clear either.
    enum JITStatus: Equatable {
        /// LM Studio drops JIT-loaded models at least as promptly as ViddyDictate drops its own.
        case matched(ttlSeconds: Int)
        /// LM Studio holds them longer than ViddyDictate does. This is the state that pinned 28.7 GB for an
        /// hour on 2026-08-21.
        case tooLong(ttlSeconds: Int, appSeconds: Int)
        /// The timeout is switched off, so nothing unloads a JIT-loaded model on a clock at all.
        case noTimeout(appSeconds: Int)
        /// The file was missing, unreadable, or carried no timeout.
        case unknown
    }

    static func jitStatus(_ settings: JITSettings?, appIdleSeconds: Int) -> JITStatus {
        guard let settings = settings else { return .unknown }
        if settings.enabled == false { return .noTimeout(appSeconds: appIdleSeconds) }
        guard let ttl = settings.ttlSeconds, ttl > 0 else { return .unknown }
        return ttl > appIdleSeconds
            ? .tooLong(ttlSeconds: ttl, appSeconds: appIdleSeconds)
            : .matched(ttlSeconds: ttl)
    }

    /// Whether the row reads as something to act on. `unknown` is deliberately NOT a warning: the app could
    /// not read a file, which is not evidence that anything is wrong.
    static func jitNeedsAttention(_ status: JITStatus) -> Bool {
        switch status {
        case .tooLong, .noTimeout: return true
        case .matched, .unknown: return false
        }
    }

    static let jitTitle = "LM Studio JIT model timeout"

    /// The row's own state word, for the same reason every other row on this tab has one: a screenshot in a
    /// bug report has to be readable without relying on hue.
    static func jitStatusText(_ status: JITStatus) -> String {
        switch status {
        case .matched: return "OK"
        case .tooLong, .noTimeout: return "REVIEW"
        case .unknown: return "NOT READ"
        }
    }

    static func jitSummary(_ status: JITStatus) -> String {
        switch status {
        case .matched(let ttl):
            return "LM Studio holds JIT-loaded models for \(duration(ttl)), no longer than ViddyDictate "
                + "holds its own."
        case .tooLong(let ttl, let app):
            return "LM Studio holds JIT-loaded models for \(duration(ttl)); recommended \(duration(app))."
        case .noTimeout:
            return "LM Studio's JIT model timeout is switched off, so a model it loads stays in memory "
                + "until something unloads it."
        case .unknown:
            return "ViddyDictate could not read LM Studio's settings, so it does not know how long "
                + "LM Studio holds models that other apps load."
        }
    }

    /// The one line of instruction. Present only where there is something to change.
    static func jitRemedy(_ status: JITStatus) -> String? {
        switch status {
        case .matched:
            return nil
        case .tooLong(_, let app):
            return "Fix: in LM Studio, open Settings > Developer and set the JIT model TTL to "
                + "\(duration(app)). ViddyDictate does not change that file itself - LM Studio keeps it in "
                + "memory and would overwrite the change on its next save."
        case .noTimeout(let app):
            return "Fix: in LM Studio, open Settings > Developer, switch the JIT model TTL on, and set it "
                + "to \(duration(app)). ViddyDictate does not change that file itself - LM Studio keeps it "
                + "in memory and would overwrite the change on its next save."
        case .unknown:
            return "If local models start being refused for memory, check that the JIT model TTL under "
                + "Settings > Developer in LM Studio is no longer than ViddyDictate's own timer above."
        }
    }

    /// What it costs while it stays this way. Only the two states that cost anything have one.
    static func jitConsequence(_ status: JITStatus) -> String? {
        switch status {
        case .matched, .unknown:
            return nil
        case .tooLong, .noTimeout:
            return "A model another app loaded counts against the budget above for as long as LM Studio "
                + "keeps it, and ViddyDictate never unloads a model it did not load."
        }
    }

    /// Seconds as the unit a person set them in. Minutes wherever they divide, because that is how this
    /// timeout is entered in both apps.
    static func duration(_ seconds: Int) -> String {
        guard seconds >= 60, seconds % 60 == 0 else { return "\(seconds) sec" }
        return "\(seconds / 60) min"
    }

    // MARK: - Identity

    /// The addressable parts of the section, so the offscreen render gate drives the same identifiers the
    /// view builds and a line that silently stopped rendering reds a gate instead of shipping a gap.
    enum Part: String, CaseIterable {
        case headline
        case purpose
        case budgetTitle
        case budgetSlider
        case budgetLevel
        case budgetLine
        case reservedLine
        case residencyTitle
        case residencyList
        case residencySummary
        case residencyNote
        case unloadAll
        case timerTitle
        case timerControl
        case timerHint
        case jitStatus
        case jitTitle
        case jitSummary
        case jitRemedy
        case jitConsequence

        /// A control rather than a line of text. The layout gate reads text parts to prove nothing is
        /// clipped; controls are fixed-height by design and would red that check for no reason.
        var isControl: Bool {
            switch self {
            case .budgetSlider, .timerControl, .unloadAll: return true
            default: return false
            }
        }
    }

    static func identifier(_ part: Part) -> String { "local-models-\(part.rawValue)" }

    /// The section view itself, so a capture gate can photograph both cards as one image rather than
    /// stitching two.
    static let sectionIdentifier = "local-models-section"
    static let cardIdentifier = "local-models-card"
    static let jitCardIdentifier = "local-models-jit-card"

    // MARK: - Standing copy

    static let headline = "Local models run in LM Studio, on this Mac."

    static let purpose =
        "ViddyDictate refuses to load a model when doing so would push the machine past the budget below, "
        + "and says so rather than crashing. The budget counts everything on the Mac holding wired memory, "
        + "not just ViddyDictate's own models."
}
