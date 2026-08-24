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
            case .budgetSlider, .timerControl: return true
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
