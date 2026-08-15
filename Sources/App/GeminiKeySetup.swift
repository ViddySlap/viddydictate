import Foundation
import Security

/// The Gemini API key section on the Setup tab (L5, spec decision D7): what the user is told,
/// and what happens to a key they paste.
///
/// **D7 - the key is entered IN-APP, not through Terminal.** That is not only slicker, it is more correct:
/// the process that CREATES a keychain item lands on that item's access list, so a key ViddyDictate wrote
/// is read back silently while one `security add-generic-password` wrote makes macOS prompt on every
/// launch. `SecretStore` already documented this; until now nothing but the shipped CLI acted on it.
/// `scripts/set-gemini-key.sh` stays shipped and is named here as the fallback for a terminal or a
/// headless setup.
///
/// This file holds the judgement and the words; `GeminiKeySectionView` draws them. Every message is a pure
/// function of a state or an outcome, and no message-producing function here takes the key as a parameter,
/// so a message CANNOT carry the value it was written about - the never-echo rule is a property of the
/// shapes below rather than a discipline someone has to remember. The one function that does see the value,
/// `save`, returns an outcome that has nowhere to put it.
///
/// It measures nothing. The stored/not-stored state is derived from the SAME `PreflightObservation` the
/// Setup tab's other two surfaces read (`webAnswerKeySource`), so the section and the "Gemini answer key"
/// preflight row one inch below it cannot disagree about whether a key is stored.
enum GeminiKeySetup {

    // MARK: - State (derived, never stored)

    /// Whether a key resolves, and from where. `SecretStore.Source` is carried rather than flattened to a
    /// Boolean because "it is coming from the test override, not the keychain" is a materially different
    /// thing to be told - a user who thinks their key is stored, but whose Option+G dies the moment that
    /// variable is not exported, has been lied to by a green row.
    enum Status: Equatable {
        case stored(SecretStore.Source)
        case notStored

        var isStored: Bool { self != .notStored }
    }

    static func status(_ source: SecretStore.Source?) -> Status {
        source.map(Status.stored) ?? .notStored
    }

    /// The row's own state word, for the same reason the preflight and onboarding rows use one: a
    /// screenshot in a bug report has to be readable without relying on hue.
    static func statusText(_ status: Status) -> String {
        switch status {
        case .stored: return "STORED"
        case .notStored: return "NOT SET"
        }
    }

    /// What the section leads with. Says what is ON or OFF rather than what is stored, because the key is
    /// not the point - Option+G is.
    static func headline(_ status: Status) -> String {
        switch status {
        case .stored(.keychain):
            return "A Gemini API key is stored. Option+G web search is on."
        case .stored(.environment):
            return "A Gemini API key is coming from the test override. Option+G web search is on."
        case .notStored:
            return "Add a Gemini API key to turn on Option+G web search."
        }
    }

    /// Where the key came from, in one line, and never what it is. There is no code path in this file or
    /// its view that can put the value on screen: `SecretStore.read` is not called here at all, and the
    /// status this line is built from carries a source, not a secret.
    static func statusLine(_ status: Status) -> String {
        switch status {
        case .stored(.keychain):
            return "Stored in your login keychain, where only ViddyDictate reads it. It is never shown "
                + "here and never written into a file."
        case .stored(.environment):
            return "Coming from the \(SecretStore.Secret.geminiAPIKey.environmentVariable) environment "
                + "variable, not from your keychain - Option+G stops working in any session that does "
                + "not export it. Paste the key below to store it properly."
        case .notStored:
            return "No key is stored yet, so Option+G reports itself off. Nothing else in ViddyDictate "
                + "is affected."
        }
    }

    // MARK: - Standing copy

    static let header = "GEMINI API KEY FOR OPTION+G WEB SEARCH"

    /// Shown while the tab is still measuring. A section with no reading must not read as a verdict, for the
    /// same reason onboarding has its own checking headline.
    static let checkingHeadline = "Checking for a stored Gemini API key..."

    /// What a key turns on. Named as the feature the user would recognise, because "Gemini API key" means
    /// nothing to someone who just wants to ask a question out loud and hear an answer.
    static let turnsOn =
        "Option+G answers a spoken question using Google's grounded web search, then reads the answer back "
        + "the same way Option+L does. It is the only thing that needs this key, and it is optional: with "
        + "no key stored, Option+G reports itself off and every other mode keeps working."

    /// The instructions. Deliberately not a click-path through the console: consoles get redesigned, and a
    /// stale click-path is worse than a URL plus a sentence. This is also why the line below exists.
    static let instructions =
        "Sign in to your Google account, open https://aistudio.google.com/apikey, and create an API key. "
        + "Copy it, paste it in the field below, and click Save. It goes straight into your login keychain."

    /// The warm one. A first-run user who cannot find a button in someone else's console usually stops
    /// there, and the thing that unsticks them is already open on their Mac. Short on purpose.
    static let agentHelp =
        "Cannot find where to create the key? Take a screenshot of this window, or copy this text, and "
        + "hand it to your own AI assistant - ask it to walk you through it step by step. That is a "
        + "perfectly good way to do this, and it is faster than hunting."

    /// The terminal path stays shipped (D7) and is named here rather than hidden, because a headless setup
    /// has no window to paste into.
    static let fallback =
        "Prefer a terminal, or setting up a Mac you are not sitting at? ./scripts/set-gemini-key.sh does "
        + "the same thing from the command line, and --status or --clear reports or removes the stored key."

    /// Said under the field. A stored key can be replaced by pasting over it or removed outright (L9), so
    /// the field is offered in both states and says which one it is in.
    static func fieldHint(_ status: Status) -> String {
        status.isStored
            ? "Paste a new key here to replace the stored one. Option+G uses it on the next dictation."
            : "Option+G starts working on the next dictation. No restart needed."
    }

    // MARK: - Removing a stored key (L9)

    /// Whether the section offers to delete, which is true for exactly one state: a key resolved FROM THE
    /// KEYCHAIN.
    ///
    /// This is the whole honesty problem of the item, so it is decided here rather than in the view.
    /// `SecretStore` resolves keychain first and the environment override second, so a key that resolved
    /// from the environment means the keychain held NOTHING - a Delete button in that state would delete an
    /// item that does not exist, report success, and leave Option+G working exactly as before. That is a
    /// button that lies. There is also nothing honest it could do instead: a process cannot unset a
    /// variable in the session that launched it, and this app will not pretend otherwise. So that state
    /// gets `environmentNote` instead of a control.
    ///
    /// The reverse case - a keychain key with the override ALSO exported - is not decided here, because
    /// the resolution only reports the winner. It is handled by re-measuring: after the delete the tab
    /// measures again, the override wins the next resolution, and the headline says the key is coming from
    /// the override and Option+G is still on. `deletePrompt` warns about exactly that before the click, so
    /// the outcome cannot surprise anyone.
    static func offersDelete(_ status: Status) -> Bool {
        status == .stored(.keychain)
    }

    static let deleteTitle = "Delete stored key"
    static let deleteConfirmTitle = "Delete"
    static let deleteCancelTitle = "Cancel"

    /// The confirmation. A destructive control that fires on one click is how a working key gets dropped by
    /// a mis-click, so the button asks first and this is what it asks.
    ///
    /// It does NOT promise that Option+G goes off, because that is not always true - the environment
    /// override can still be supplying a key underneath the stored one. Naming the one thing that could
    /// keep it on is cheaper than a promise that is wrong for the one user it is wrong for.
    static let deletePrompt =
        "Remove the stored key from your login keychain? Option+G web search stops working, unless the "
        + "\(SecretStore.Secret.geminiAPIKey.environmentVariable) override is also set - this section "
        + "re-checks the moment it is gone and says which. You can paste a new key in at any time."

    /// Shown INSTEAD of a delete control when the key is coming from the override. See `offersDelete`.
    static let environmentNote =
        "There is nothing stored for ViddyDictate to delete: this key is coming from the "
        + "\(SecretStore.Secret.geminiAPIKey.environmentVariable) environment variable, and no app can "
        + "unset a variable in the session that launched it. Remove it where it is exported, then quit and "
        + "reopen ViddyDictate. Deleting a stored key would not turn Option+G off while that is set."

    /// What a Delete attempt did. Two cases and neither carries a `String`, for the same reason
    /// `SaveOutcome` does not: an outcome that cannot hold a value cannot be the thing that leaks one.
    ///
    /// There is deliberately no "there was nothing there" case. `SecretStore.delete` maps
    /// `errSecItemNotFound` to success because the caller's intent is "make sure this is gone", and the
    /// section only offers the control when a key resolved from the keychain anyway.
    enum DeleteOutcome: Equatable {
        case removed
        case failed(OSStatus)

        enum Kind: String, CaseIterable {
            case removed, failed
        }

        var kind: Kind {
            switch self {
            case .removed: return .removed
            case .failed: return .failed
            }
        }
    }

    /// The keychain delete, as a function. It takes NO parameter, so the delete path cannot be handed the
    /// key even by accident.
    ///
    /// Production is `SecretStore.delete(.geminiAPIKey)` - the SAME `SecItemDelete` that
    /// `./scripts/set-gemini-key.sh --clear` drives through `--clear-gemini-key`. There is one delete in
    /// this app and this is it; the in-app button is a second caller, not a second implementation.
    typealias Deleter = () -> OSStatus

    static func delete(deleter: Deleter = { SecretStore.delete(.geminiAPIKey) }) -> DeleteOutcome {
        let status = deleter()
        guard status == errSecSuccess else {
            Log.write("gemini key: keychain delete failed (OSStatus \(status))")
            return .failed(status)
        }
        Log.write("gemini key: removed from the login keychain")
        return .removed
    }

    static func message(_ outcome: DeleteOutcome) -> String {
        switch outcome {
        case .removed:
            return "Removed the stored key from your login keychain. ViddyDictate re-checked straight "
                + "after, so the state above is what Option+G is actually doing now."
        case .failed(let status):
            return "The key was not removed: \(SecretStore.explain(status)). Nothing changed, so you can "
                + "try again, or use ./scripts/set-gemini-key.sh --clear instead."
        }
    }

    /// A delete that actually removed something changes what the machine would report. A failed one did
    /// not touch anything, so there is nothing new to measure.
    static func requiresRemeasure(_ outcome: DeleteOutcome) -> Bool {
        outcome == .removed
    }

    // MARK: - What the section last did

    /// The section shows at most ONE message, and it is always a pure function of a typed outcome. Holding
    /// the two kinds in one value is what makes that structural: there is one slot, so a stale "Saved."
    /// cannot sit under a fresh "Removed." Neither case can carry a `String`, so this cannot carry the key
    /// either.
    enum Notice: Equatable {
        case saved(SaveOutcome)
        case deleted(DeleteOutcome)
    }

    static func message(_ notice: Notice) -> String {
        switch notice {
        case .saved(let outcome): return message(outcome)
        case .deleted(let outcome): return message(outcome)
        }
    }

    /// Whether the message reads as a success, for the one thing the view does with it: its colour.
    static func isSuccess(_ notice: Notice) -> Bool {
        switch notice {
        case .saved(let outcome): return outcome == .stored
        case .deleted(let outcome): return outcome == .removed
        }
    }

    static func requiresRemeasure(_ notice: Notice) -> Bool {
        switch notice {
        case .saved(let outcome): return requiresRemeasure(outcome)
        case .deleted(let outcome): return requiresRemeasure(outcome)
        }
    }

    // MARK: - Saving

    /// What a Save attempt did. It can carry an OSStatus and nothing else - there is deliberately no case
    /// with a `String` payload, so an outcome cannot be the thing that leaks the key into a message, a log
    /// line, or a crash report.
    enum SaveOutcome: Equatable {
        case stored
        /// The field was empty or whitespace. Nothing was written, and nothing needs undoing.
        case nothingEntered
        case failed(OSStatus)

        /// Discriminator so a gate can assert the shape stays this narrow. A new case here has to be added
        /// deliberately and reds that gate.
        enum Kind: String, CaseIterable {
            case stored, nothingEntered, failed
        }

        var kind: Kind {
            switch self {
            case .stored: return .stored
            case .nothingEntered: return .nothingEntered
            case .failed: return .failed
            }
        }
    }

    /// The keychain write, as a function. Production is `SecretStore.write(.geminiAPIKey, value:)` and there
    /// is no other implementation; this exists so the rail can drive the outcomes, not so a second writer can
    /// be plugged in.
    typealias Writer = (String) -> OSStatus

    /// Store what the user pasted, through the app's ONE keychain writer.
    ///
    /// The writer is injected so the deterministic rail can drive every outcome without a login keychain -
    /// an agent shell cannot write one at all (`errSecInteractionNotAllowed`), and a gate that tried would
    /// report on this machine's session rather than on this policy. Production passes
    /// `SecretStore.write(.geminiAPIKey, value:)`, which performs the real `SecItemUpdate`/`SecItemAdd`;
    /// there is no second keychain path.
    ///
    /// The value is trimmed before it is stored, not just on the way out: a key pasted with a trailing
    /// newline that is stored verbatim arrives at Google as a malformed credential and comes back as an
    /// opaque 400, which reads as "my key is wrong" rather than "my paste had a newline in it".
    ///
    /// Nothing here logs, prints, or passes the value anywhere except to the writer.
    static func save(_ raw: String?,
                     writer: Writer = { SecretStore.write(.geminiAPIKey, value: $0) }) -> SaveOutcome {
        guard let value = SecretStore.normalized(raw) else {
            Log.write("gemini key: nothing entered, nothing written")
            return .nothingEntered
        }
        let status = writer(value)
        guard status == errSecSuccess else {
            // The number, never the value. `explain` maps the statuses a user can actually hit.
            Log.write("gemini key: keychain write failed (OSStatus \(status))")
            return .failed(status)
        }
        Log.write("gemini key: stored in the login keychain")
        return .stored
    }

    /// What to say after a Save. A pure function of the OUTCOME, so it has no access to the value even in
    /// the failure case.
    static func message(_ outcome: SaveOutcome) -> String {
        switch outcome {
        case .stored:
            return "Saved. Option+G web search is on from your next dictation - no restart needed."
        case .nothingEntered:
            return "Nothing was entered, so nothing was written. Paste the key into the field first."
        case .failed(let status):
            return "The key was not stored: \(SecretStore.explain(status)). Nothing changed, so you can "
                + "try again, or use ./scripts/set-gemini-key.sh instead."
        }
    }

    /// Whether the host should re-measure after this outcome. Only a real write changes what the machine
    /// would report, and re-measuring is what keeps the section, the preflight row, and Option+G itself
    /// reading one observation.
    static func requiresRemeasure(_ outcome: SaveOutcome) -> Bool {
        outcome == .stored
    }

    // MARK: - Identity

    /// The addressable parts of the section, so the offscreen probe drives the same identifiers the view
    /// builds and a section that silently stopped rendering its instructions reds a gate instead of
    /// shipping half a message.
    enum Part: String, CaseIterable {
        case status
        case headline
        case statusLine
        case turnsOn
        case instructions
        case agentHelp
        case fallback
        case field
        case save
        case fieldHint
        case delete
        case deletePrompt
        case deleteConfirm
        case deleteCancel
        case environmentNote
        case message

        /// A control rather than a line of text. The layout gate reads text parts to prove nothing is
        /// clipped; controls are fixed-height by design and would red that check for no reason. Kept here
        /// rather than as a list in the gate so a new control cannot be added and forgotten.
        var isControl: Bool {
            switch self {
            case .field, .save, .delete, .deleteConfirm, .deleteCancel: return true
            default: return false
            }
        }
    }

    static func identifier(_ part: Part) -> String { "gemini-key-\(part.rawValue)" }

    static let cardIdentifier = "gemini-key-card"
}
