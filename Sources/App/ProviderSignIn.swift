import Cocoa

/// The Claude half of onboarding's one connect action (Public V1 spec W4, item P9).
///
/// Piggyback auth (locked decision 2) means the vendor's own client mints and owns the credential, so signing
/// in to Claude is not something ViddyDictate can do in-process: `claude auth login` is an interactive
/// terminal flow that renders its own UI and waits for the user. Codex has an in-app equivalent only because
/// its CLI exposes a non-interactive device-login command whose output can be read (`CodexConnectionController`).
///
/// So the Claude action hands the login to Terminal, already running the right command, and ViddyDictate
/// watches for it to take effect (spec D5 - `ClaudeConnectionFlow` owns that polling; the user no longer
/// re-checks by hand). Terminal declares `com.apple.terminal.shell-script` with the `Shell` role, which is why
/// handing it a `.command` file runs it rather than opening it in an editor; that is also why the file must be
/// executable. Nothing here needs Automation permission - it is an ordinary document open, not an AppleEvent.
///
/// The script is written into the app's own Application Support directory rather than a world-writable temp
/// directory, because it is a file this app makes executable on purpose.
enum ClaudeSignIn {
    static let scriptName = "claude-sign-in.command"

    enum Outcome: Equatable {
        case launched(command: String)
        /// The CLI is not installed, so there is nothing to sign in to. Onboarding never offers the action in
        /// that state; this exists so a caller reached some other way still fails honestly.
        case notInstalled
        case failed(String)
    }

    /// The literal command a user could also run themselves. Shown beside the button, and quoted into the
    /// script, so the two can never disagree about what is being run.
    static func command(binary: String) -> String {
        "\(shellQuoted(binary)) auth login"
    }

    /// The whole script. `exec` so the window shows the vendor's own UI with no wrapper output above it, and
    /// `--claudeai` is deliberately absent: it is already the default, and naming `--console` instead would
    /// switch the user to API-usage billing, which is not what a subscription sign-in means.
    ///
    /// The second line used to say "click Check again". Spec D5 replaced that manual step: ViddyDictate
    /// polls `claude auth status --json` and closes its own sheet, so the script says what actually
    /// happens rather than sending the user looking for a button that is no longer the mechanism.
    static func scriptBody(binary: String) -> String {
        """
        #!/bin/zsh
        # Written by ViddyDictate to sign in to Claude Code. Safe to delete.
        echo "Signing in to Claude Code for ViddyDictate."
        echo "When this finishes, ViddyDictate notices by itself. You can close this window."
        echo
        exec \(command(binary: binary))
        """
    }

    /// Single-quote for the shell, the way a path with a space or a quote in it requires.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static var terminalURL: URL {
        URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }

    /// Resolve the CLI, write the script, and open it with Terminal. The binary comes from
    /// `CloudCleanupClient.resolveBinary`, the one owner of "where is the claude CLI", so onboarding cannot
    /// launch a different binary than the one the transforms use.
    static func launch(binary resolved: String? = CloudCleanupClient.resolveBinary(),
                       open: (URL) -> Bool = openInTerminal) -> Outcome {
        guard let binary = resolved else { return .notInstalled }
        let url = AppPaths.ensureApplicationSupportDirectory()
            .appendingPathComponent(scriptName, isDirectory: false)
        do {
            try scriptBody(binary: binary).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path)
        } catch {
            Log.write("claude sign-in: could not stage the login script")
            return .failed("The sign-in script could not be written.")
        }
        guard open(url) else {
            Log.write("claude sign-in: Terminal did not open the login script")
            return .failed("Terminal did not open.")
        }
        Log.write("claude sign-in: handed claude auth login to Terminal")
        return .launched(command: command(binary: binary))
    }

    /// Asynchronous by nature, so a false here means the request itself was refused, not that the login
    /// failed. A later re-measure through `LLMProviderDetection` is what establishes whether it worked;
    /// nothing is ever inferred from this.
    private static func openInTerminal(_ script: URL) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([script], withApplicationAt: terminalURL,
                                configuration: configuration, completionHandler: nil)
        return true
    }
}

/// The ONE code path for getting a provider connected (W4). Both hosts - the first-run window and the Setup
/// tab in Settings - drive this same type, entered from the same `signedOut` state, so the two cannot drift
/// into two implementations of one outcome.
///
/// It sets no route, model, effort, or prompt: the only thing it does is ask a provider's own client to sign
/// the user in. Whether it worked is established by re-measuring, never by parsing what a vendor said.
final class ProviderSignInPresenter {
    private let codex = CodexConnectionPresenter()
    private let claude = ClaudeConnectionPresenter()

    /// Invoked after a sign-in attempt returns, so the host can re-measure rather than assume.
    var onFinished: (() -> Void)?

    func begin(_ provider: LLMProvider, in window: NSWindow?) {
        switch provider {
        case .codex:
            codex.present(in: window) { [weak self] in self?.onFinished?() }
        case .claude:
            claude.present(in: window) { [weak self] in self?.onFinished?() }
        case .local:
            // Onboarding never offers Local (`ProviderOnboarding.canDriveSignIn`), so this is unreachable
            // from a plan. Logged rather than asserted because a crash would be a worse answer than nothing.
            Log.write("provider sign-in: no sign-in flow for the local provider")
        }
    }
}

/// Rendering contract for the Claude sign-in wait field, owned in one place so the presenter and its GUI
/// probe cannot drift apart.
///
/// The countdown arrives every two seconds, AFTER the sheet is on screen. An `NSAlert` freezes its layout
/// when presented, so a string swapped into `informativeText` at that point is silently clipped and the user
/// sees nothing change. The countdown therefore lives in a fixed-size accessory field that is already big
/// enough for its longest value before the sheet is shown. See `CodexDeviceCodePresentation`, which is the
/// same contract for the Codex one-time code and the same defect it was written for.
enum ClaudeSignInWaitPresentation {
    static let fieldSize = NSSize(width: 340, height: 24)

    static func makeStatusField() -> NSTextField {
        let field = NSTextField(labelWithString: ClaudeConnectionFlow.awaitingFieldText)
        // Monospaced digits so a ticking countdown does not shuffle the text sideways every second.
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .center
        field.lineBreakMode = .byClipping
        field.setFrameSize(fieldSize)
        return field
    }

    /// True when the field's current string renders inside its own frame, in both axes. The original defect
    /// was a string that did not fit and was clipped unseen, so "it fits" is the assertion that bites.
    static func textFits(_ field: NSTextField) -> Bool {
        let size = field.attributedStringValue.size()
        return size.width <= field.frame.width && size.height <= field.frame.height
    }
}

/// The Claude connect flow's AppKit host (spec D3, D5). One of these is owned by
/// `ProviderSignInPresenter`, so the Setup tab, the first-run window, and the Models tab's inline rescue
/// are three hosts on ONE implementation (W4).
///
/// It presents; it decides nothing. Which of the four things happens comes from
/// `ClaudeConnectionFlow.launchesSignIn` and the measurement behind it, and every string comes from the
/// flow's own copy, so the deterministic gate covers the wording and this file covers only the sheets.
final class ClaudeConnectionPresenter {
    private var waitAlert: NSAlert?
    private var statusField: NSTextField?
    private var onFinished: (() -> Void)?

    func present(in window: NSWindow?, onFinished: (() -> Void)? = nil) {
        guard let window else {
            // Both real hosts own a window; a sheet-less caller would have nowhere to show the wait, and a
            // modal alert would block the main thread the poll needs to close itself.
            Log.write("claude sign-in: no host window, nothing presented")
            onFinished?()
            return
        }
        self.onFinished = onFinished
        // Measured live rather than read from stored availability: this is the decision that either does or
        // does not rotate a machine-wide credential, so it is worth a fresh 0.2s reading.
        ClaudeConnectionController.shared.measure { [weak self] measurement in
            guard let self else { return }
            guard ClaudeConnectionFlow.launchesSignIn(measurement.situation),
                  let binary = measurement.binary,
                  let command = measurement.command else {
                self.presentMessage(
                    ClaudeConnectionFlow.situationMessage(measurement.situation,
                                                          reason: measurement.reason,
                                                          command: measurement.command),
                    in: window)
                self.finish()
                return
            }
            self.beginSignIn(binary: binary, command: command, in: window)
        }
    }

    private func finish() {
        let callback = onFinished
        onFinished = nil
        callback?()
    }

    private func beginSignIn(binary: String, command: String, in window: NSWindow) {
        let sheet = NSAlert()
        let waiting = ClaudeConnectionFlow.situationMessage(.signedOut, command: command)
        // Every word that has to be readable later is set BEFORE presenting; only the accessory field's
        // string changes afterwards.
        sheet.messageText = waiting.title
        sheet.informativeText = waiting.body
        sheet.alertStyle = .informational
        let field = ClaudeSignInWaitPresentation.makeStatusField()
        sheet.accessoryView = field
        sheet.addButton(withTitle: "Cancel")
        waitAlert = sheet
        statusField = field
        sheet.beginSheetModal(for: window) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.waitAlert === sheet else { return }
            self.waitAlert = nil
            self.statusField = nil
            ClaudeConnectionController.shared.cancelSignIn()
        }

        ClaudeConnectionController.shared.startSignIn(
            binary: binary,
            onWaiting: { [weak self, weak sheet] remaining in
                guard let self, let sheet, self.waitAlert === sheet else { return }
                self.statusField?.stringValue =
                    ClaudeConnectionFlow.waitingFieldText(remaining: remaining)
            },
            completion: { [weak self, weak sheet] result in
                guard let self else { return }
                if let sheet, self.waitAlert === sheet {
                    self.waitAlert = nil
                    self.statusField = nil
                    // D5: the flow closes its own sheet on a detected sign-in. Nothing waits for a click.
                    if sheet.window.sheetParent != nil { window.endSheet(sheet.window) }
                }
                if let message = ClaudeConnectionFlow.resultMessage(result, command: command) {
                    // One turn later: a sheet cannot begin while the previous one is still being dismissed.
                    DispatchQueue.main.async { self.presentMessage(message, in: window) }
                }
                self.finish()
            })
    }

    private func presentMessage(_ message: ClaudeConnectionFlow.Message, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.body
        alert.alertStyle = message.severity == .warning ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
