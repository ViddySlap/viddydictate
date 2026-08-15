import Foundation

/// The logic half of the prompt workstation's Test button (item W2): which sample a test starts from,
/// where the sample on screen came from, and how an outcome is worded.
///
/// **A test is inert by construction, and the construction is this type's absence of reach.** There is
/// no delivery collaborator here — no history recorder, no pasteboard, no note bridge, no undo
/// registration, no bullseye. Landing lives entirely in `OneShotRegistry`'s land closures, which a test
/// never enters: it calls `CustomModeClient.run` directly, exactly as a real take's transform half does,
/// and then draws the answer. The one side effect the shared transform seam would still have had is the
/// explicit-retry lifecycle, which a test disarms (`TextTransformArming.inert`) so it cannot clear a
/// pending Retry the user was about to press.
///
/// It runs the mode's REAL configured provider and model. That is the point: a bench that ran something
/// cheaper would tell the user about a model they are not shipping against.
enum PromptTestBench {
    /// Ceiling for the History default. Measured, not guessed: across the user's last hundred takes the raw
    /// transcript is median 190 characters, p75 476, p90 925, max 2524. 1000 therefore admits a normal
    /// take (well past p90) and excludes a monologue, which is the shape a prompt is usually tuned on.
    /// The free-text field below carries no cap at all, because "build me an email-writer hotkey" means
    /// testing against one specific long dictation the user types out.
    static let historySampleCharacterLimit = 1000

    /// Where the sample currently in the field came from. It is displayed, always: a History default
    /// left sitting in the box from three sessions ago must never read as something the user typed.
    enum SampleSource: Equatable {
        /// Loaded from the History entry recorded at this date, and unedited since.
        case history(Date)
        /// The user's own text — either typed from scratch or edited on top of a History default. An
        /// edited default is "typed", not "history": the bytes are no longer the recorded take.
        case typed
        /// Nothing to run yet.
        case empty
    }

    /// The initial sample: the most recent History entry whose raw transcript fits the cap, walking
    /// BACK through the log until one does. `date` is nil when nothing fits, in which case the field
    /// starts empty rather than showing a truncated entry — a half-transcript would silently change
    /// what the prompt is being judged on.
    struct Seed: Equatable {
        let text: String
        let date: Date?

        static let none = Seed(text: "", date: nil)
    }

    /// `entries` is newest-first, the order `TranscriptionHistory.all()` returns.
    static func seed(from entries: [TranscriptionHistory.Entry]) -> Seed {
        for entry in entries {
            let raw = entry.original
            guard raw.count <= historySampleCharacterLimit,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return Seed(text: raw, date: entry.date)
        }
        return .none
    }

    /// The source the panel reports for `current`, given what was seeded into the field. Byte equality
    /// is the whole test: type over the default and it stops claiming to be the default; undo back to
    /// the default and it truthfully is one again.
    static func source(current: String, seed: Seed) -> SampleSource {
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if let date = seed.date, current == seed.text { return .history(date) }
        return .typed
    }

    /// The one line the panel shows about provenance.
    static func sourceLabel(_ source: SampleSource,
                            dateText: (Date) -> String = defaultDateText) -> String {
        switch source {
        case .history(let date):
            return "Sample: your most recent dictation, \(dateText(date))."
        case .typed:
            return "Sample: text you typed here."
        case .empty:
            return "Sample: empty. Type one below, or load a recent dictation."
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func defaultDateText(_ date: Date) -> String { dateFormatter.string(from: date) }

    /// The descriptor a test executes: the stored mode with the prompt CURRENTLY in the editable
    /// region. Testing the stored bytes instead would make the bench useless for the thing it exists
    /// for — typing a fix and seeing whether it worked. Nothing here writes: `candidate` is a value,
    /// and only Save ever hands bytes to the store.
    static func candidate(_ mode: CustomMode, editedPrompt: String) -> CustomMode {
        var candidate = mode
        candidate.prompt = editedPrompt
        return candidate
    }

    /// A sample worth running: blank input would come back as `.badOutput("empty input")` from the
    /// client, which is a true answer to a question the user did not mean to ask.
    static func isRunnable(_ sample: String) -> Bool {
        !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the panel shows when a run finishes. Failures are NOT reworded here: they are the real
    /// path's own three categories, carrying the same user-facing sentence `OneShotRegistry` toasts
    /// after a failed take, so a bench failure and a live failure read identically.
    enum Outcome: Equatable {
        case output(String)
        case failure(TextTransformRetryDescriptor.Failure)

        /// The status line. On success it restates the inertness, because "it ran and produced text"
        /// is exactly the moment a user wonders where that text went.
        var statusText: String {
            switch self {
            case .output: return "Done. Nothing was saved, pasted, or added to History."
            case .failure(let failure): return failure.userMessage
            }
        }

        /// The result body. A failure leaves it empty rather than putting an error where output goes.
        var resultText: String {
            switch self {
            case .output(let text): return text
            case .failure: return ""
            }
        }
    }

    static func outcome(for result: CleanupClient.Result) -> Outcome {
        if case .ok(let text) = result { return .output(text) }
        // Total over the Result enum: `safeFailure` returns nil only for `.ok`, handled above.
        guard let failure = TextTransformClient.safeFailure(for: result) else { return .output("") }
        return .failure(failure)
    }
}
