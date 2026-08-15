import Foundation
import Security

/// Characterizes the Gemini API key section's copy and its save policy (L5, spec decision D7).
///
/// Deliberately touches NO real keychain. The write is driven through `GeminiKeySetup.save`'s injected
/// writer, so every outcome - stored, nothing entered, and a real OSStatus failure - is reachable on the
/// offline rail. An agent shell cannot write the login keychain at all (`errSecInteractionNotAllowed`), and a
/// gate that tried would go green or red on which session it ran in rather than on this policy. The live
/// write is a hand-test step, and the app itself is the writer by construction (D7's whole rationale).
///
/// The assertion that matters most here is the never-echo one, and it is made against a canary: a synthetic
/// key value is driven through the whole save path, and then the outcome, its message, its debug description,
/// and the app log are all checked for it. That is what makes "the key is never echoed or logged" a measured
/// fact rather than a claim about the code someone read once.
enum GeminiKeySetupSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate Gemini key setup - selftest ===")
        let reporter = SelfTestReporter()

        checkStatusDerivation(reporter)
        checkCopy(reporter)
        checkSavePolicy(reporter)
        checkDeletePolicy(reporter)
        checkNeverEchoed(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "gemini key setup"))
        return reporter.passed
    }

    /// Every string the section can put on screen, so a sweep can assert a property of all of them at once.
    private static var allCopy: [String] {
        [GeminiKeySetup.header, GeminiKeySetup.checkingHeadline, GeminiKeySetup.turnsOn,
         GeminiKeySetup.instructions, GeminiKeySetup.agentHelp, GeminiKeySetup.fallback,
         GeminiKeySetup.deleteTitle, GeminiKeySetup.deleteConfirmTitle, GeminiKeySetup.deleteCancelTitle,
         GeminiKeySetup.deletePrompt, GeminiKeySetup.environmentNote]
            + statuses.map(GeminiKeySetup.headline)
            + statuses.map(GeminiKeySetup.statusLine)
            + statuses.map(GeminiKeySetup.statusText)
            + statuses.map(GeminiKeySetup.fieldHint)
            + notices.map(GeminiKeySetup.message)
    }

    private static var statuses: [GeminiKeySetup.Status] {
        [.stored(.keychain), .stored(.environment), .notStored]
    }

    private static var outcomes: [GeminiKeySetup.SaveOutcome] {
        [.stored, .nothingEntered, .failed(errSecUserCanceled)]
    }

    private static var deleteOutcomes: [GeminiKeySetup.DeleteOutcome] {
        [.removed, .failed(errSecUserCanceled)]
    }

    /// Every message the section can show, of either kind, so the never-echo sweep covers the delete path
    /// as well as the save path rather than leaving a new path uncovered.
    private static var notices: [GeminiKeySetup.Notice] {
        outcomes.map(GeminiKeySetup.Notice.saved) + deleteOutcomes.map(GeminiKeySetup.Notice.deleted)
    }

    // MARK: - State comes from the tab's one observation

    private static func checkStatusDerivation(_ check: SelfTestReporter) {
        print("--- stored state is derived from the preflight observation ---")

        check("a keychain-resolved key reads as stored from the keychain",
              GeminiKeySetup.status(.keychain) == .stored(.keychain))
        check("an override-resolved key reads as stored from the environment",
              GeminiKeySetup.status(.environment) == .stored(.environment))
        check("no resolution reads as not stored", GeminiKeySetup.status(nil) == .notStored)
        check("only a resolved key counts as stored",
              GeminiKeySetup.Status.stored(.keychain).isStored
                && GeminiKeySetup.Status.stored(.environment).isStored
                && !GeminiKeySetup.Status.notStored.isStored)

        // The section and the preflight row read the SAME field, so they cannot disagree. Asserted through
        // an observation rather than by inspection, because that is the actual coupling.
        var observation = PreflightSelfTest.broken
        observation.webAnswerKeySource = .keychain
        let stored = Preflight.evaluate(observation).finding(.webAnswerKey)
        check("a stored key leaves the preflight key row green and the section reading stored",
              stored?.isWarning == false
                && GeminiKeySetup.status(observation.webAnswerKeySource).isStored)
        observation.webAnswerKeySource = nil
        let missing = Preflight.evaluate(observation).finding(.webAnswerKey)
        check("an absent key warns in the preflight row and reads as not stored in the section",
              missing?.isWarning == true
                && GeminiKeySetup.status(observation.webAnswerKeySource) == .notStored)
    }

    // MARK: - Required section wording

    private static func checkCopy(_ check: SelfTestReporter) {
        print("--- the section's copy ---")

        // The one thing a user cannot guess and cannot be sent hunting for.
        check("the instructions carry the console URL",
              GeminiKeySetup.instructions.contains("https://aistudio.google.com/apikey"))
        check("the instructions say to paste it and save, rather than describing a click-path",
              GeminiKeySetup.instructions.lowercased().contains("paste")
                && GeminiKeySetup.instructions.contains("Save"))

        // The warm line. It exists to stop a user who cannot find a button in someone else's console, so it
        // has to name both ways of handing this window to an assistant.
        let help = GeminiKeySetup.agentHelp.lowercased()
        check("the warm line offers a screenshot and a copy of this window",
              help.contains("screenshot") && help.contains("copy"))
        check("the warm line points at the user's own AI assistant and asks for step-by-step help",
              help.contains("ai assistant") && help.contains("step by step"))
        check("the warm line stays short", GeminiKeySetup.agentHelp.count < 260,
              "\(GeminiKeySetup.agentHelp.count) characters")

        // What a key turns on, said in the section rather than left to the preflight row below it.
        check("the section names the feature a key turns on",
              GeminiKeySetup.turnsOn.contains("Option+G")
                && GeminiKeySetup.turnsOn.lowercased().contains("web search"))
        check("the section header names Option+G too, so a scrolled-past section still says what it is for",
              GeminiKeySetup.header.contains("OPTION+G"))
        check("the section says a key is optional and nothing else is affected",
              GeminiKeySetup.turnsOn.lowercased().contains("optional")
                && GeminiKeySetup.statusLine(.notStored).lowercased().contains("nothing else"))
        check("the not-stored headline asks for the key by naming what it turns on",
              GeminiKeySetup.headline(.notStored).contains("Option+G"))
        check("the stored headline says the feature is on",
              GeminiKeySetup.headline(.stored(.keychain)).lowercased().contains("is on"))

        // D7: the script stays shipped and is named as the fallback rather than hidden.
        check("the fallback names the shipped script",
              GeminiKeySetup.fallback.contains("./scripts/set-gemini-key.sh"))
        check("the fallback says who it is for: a terminal, or a Mac you are not sitting at",
              GeminiKeySetup.fallback.lowercased().contains("terminal"))
        check("the fallback names the script's own status and clear switches",
              GeminiKeySetup.fallback.contains("--status")
                && GeminiKeySetup.fallback.contains("--clear"))

        // A stored key can be replaced by pasting over it, or removed outright (L9).
        check("the field says it replaces the stored key once one is stored",
              GeminiKeySetup.fieldHint(.stored(.keychain)).lowercased().contains("replace"))
        check("the field says Option+G needs no restart when there is no key yet",
              GeminiKeySetup.fieldHint(.notStored).lowercased().contains("no restart"))

        // An override-sourced key is a materially different thing to be told about.
        check("an override-sourced key is named as such and not reported as stored in the keychain",
              GeminiKeySetup.statusLine(.stored(.environment))
                .contains(SecretStore.Secret.geminiAPIKey.environmentVariable)
                && !GeminiKeySetup.statusLine(.stored(.environment)).contains("Stored in your login"))
        check("a keychain-sourced key says where it lives and that it is never shown",
              GeminiKeySetup.statusLine(.stored(.keychain)).lowercased().contains("login keychain")
                && GeminiKeySetup.statusLine(.stored(.keychain)).lowercased().contains("never shown"))

        // House rules for anything shipped to a user.
        check("every string is plain ASCII", allCopy.allSatisfy { $0.allSatisfy(\.isASCII) },
              allCopy.filter { !$0.allSatisfy(\.isASCII) }.joined(separator: " | "))
        check("no string is empty", allCopy.allSatisfy { !$0.isEmpty })
        check("every addressable part has a distinct identifier",
              Set(GeminiKeySetup.Part.allCases.map(GeminiKeySetup.identifier)).count
                == GeminiKeySetup.Part.allCases.count)
        check("the card identifier does not collide with a part identifier",
              !GeminiKeySetup.Part.allCases.map(GeminiKeySetup.identifier)
                .contains(GeminiKeySetup.cardIdentifier))
    }

    // MARK: - Saving: one writer, and nothing written when there is nothing to write

    private static func checkSavePolicy(_ check: SelfTestReporter) {
        print("--- save policy ---")

        var written: [String] = []
        let ok: GeminiKeySetup.Writer = { value in written.append(value); return errSecSuccess }

        check("a pasted key is stored through the injected writer, once",
              GeminiKeySetup.save("AIzaSY-synthetic", writer: ok) == .stored
                && written == ["AIzaSY-synthetic"], "\(written.count) write(s)")

        // A key pasted with a trailing newline that is stored verbatim comes back from Google as an opaque
        // 400, which reads as "my key is wrong" rather than "my paste had a newline in it".
        written = []
        check("the stored value is trimmed, not stored as pasted",
              GeminiKeySetup.save("  AIzaSY-synthetic\n", writer: ok) == .stored
                && written == ["AIzaSY-synthetic"], written.joined(separator: ","))

        // Nothing entered must write NOTHING. An empty write would replace a working key with an empty one,
        // which is the one way this section could break a user who already had Option+G working.
        for blank in [nil, "", "   ", "\n\t "] as [String?] {
            written = []
            let outcome = GeminiKeySetup.save(blank, writer: ok)
            check("a blank entry (\(blank.map { "\"\($0)\"" } ?? "nil")) writes nothing at all",
                  outcome == .nothingEntered && written.isEmpty,
                  "\(written.count) write(s)")
        }

        // A real keychain failure is reported with its status and changes nothing.
        let failing: GeminiKeySetup.Writer = { _ in errSecInteractionNotAllowed }
        let failed = GeminiKeySetup.save("AIzaSY-synthetic", writer: failing)
        check("a keychain failure is reported as a failure carrying its own status",
              failed == .failed(errSecInteractionNotAllowed))
        check("the failure message explains the status rather than quoting a bare number",
              GeminiKeySetup.message(failed).contains(SecretStore.explain(errSecInteractionNotAllowed)))
        check("the failure message says nothing changed and offers the script",
              GeminiKeySetup.message(failed).lowercased().contains("nothing changed")
                && GeminiKeySetup.message(failed).contains("set-gemini-key.sh"))
        check("the success message says Option+G is on and needs no restart",
              GeminiKeySetup.message(.stored).contains("Option+G")
                && GeminiKeySetup.message(.stored).lowercased().contains("no restart"))
        check("the nothing-entered message says nothing was written",
              GeminiKeySetup.message(.nothingEntered).lowercased().contains("nothing was written"))

        // Only a real write changes what the machine would report, so only a real write re-measures.
        check("only a stored key makes the tab re-measure",
              GeminiKeySetup.requiresRemeasure(GeminiKeySetup.SaveOutcome.stored)
                && !GeminiKeySetup.requiresRemeasure(GeminiKeySetup.SaveOutcome.nothingEntered)
                && !GeminiKeySetup.requiresRemeasure(
                    GeminiKeySetup.SaveOutcome.failed(errSecUserCanceled)))

        // The shape that keeps the never-echo rule structural: an outcome can carry an OSStatus and nothing
        // else. A fourth case, or a String payload, has to be added deliberately and reds this.
        check("a save outcome can express exactly three things",
              GeminiKeySetup.SaveOutcome.Kind.allCases.count == 3
                && Set(GeminiKeySetup.SaveOutcome.Kind.allCases.map(\.rawValue)).count == 3)
        check("every outcome reports its own kind",
              outcomes.map(\.kind) == [.stored, .nothingEntered, .failed])
    }

    // MARK: - Deleting: offered only where it can tell the truth, and asked before it fires

    private static func checkDeletePolicy(_ check: SelfTestReporter) {
        print("--- delete policy ---")

        // The honesty rule of the whole item. A key resolved from the environment override means the
        // KEYCHAIN held nothing (SecretStore resolves keychain first), so a Delete button there would
        // delete nothing, report success, and leave Option+G working - which is exactly the lie that made
        // this affordance worth declining until it could be built properly.
        check("delete is offered for a key stored in the keychain",
              GeminiKeySetup.offersDelete(.stored(.keychain)))
        check("delete is NOT offered for a key coming from the environment override",
              !GeminiKeySetup.offersDelete(.stored(.environment)))
        check("delete is NOT offered when no key is stored",
              !GeminiKeySetup.offersDelete(.notStored))
        check("the environment state says the variable is what is supplying the key",
              GeminiKeySetup.environmentNote
                .contains(SecretStore.Secret.geminiAPIKey.environmentVariable))
        check("the environment state says plainly that a delete would not turn Option+G off",
              GeminiKeySetup.environmentNote.contains("Option+G")
                && GeminiKeySetup.environmentNote.lowercased().contains("would not turn"))
        check("the environment state says where to remove it instead",
              GeminiKeySetup.environmentNote.lowercased().contains("remove it where it is exported"))

        // The confirmation must not promise something it cannot know. The override can still be supplying a
        // key underneath a stored one, so the prompt names that rather than promising Option+G goes off.
        check("the confirmation names what it removes and from where",
              GeminiKeySetup.deletePrompt.lowercased().contains("login keychain")
                && GeminiKeySetup.deletePrompt.hasSuffix("."))
        check("the confirmation warns that the override can keep Option+G on",
              GeminiKeySetup.deletePrompt
                .contains(SecretStore.Secret.geminiAPIKey.environmentVariable)
                && GeminiKeySetup.deletePrompt.lowercased().contains("unless"))
        check("the confirmation says the section re-checks rather than asserting the result",
              GeminiKeySetup.deletePrompt.lowercased().contains("re-checks"))
        check("the confirmation says a new key can be pasted in later",
              GeminiKeySetup.deletePrompt.lowercased().contains("paste a new key"))

        // The delete itself: one call, through the app's one deleter.
        var deletes = 0
        let ok: GeminiKeySetup.Deleter = { deletes += 1; return errSecSuccess }
        check("a confirmed delete calls the app's keychain deleter exactly once",
              GeminiKeySetup.delete(deleter: ok) == .removed && deletes == 1, "\(deletes) delete(s)")

        let failing: GeminiKeySetup.Deleter = { errSecInteractionNotAllowed }
        let failed = GeminiKeySetup.delete(deleter: failing)
        check("a keychain failure is reported as a failure carrying its own status",
              failed == .failed(errSecInteractionNotAllowed))
        check("the failure message explains the status rather than quoting a bare number",
              GeminiKeySetup.message(failed).contains(SecretStore.explain(errSecInteractionNotAllowed)))
        check("the failure message says nothing changed and offers the script's --clear",
              GeminiKeySetup.message(failed).lowercased().contains("nothing changed")
                && GeminiKeySetup.message(failed).contains("set-gemini-key.sh --clear"))

        // The success message must not claim Option+G is off - only the re-measurement knows that.
        let removed = GeminiKeySetup.message(.removed)
        check("the removal message says what was removed and from where",
              removed.lowercased().contains("removed the stored key")
                && removed.lowercased().contains("login keychain"))
        check("the removal message points at the re-measured state instead of claiming Option+G is off",
              removed.lowercased().contains("re-checked")
                && !removed.lowercased().contains("option+g is off")
                && !removed.lowercased().contains("web search is off"))

        // Only a real delete changes what the machine would report, so only a real delete re-measures.
        check("only a real removal makes the tab re-measure",
              GeminiKeySetup.requiresRemeasure(GeminiKeySetup.DeleteOutcome.removed)
                && !GeminiKeySetup.requiresRemeasure(
                    GeminiKeySetup.DeleteOutcome.failed(errSecUserCanceled)))

        // Same structural guarantee the save path carries: an outcome that cannot hold a String cannot be
        // the thing that leaks a value into a message, a log line, or a crash report.
        check("a delete outcome can express exactly two things",
              GeminiKeySetup.DeleteOutcome.Kind.allCases.count == 2
                && Set(GeminiKeySetup.DeleteOutcome.Kind.allCases.map(\.rawValue)).count == 2)
        check("every delete outcome reports its own kind",
              deleteOutcomes.map(\.kind) == [.removed, .failed])

        // One message slot, of either kind, so a stale save message cannot sit under a fresh delete one.
        check("a notice carries either message and colours it by its own success",
              GeminiKeySetup.message(.deleted(.removed)) == GeminiKeySetup.message(.removed)
                && GeminiKeySetup.message(.saved(.stored)) == GeminiKeySetup.message(.stored)
                && GeminiKeySetup.isSuccess(.deleted(.removed))
                && GeminiKeySetup.isSuccess(.saved(.stored))
                && !GeminiKeySetup.isSuccess(.deleted(.failed(errSecAuthFailed)))
                && !GeminiKeySetup.isSuccess(.saved(.nothingEntered)))
        check("a notice re-measures on exactly the outcomes its own kind would",
              GeminiKeySetup.requiresRemeasure(GeminiKeySetup.Notice.deleted(.removed))
                && GeminiKeySetup.requiresRemeasure(GeminiKeySetup.Notice.saved(.stored))
                && !GeminiKeySetup.requiresRemeasure(
                    GeminiKeySetup.Notice.deleted(.failed(errSecUserCanceled)))
                && !GeminiKeySetup.requiresRemeasure(GeminiKeySetup.Notice.saved(.nothingEntered)))

        // The controls the confirmation needs, each with its own identifier and none of them a text line the
        // layout gate would try to measure for clipping.
        check("the delete controls are addressable and distinct from the text parts",
              [GeminiKeySetup.Part.delete, .deleteConfirm, .deleteCancel].allSatisfy(\.isControl)
                && [GeminiKeySetup.Part.deletePrompt, .environmentNote, .message]
                    .allSatisfy { !$0.isControl })
        check("every delete control has a title",
              [GeminiKeySetup.deleteTitle, GeminiKeySetup.deleteConfirmTitle,
               GeminiKeySetup.deleteCancelTitle].allSatisfy { !$0.isEmpty })
    }

    // MARK: - The key is never echoed, never logged, never in an argv

    private static func checkNeverEchoed(_ check: SelfTestReporter) {
        print("--- the pasted key never leaves the writer ---")

        let canary = "AIzaSY-CANARY-\(UUID().uuidString)"
        var written: [String] = []
        let outcome = GeminiKeySetup.save(canary, writer: { written.append($0); return errSecSuccess })
        check("the canary reached the keychain writer, so this gate is testing a real path",
              written == [canary])

        check("the outcome cannot carry the value",
              !String(describing: outcome).contains(canary)
                && !String(reflecting: outcome).contains(canary))
        check("the message shown after a save cannot carry the value",
              !GeminiKeySetup.message(outcome).contains(canary))
        check("no string the section can render carries the value",
              allCopy.allSatisfy { !$0.contains(canary) })

        // The app log is the one place a value could leak durably, so it is read rather than reasoned about.
        Log.flushForTest()
        let log = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("the app log records that a key was stored, and never the key",
              !log.contains(canary) && log.contains("gemini key: stored in the login keychain"),
              "log is \(log.utf8.count) bytes")

        // A failing write is the more dangerous path, because a failure message is where a value tends to get
        // quoted "for debugging".
        let failedCanary = "AIzaSY-FAILCANARY-\(UUID().uuidString)"
        let failure = GeminiKeySetup.save(failedCanary, writer: { _ in errSecAuthFailed })
        check("a failed write reports the status without the value",
              failure == .failed(errSecAuthFailed)
                && !GeminiKeySetup.message(failure).contains(failedCanary)
                && !String(describing: failure).contains(failedCanary))
        Log.flushForTest()
        let afterFailure = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("the app log records the failing status without the value",
              !afterFailure.contains(failedCanary)
                && afterFailure.contains("gemini key: keychain write failed (OSStatus \(errSecAuthFailed))"))

        // A blank entry must not log a value either - and must not log a success it did not perform.
        let blankLogBefore = afterFailure
        _ = GeminiKeySetup.save("   ", writer: { _ in errSecSuccess })
        Log.flushForTest()
        let afterBlank = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("a blank entry is logged as writing nothing, not as a store",
              afterBlank.contains("gemini key: nothing entered, nothing written")
                && afterBlank.count > blankLogBefore.count)

        // L9: the delete path is swept too, rather than inheriting the save path's clean bill. The strongest
        // guarantee here is structural - `Deleter` takes no parameter, so this path cannot be handed the key
        // even by a caller trying to - but the canary is driven through the state a real user is actually in
        // when they click Delete: a key stored a moment ago, then removed.
        let doomed = "AIzaSY-DELETECANARY-\(UUID().uuidString)"
        _ = GeminiKeySetup.save(doomed, writer: { _ in errSecSuccess })
        let removal = GeminiKeySetup.delete(deleter: { errSecSuccess })
        check("the delete outcome cannot carry the value of the key it removed",
              removal == .removed
                && !String(describing: removal).contains(doomed)
                && !String(reflecting: removal).contains(doomed))
        check("the message shown after a delete cannot carry the value",
              !GeminiKeySetup.message(removal).contains(doomed))
        check("no string the section can render after a delete carries the value",
              allCopy.allSatisfy { !$0.contains(doomed) })
        Log.flushForTest()
        let afterDelete = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("the app log records the removal, and never the key it removed",
              !afterDelete.contains(doomed)
                && afterDelete.contains("gemini key: removed from the login keychain"))

        let failedDelete = GeminiKeySetup.delete(deleter: { errSecInteractionNotAllowed })
        Log.flushForTest()
        let afterFailedDelete = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("a failed delete reports the status without the value, and logs the same way",
              failedDelete == .failed(errSecInteractionNotAllowed)
                && !GeminiKeySetup.message(failedDelete).contains(doomed)
                && !afterFailedDelete.contains(doomed)
                && afterFailedDelete.contains(
                    "gemini key: keychain delete failed (OSStatus \(errSecInteractionNotAllowed))"))
    }
}
