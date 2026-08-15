import Cocoa

/// Rolling, local clipboard history. Stores the most recent eligible clipboard contents in
/// Application Support. ViddyDictate's own pasteboard writes all go through `SyntheticPasteboard`,
/// which marks them; `poll()` skips marked contents so they never appear here.
final class ClipboardHistory {
    static let shared = ClipboardHistory()
    static let didChange = Notification.Name("VDClipboardHistoryDidChange")

    struct Entry: Codable {
        let id: UUID
        let date: Date
        let preview: String
        let detail: String
        let types: [String]
        let snapshot: PasteboardSnapshot
    }

    /// Per-entry persistence budget: the sole owner of the 10MB cap. It bounds how large a captured
    /// clipboard this rolling on-disk history will store — a persistence concern, not a capture one.
    /// The transient park/copy-capture paths capture uncapped (`PasteboardSnapshot.capture` default).
    private let maxBytes = 10 * 1024 * 1024
    private let log: PersistedJSONLog<Entry>
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var suppressCaptureUntil = Date.distantPast

    private init() {
        let base = AppPaths.ensureApplicationSupportDirectory()
        log = PersistedJSONLog(
            url: base.appendingPathComponent("clipboard-history.json"),
            queueLabel: AppIdentity.queueLabel("clipboard-history"),
            maxEntries: { Settings.clipboardHistoryMax },
            didChange: Self.didChange,
            failureSubsystem: "clipboard history",
            failureOperation: "save")
    }

    func startMonitoring() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Narrow guard for the one app-provoked pasteboard write that cannot carry the
    /// `SyntheticPasteboard` marker: `TargetResolver.captureSelectionViaCopy` synthesizes Cmd+C, so
    /// the FRONTMOST app writes the user's selection to the pasteboard. Blinds `poll()` for
    /// `interval` so that transient foreign write is never recorded. Deadline-based so it can never
    /// stick — capture always resumes when the window lapses. Main-thread-only, like the poll timer.
    func suppressCapture(for interval: TimeInterval) {
        suppressCaptureUntil = Date().addingTimeInterval(interval)
    }

    func all() -> [Entry] { log.all() }

    func clear() { log.clear() }

    /// Update the retention cap: persist it and trim immediately if the new cap is lower than the
    /// current count. Posts `didChange` so an open window refreshes.
    func setMaxEntries(_ newMax: Int) {
        Settings.clipboardHistoryMax = newMax
        log.trimToCap()
    }

    func copyToClipboard(_ entry: Entry) -> Bool {
        guard !entry.snapshot.isEmpty else { return false }
        SyntheticPasteboard.restore(entry.snapshot)
        return true
    }

    private func poll() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if Date() < suppressCaptureUntil { return }
        if SyntheticPasteboard.isMarked(pb) { return }
        captureCurrentPasteboard()
    }

    private func captureCurrentPasteboard() {
        let pb = NSPasteboard.general
        let text = ClipboardHistory.readPlainText(from: pb)
        if let text = text, Self.isSensitive(text) {
            Log.write("clipboard history skipped sensitive-looking text")
            return
        }

        let snapshot = PasteboardSnapshot.capture(from: pb, maxBytes: maxBytes)
        let items = pb.pasteboardItems ?? []
        let typeNames = Array(Set(items.flatMap { $0.types.map(\.rawValue) })).sorted()
        guard !snapshot.isEmpty || !typeNames.isEmpty else { return }

        let preview = Self.previewText(text: text, items: items, typeNames: typeNames)
        let detail = Self.detailText(snapshot: snapshot, items: items, typeNames: typeNames)
        let entry = Entry(id: UUID(), date: Date(), preview: preview, detail: detail,
                          types: typeNames, snapshot: snapshot)
        Log.write("clipboard history captured: \(preview.prefix(80))")
        record(entry)
    }

    /// Whether `candidate` duplicates the current head entry and should be dropped. The dedup
    /// identity is the display preview, the type set, AND the snapshot's byte count. The byte count
    /// is the content discriminator: without it two DISTINCT single images both preview as
    /// "1 copied image" with the same types, so a genuinely new screenshot copied right after
    /// another was silently dropped. `totalBytes` is already stored (zero added capture cost), and
    /// distinct content virtually never shares an exact byte count, so real re-copies still collapse
    /// while distinct copies are kept. Pure and `static` so the headless selftest can exercise it
    /// without the singleton/timer, and so the one identity rule lives in one place.
    static func isDuplicate(head: Entry?, candidate: Entry) -> Bool {
        head?.preview == candidate.preview
            && head?.types == candidate.types
            && head?.snapshot.totalBytes == candidate.snapshot.totalBytes
    }

    private func record(_ entry: Entry) {
        log.append(entry, if: { head in
            !Self.isDuplicate(head: head, candidate: entry)
        })
    }

    private static func readPlainText(from pasteboard: NSPasteboard) -> String? {
        if let s = pasteboard.string(forType: .string), !s.isEmpty { return s }
        if let data = pasteboard.data(forType: .rtf),
           let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil),
           !attr.string.isEmpty {
            return attr.string
        }
        if let data = pasteboard.data(forType: .html),
           let html = String(data: data, encoding: .utf8) {
            let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? nil : stripped
        }
        return nil
    }

    static func previewText(text: String?, items: [NSPasteboardItem], typeNames: [String]) -> String {
        if let text = text {
            let oneLine = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !oneLine.isEmpty { return String(oneLine.prefix(500)) }
        }
        if typeNames.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            return "\(items.count) copied file\(items.count == 1 ? "" : "s")"
        }
        if typeNames.contains(NSPasteboard.PasteboardType.tiff.rawValue)
            || typeNames.contains(NSPasteboard.PasteboardType.png.rawValue) {
            return "\(items.count) copied image\(items.count == 1 ? "" : "s")"
        }
        return "Clipboard item (\(typeNames.first ?? "unknown type"))"
    }

    static func detailText(snapshot: PasteboardSnapshot, items: [NSPasteboardItem], typeNames: [String]) -> String {
        if snapshot.isEmpty { return "Metadata only - too large or not restorable" }
        let bytes = snapshot.totalBytes
        let kb = max(1, Int(ceil(Double(bytes) / 1024.0)))
        if typeNames.contains(NSPasteboard.PasteboardType.string.rawValue) { return "Text - \(kb) KB" }
        if typeNames.contains(NSPasteboard.PasteboardType.rtf.rawValue) { return "Rich text - \(kb) KB" }
        if typeNames.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return "Files - \(items.count) item(s)" }
        if typeNames.contains(NSPasteboard.PasteboardType.tiff.rawValue)
            || typeNames.contains(NSPasteboard.PasteboardType.png.rawValue) {
            return "Image - \(kb) KB"
        }
        return "Clipboard data - \(kb) KB"
    }

    private static func isSensitive(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        let lower = text.lowercased()

        if lower.contains("-----begin") && lower.contains("private key-----") { return true }
        if text.range(of: #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
                      options: .regularExpression) != nil { return true }
        if text.range(of: #"(sk-|xox[baprs]-|gh[pousr]_|github_pat_)[A-Za-z0-9_\-]{20,}"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if text.range(of: #"(?i)(api[_-]?key|access[_-]?token|secret|password)\s*[:=]"#,
                      options: .regularExpression) != nil { return true }

        let words = text.split(whereSeparator: { $0.isWhitespace })
        let compact = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        if words.count <= 2 && compact.count >= 24 && compact.count <= 256
            && compact.range(of: #"^[A-Za-z0-9+/=_\-\.]+$"#, options: .regularExpression) != nil {
            let classes = [
                compact.range(of: #"[a-z]"#, options: .regularExpression) != nil,
                compact.range(of: #"[A-Z]"#, options: .regularExpression) != nil,
                compact.range(of: #"[0-9]"#, options: .regularExpression) != nil,
                compact.range(of: #"[+/=_\-.]"#, options: .regularExpression) != nil,
            ].filter { $0 }.count
            if classes >= 3 && uniqueRatio(compact) > 0.45 { return true }
        }
        return false
    }

    private static func uniqueRatio(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        return Double(Set(s).count) / Double(s.count)
    }
}

extension ClipboardHistory.Entry {
    /// Tolerant decode for `snapshot`: `load()` decodes the whole array with `try?`, so one bad
    /// entry would silently cost the entire history file. No app version has ever written a null
    /// or missing snapshot — map a hand-edited/corrupted one to the empty snapshot instead.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        preview = try c.decode(String.self, forKey: .preview)
        detail = try c.decode(String.self, forKey: .detail)
        types = try c.decode([String].self, forKey: .types)
        snapshot = (try? c.decode(PasteboardSnapshot.self, forKey: .snapshot))
            ?? PasteboardSnapshot(items: [], totalBytes: 0)
    }
}
