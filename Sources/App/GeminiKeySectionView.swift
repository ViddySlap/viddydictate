import Cocoa
import Security

/// The Gemini API key section on the Setup tab (L5, spec decision D7), as one card: what the key
/// turns on, how to get one, a secure field to paste it into, where it went, and (L9) how to remove it.
///
/// A stored key can be REPLACED by pasting over it or DELETED outright. Delete asks before it fires and is
/// offered only when a key actually resolved from the keychain - see `GeminiKeySetup.offersDelete`, which
/// owns that judgement and the reason for it.
///
/// Built the same way L4's provider sign-in section is: a state comes in through `apply`, a card goes out,
/// and the only judgement in the file belongs to `GeminiKeySetup`. It shares that section's card and label
/// chrome through `SettingsSectionKit` rather than drawing its own, so the two sections on this tab cannot
/// drift apart.
///
/// **The key never leaves this file except into the keychain writer.** It is typed into an
/// `NSSecureTextField`, read once on Save, handed to `GeminiKeySetup.save`, and the field is cleared on a
/// successful write. Nothing here logs it, puts it in a label, sets it as a tooltip, or passes it through an
/// argv - and the message shown afterwards is built from the OUTCOME, which has nowhere to carry a value.
final class GeminiKeySectionView: NSView {
    override var isFlipped: Bool { true }

    /// The keychain write, injected. Production is `SecretStore.write`, which performs the real
    /// `SecItemUpdate`/`SecItemAdd`; there is no second keychain path anywhere in this feature. It is
    /// injected only so the offscreen probe can drive every outcome - an agent shell cannot write the login
    /// keychain at all, so a gate that used the real one would report on the session, not on this surface.
    typealias Writer = GeminiKeySetup.Writer

    /// The keychain delete, injected for the same reason and with the same production default: it is the
    /// SAME `SecretStore.delete` that `./scripts/set-gemini-key.sh --clear` reaches through
    /// `--clear-gemini-key`, not a second delete written for a button. It takes no parameter, so this path
    /// cannot be handed the key at all.
    typealias Deleter = GeminiKeySetup.Deleter

    /// Called after a write or a delete that actually changed the machine, so the host can re-measure. The
    /// section does not re-render itself from its own opinion of what it just did: the stored state comes
    /// back through `apply` from the same observation the preflight row reads, so the two can never
    /// disagree. That property matters most on the delete path - a Delete button that reported success
    /// while Option+G kept working would be a lie, and re-measuring is what makes it impossible to tell one.
    var onStored: (() -> Void)?

    private let W: CGFloat
    private let L: CGFloat
    private let writer: Writer
    private let deleter: Deleter
    /// nil until the tab has measured. A section with no reading must not claim a key is missing.
    private var status: GeminiKeySetup.Status?
    /// What the section last did, or nil when nothing has been tried since it was built. One slot, so a
    /// stale "Saved." cannot sit underneath a fresh "Removed."
    private var notice: GeminiKeySetup.Notice?
    /// Whether the delete is waiting on its confirmation. A destructive control that fires on one click is
    /// how a working key gets dropped by a mis-click, so Delete asks first and this holds the asking.
    ///
    /// Deliberately a two-step INLINE confirmation rather than an `NSAlert`: an alert on this tab would be
    /// undrivable by the offscreen render gate, so the confirmation would ship unverified - and the alert
    /// layout trap this project has already paid for is right there in `CodexDeviceCodePresentation`.
    private var confirmingDelete = false
    /// Held across rebuilds so a failed Save does not throw away what the user pasted. The field is secure,
    /// so this is bullets on screen either way; losing a pasted key to a re-render would just make them
    /// paste it twice.
    private var pending = ""

    init(width: CGFloat, leftInset: CGFloat = 20,
         writer: @escaping Writer = { SecretStore.write(.geminiAPIKey, value: $0) },
         deleter: @escaping Deleter = { SecretStore.delete(.geminiAPIKey) }) {
        self.W = width
        self.L = leftInset
        self.writer = writer
        self.deleter = deleter
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    /// Render a measurement, or the in-flight state when `status` is nil. Returns the height it needs, so a
    /// host laying out a taller document can place what follows.
    @discardableResult
    func apply(_ status: GeminiKeySetup.Status?) -> CGFloat {
        self.status = status
        // A pending confirmation belongs to the reading it was raised against. If a re-measurement says
        // there is no longer a stored key to delete - because this delete succeeded, or because something
        // else changed the machine - the question is stale and must not stay on screen waiting to be
        // answered about a key that is gone.
        if !GeminiKeySetup.offersDelete(status ?? .notStored) { confirmingDelete = false }
        rebuild()
        return frame.height
    }

    // MARK: - build

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let contentW = W - L - 20
        let card = SettingsSectionKit.card(frame: NSRect(x: L, y: 0, width: contentW, height: 0),
                                           identifier: GeminiKeySetup.cardIdentifier)
        addSubview(card)

        let statusW: CGFloat = 110
        let textX = statusW + 20
        let textW = contentW - textX - 14
        var y: CGFloat = 12

        // Before the tab has measured, the section still draws its standing copy - the instructions are
        // useful with or without a reading - but it must not show a state word it has not measured.
        if let status = status {
            let state = SettingsSectionKit.label(GeminiKeySetup.statusText(status), x: 14, y: y + 1,
                                                 width: statusW - 8, size: 10, weight: .semibold,
                                                 color: status.isStored ? .systemGreen : .systemOrange)
            state.identifier = identifier(.status)
            card.addSubview(state)
        }

        let headline = SettingsSectionKit.wrapped(
            status.map(GeminiKeySetup.headline) ?? GeminiKeySetup.checkingHeadline,
            x: textX, y: y, width: textW, size: 12.5, weight: .semibold,
            color: (status?.isStored ?? true) ? .labelColor : .systemOrange)
        headline.identifier = identifier(.headline)
        card.addSubview(headline)
        y = headline.frame.maxY + 4

        // Laid out from one list so the section cannot lose a line by forgetting a call, and so the
        // identifiers are assigned positionally from the order the pure layer documents.
        let lines: [(GeminiKeySetup.Part, String?, NSColor)] = [
            (.statusLine, status.map(GeminiKeySetup.statusLine), .secondaryLabelColor),
            // Secondary rather than tertiary: this is the line that says what a key turns on, and at
            // tertiary against the card fill it was legible only if you already knew it was there.
            (.turnsOn, GeminiKeySetup.turnsOn, .secondaryLabelColor),
            (.instructions, GeminiKeySetup.instructions, .labelColor),
            (.agentHelp, GeminiKeySetup.agentHelp, .secondaryLabelColor),
        ]
        for (part, value, color) in lines {
            guard let value = value else { continue }
            let field = SettingsSectionKit.wrapped(value, x: textX, y: y, width: textW, size: 10.5,
                                                   color: color)
            field.identifier = identifier(part)
            field.toolTip = value
            card.addSubview(field)
            y += field.frame.height + 3
        }
        y += 5

        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.font = .systemFont(ofSize: 11)
        save.identifier = identifier(.save)
        save.sizeToFit()
        let saveW = max(72, save.frame.width)

        // Secure by construction, not by an attribute someone can flip: an NSSecureTextField cannot be made
        // to display what is typed into it, so the field cannot become the thing that echoes the key.
        let entry = NSSecureTextField(frame: NSRect(x: textX, y: y, width: textW - saveW - 8, height: 24))
        entry.identifier = identifier(.field)
        entry.placeholderString = "Paste your Gemini API key"
        entry.font = .systemFont(ofSize: 11)
        entry.stringValue = pending
        entry.target = self
        entry.action = #selector(saveClicked)   // Return in the field saves, like any credential field
        card.addSubview(entry)

        save.frame = NSRect(x: textX + textW - saveW, y: y - 1, width: saveW, height: 26)
        card.addSubview(save)
        y = max(entry.frame.maxY, save.frame.maxY) + 5

        let hint = SettingsSectionKit.wrapped(
            GeminiKeySetup.fieldHint(status ?? .notStored), x: textX, y: y, width: textW,
            size: 10, color: .tertiaryLabelColor)
        hint.identifier = identifier(.fieldHint)
        card.addSubview(hint)
        y = hint.frame.maxY + 3

        y = addDeleteRow(to: card, x: textX, y: y, width: textW)

        if let notice = notice {
            let text = GeminiKeySetup.message(notice)
            let message = SettingsSectionKit.wrapped(
                text, x: textX, y: y, width: textW, size: 10.5,
                color: GeminiKeySetup.isSuccess(notice) ? .systemGreen : .systemOrange)
            message.identifier = identifier(.message)
            message.toolTip = text
            card.addSubview(message)
            y = message.frame.maxY + 3
        }

        let fallback = SettingsSectionKit.wrapped(GeminiKeySetup.fallback, x: textX, y: y + 2,
                                                  width: textW, size: 10, color: .tertiaryLabelColor)
        fallback.identifier = identifier(.fallback)
        card.addSubview(fallback)
        y = fallback.frame.maxY

        card.frame.size.height = y + 9
        frame = NSRect(x: 0, y: frame.origin.y, width: W, height: card.frame.maxY)
    }

    // MARK: - delete (L9)

    /// Draw whatever this state offers for removing a stored key: the button, the confirmation it raises,
    /// or - when the key is coming from the environment override - the note that says why there is no
    /// button and what to do instead. Returns the y it consumed to.
    private func addDeleteRow(to card: NSView, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        guard let status = status else { return y }

        // No stored key to remove and no override in play: nothing to say.
        if !GeminiKeySetup.offersDelete(status) {
            guard status == .stored(.environment) else { return y }
            let note = SettingsSectionKit.wrapped(GeminiKeySetup.environmentNote, x: x, y: y + 2,
                                                  width: width, size: 10, color: .systemOrange)
            note.identifier = identifier(.environmentNote)
            note.toolTip = GeminiKeySetup.environmentNote
            card.addSubview(note)
            return note.frame.maxY + 3
        }

        var y = y + 2
        guard confirmingDelete else {
            let button = control(title: GeminiKeySetup.deleteTitle, part: .delete,
                                 action: #selector(deleteClicked), x: x, y: y)
            card.addSubview(button)
            return button.frame.maxY + 3
        }

        let prompt = SettingsSectionKit.wrapped(GeminiKeySetup.deletePrompt, x: x, y: y, width: width,
                                                size: 10.5, color: .systemOrange)
        prompt.identifier = identifier(.deletePrompt)
        prompt.toolTip = GeminiKeySetup.deletePrompt
        card.addSubview(prompt)
        y = prompt.frame.maxY + 4

        let confirm = control(title: GeminiKeySetup.deleteConfirmTitle, part: .deleteConfirm,
                              action: #selector(confirmDeleteClicked), x: x, y: y)
        confirm.hasDestructiveAction = true
        card.addSubview(confirm)
        let cancel = control(title: GeminiKeySetup.deleteCancelTitle, part: .deleteCancel,
                             action: #selector(cancelDeleteClicked), x: confirm.frame.maxX + 8, y: y)
        card.addSubview(cancel)
        return max(confirm.frame.maxY, cancel.frame.maxY) + 3
    }

    private func control(title: String, part: GeminiKeySetup.Part, action: Selector,
                         x: CGFloat, y: CGFloat) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.identifier = identifier(part)
        button.sizeToFit()
        button.frame = NSRect(x: x, y: y, width: max(72, button.frame.width + 8), height: 24)
        return button
    }

    /// One click asks; it does not delete. The click that deletes is `confirmDeleteClicked`.
    @objc private func deleteClicked() {
        confirmingDelete = true
        notice = nil
        rebuild()
    }

    @objc private func cancelDeleteClicked() {
        confirmingDelete = false
        rebuild()
    }

    /// Remove the stored key through the app's ONE keychain delete, then let the tab re-measure. The
    /// section never decides for itself that the key is gone: what it says next comes back through `apply`
    /// from a fresh observation, so it cannot report an off feature that is still on.
    @objc private func confirmDeleteClicked() {
        let outcome = GeminiKeySetup.delete(deleter: deleter)
        confirmingDelete = false
        notice = .deleted(outcome)
        rebuild()
        if GeminiKeySetup.requiresRemeasure(outcome) { onStored?() }
    }

    // MARK: - save

    /// Read the field once, hand it to the pure save policy, and render what it says. The value is not held
    /// anywhere else and is dropped the moment the write succeeds.
    @objc private func saveClicked() {
        guard let entry = viewWithIdentifier(GeminiKeySetup.identifier(.field)) as? NSSecureTextField
        else { return }
        let outcome = GeminiKeySetup.save(entry.stringValue, writer: writer)
        notice = .saved(outcome)
        // A save answers a delete question that is still on screen: the user changed their mind about what
        // they were doing, and a confirmation left standing would apply to the key they just pasted.
        confirmingDelete = false
        // Cleared only on a real write. A failed Save keeps the paste so the user can retry rather than
        // fetch the key again; the field is secure, so it is bullets either way.
        pending = outcome == .stored ? "" : entry.stringValue
        rebuild()
        if GeminiKeySetup.requiresRemeasure(outcome) { onStored?() }
    }

    private func identifier(_ part: GeminiKeySetup.Part) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(GeminiKeySetup.identifier(part))
    }

    private func viewWithIdentifier(_ id: String) -> NSView? {
        func search(_ root: NSView) -> NSView? {
            if root.identifier?.rawValue == id { return root }
            for child in root.subviews {
                if let hit = search(child) { return hit }
            }
            return nil
        }
        return search(self)
    }
}
