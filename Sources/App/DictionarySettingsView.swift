import Cocoa

/// The correction Dictionary editor (Settings "Dictionary" tab, ADR 0002). Two hand-authored columns:
/// **Hard-coded replacements** (deterministic, always-true) and **Context-aware replacements** (LLM
/// glossary applied with judgment). Each is an editable list of (heard -> intended) pairs with add /
/// remove. Edits persist to the app-local store immediately. The hidden whisper bias (Layer 0) is
/// derived from both columns and has no surface here, by design.
final class DictionarySettingsView: NSView, NSTextFieldDelegate {
    override var isFlipped: Bool { true }

    private var hard: [CorrectionEntry] = CorrectionDictionary.shared.hardCoded
    private var context: [CorrectionEntry] = CorrectionDictionary.shared.contextAware
    private var hardFields: [(heard: NSTextField, intended: NSTextField)] = []
    private var contextFields: [(heard: NSTextField, intended: NSTextField)] = []

    private(set) var contentHeight: CGFloat = 0
    private let W: CGFloat

    init(width: CGFloat) {
        self.W = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        // Always show at least one (blank, ghost-prompted) row per column so the shape is modeled.
        if hard.isEmpty { hard = [CorrectionEntry(heard: "", intended: "")] }
        if context.isEmpty { context = [CorrectionEntry(heard: "", intended: "")] }
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    // MARK: layout

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        hardFields.removeAll(); contextFields.removeAll()
        let L: CGFloat = 20
        var y: CGFloat = 16

        y = section(title: "HARD-CODED REPLACEMENTS",
                    helper: "For words that are ALWAYS misheard the same way (names, brands, jargon). "
                          + "Read each as \"When I say X, always write Y.\" For fixes that depend on the "
                          + "sentence (like \"closed\" vs \"close\"), use Cleanup (?) instead.",
                    entries: hard, isHard: true,
                    ghost: ("vidi dictate", "ViddyDictate"), x: L, y: y)
        y += 14

        y = section(title: "CONTEXT-AWARE REPLACEMENTS",
                    helper: "The AI applies these with judgment, only where they fit the sentence. "
                          + "They also nudge the recognizer toward the right words.",
                    entries: context, isHard: false,
                    ghost: ("session closed", "session close"), x: L, y: y)
        y += 12

        contentHeight = y
        frame = NSRect(x: 0, y: 0, width: W, height: y)
    }

    private func section(title: String, helper: String, entries: [CorrectionEntry], isHard: Bool,
                         ghost: (String, String), x L: CGFloat, y: CGFloat) -> CGFloat {
        var y = y
        let h = NSTextField(labelWithString: title)
        h.font = .systemFont(ofSize: 10, weight: .semibold)
        h.textColor = .secondaryLabelColor
        h.frame = NSRect(x: L, y: y, width: W - 2 * L, height: 14)
        addSubview(h); y += 18

        let hint = NSTextField(wrappingLabelWithString: helper)
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: L, y: y, width: W - 2 * L, height: 44)
        addSubview(hint); y += 48

        // Column captions.
        let cap1 = caption("When I say", x: L, y: y)
        let cap2 = caption(isHard ? "always write" : "intended", x: L + colW(L) + 28, y: y)
        addSubview(cap1); addSubview(cap2); y += 16

        let rowH: CGFloat = 30
        for (i, e) in entries.enumerated() {
            let heard = field(e.heard, placeholder: i == 0 ? ghost.0 : "", x: L, y: y, w: colW(L))
            let arrow = NSTextField(labelWithString: "→")
            arrow.font = .systemFont(ofSize: 13)
            arrow.textColor = .secondaryLabelColor
            arrow.frame = NSRect(x: L + colW(L) + 8, y: y + 4, width: 16, height: 18)
            let intended = field(e.intended, placeholder: i == 0 ? ghost.1 : "", x: L + colW(L) + 28, y: y, w: colW(L) - 36)
            let remove = NSButton(title: "–", target: self, action: #selector(removeRow(_:)))
            remove.bezelStyle = .circular
            remove.frame = NSRect(x: W - L - 24, y: y + 1, width: 24, height: 24)
            remove.tag = (isHard ? 0 : 1000) + i
            addSubview(heard); addSubview(arrow); addSubview(intended); addSubview(remove)
            if isHard { hardFields.append((heard, intended)) } else { contextFields.append((heard, intended)) }
            y += rowH
        }

        let add = NSButton(title: isHard ? "+ Add hard-coded" : "+ Add context-aware",
                           target: self, action: #selector(addRow(_:)))
        add.bezelStyle = .inline
        add.font = .systemFont(ofSize: 11)
        add.frame = NSRect(x: L, y: y + 2, width: 180, height: 24)
        add.tag = isHard ? 0 : 1
        addSubview(add); y += 32
        return y
    }

    private func colW(_ L: CGFloat) -> CGFloat { (W - 2 * L - 28 - 28) / 2 }

    private func caption(_ s: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 9.5, weight: .medium)
        t.textColor = .tertiaryLabelColor
        t.frame = NSRect(x: x, y: y, width: 160, height: 12)
        return t
    }

    private func field(_ value: String, placeholder: String, x: CGFloat, y: CGFloat, w: CGFloat) -> NSTextField {
        let t = NSTextField(string: value)
        t.font = .systemFont(ofSize: 12)
        t.placeholderString = placeholder
        t.delegate = self
        t.frame = NSRect(x: x, y: y, width: w, height: 22)
        return t
    }

    // MARK: edits

    func controlTextDidEndEditing(_ obj: Notification) { syncAndPersist() }

    @objc private func addRow(_ sender: NSButton) {
        syncFromFields()
        if sender.tag == 0 { hard.append(CorrectionEntry(heard: "", intended: "")) }
        else { context.append(CorrectionEntry(heard: "", intended: "")) }
        rebuild()
    }

    @objc private func removeRow(_ sender: NSButton) {
        syncFromFields()
        let isHard = sender.tag < 1000
        let i = isHard ? sender.tag : sender.tag - 1000
        if isHard { if hard.indices.contains(i) { hard.remove(at: i) } }
        else { if context.indices.contains(i) { context.remove(at: i) } }
        // Keep at least one (blank) row per column so the editor is never empty.
        if hard.isEmpty { hard = [CorrectionEntry(heard: "", intended: "")] }
        if context.isEmpty { context = [CorrectionEntry(heard: "", intended: "")] }
        rebuild()
        syncAndPersist()
    }

    /// Read the live text fields back into the model arrays (without persisting).
    private func syncFromFields() {
        hard = hardFields.map { CorrectionEntry(heard: $0.heard.stringValue, intended: $0.intended.stringValue) }
        context = contextFields.map { CorrectionEntry(heard: $0.heard.stringValue, intended: $0.intended.stringValue) }
    }

    private func syncAndPersist() {
        syncFromFields()
        CorrectionDictionary.shared.update(hardCoded: hard, contextAware: context)
    }
}
