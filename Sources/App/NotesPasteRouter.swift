import Cocoa

/// The routing decision for a Cmd+V inside a notes window: does the
/// pasteboard's payload belong in the attachment tray (image/video) or in the CodeMirror editor (text)?
///
/// The decision is a PURE function over a `NotesPasteDescriptor` so `--notes-probe` can assert it against
/// synthetic pasteboard shapes headlessly — the real Cmd+V exercise (an actual NSPasteboard read + web-view
/// interception) is GUI-only and covered by real-app verification. The interception seam is
/// `FirstMouseWebView.performKeyEquivalent`, which builds the descriptor from `NSPasteboard.general`, calls
/// `decide`, and on `.tray` routes the resolved items through the SAME `onDrop` path a drag-drop uses (the
/// existing `NotesAttachmentCoordinator`) — never a second attachment path, never a markdown-body embed.
enum NotesPasteRoute: Equatable {
    /// Image/video content — route to the attachment tray via the existing drop/attachment path.
    case tray
    /// Existing markdown file URLs use the same file-backed-tab arm as drag-in.
    case markdownFiles
    /// Plain text (or a non-media file) — let CodeMirror handle the paste as today.
    case editor
}

/// A pasteboard reduced to just what the routing decision needs: the file-URL extensions it carries (in
/// order) and whether it carries raw image bytes (a copied screenshot). Keeping this a plain value makes the
/// decision testable without a live NSPasteboard.
struct NotesPasteDescriptor: Equatable {
    let fileURLExtensions: [String]
    let hasRawImage: Bool
}

enum NotesPasteRouter {

    /// The routing rule. Mirrors the drag-drop resolver's precedence (`NotesDropWebView.resolveDrop`): file
    /// URLs are considered first, then raw image bytes.
    ///   - File URLs present: route to the tray iff AT LEAST ONE is an accepted image/video type (a paste of a
    ///     non-media file — a .pdf, a .txt — falls through to the editor, exactly as today). The tray route
    ///     then hands every file URL to the coordinator, which rejects any non-media sibling with the same
    ///     toast a drop would.
    ///   - No file URLs, raw image bytes present: route to the tray (a copied screenshot). On a mixed
    ///     image+text paste the image wins and the text is ignored for that paste.
    ///   - Otherwise: the editor (plain text, as today).
    static func decide(_ descriptor: NotesPasteDescriptor) -> NotesPasteRoute {
        if !descriptor.fileURLExtensions.isEmpty {
            if descriptor.fileURLExtensions.contains(where: { $0.lowercased() == "md" }) {
                return .markdownFiles
            }
            let anyMedia = descriptor.fileURLExtensions.contains {
                MediaSniffer.mediaKind(forExtension: $0) != nil
            }
            return anyMedia ? .tray : .editor
        }
        return descriptor.hasRawImage ? .tray : .editor
    }

    /// True for a bare Cmd+V key-down (no extra modifiers), the shortcut we intercept.
    static func isPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == .command && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// Reduce a live pasteboard to the descriptor the decision consumes. Raw-image detection mirrors
    /// `FirstMouseWebView.rawImage` (png/tiff bytes, else an NSImage-readable pasteboard) so the decision and
    /// the item resolution agree.
    static func descriptor(for pb: NSPasteboard) -> NotesPasteDescriptor {
        let urls = (pb.readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return NotesPasteDescriptor(fileURLExtensions: urls.map { $0.pathExtension },
                                    hasRawImage: pasteboardHasRawImage(pb))
    }

    static func pasteboardHasRawImage(_ pb: NSPasteboard) -> Bool {
        if pb.data(forType: .png) != nil { return true }
        if pb.data(forType: .tiff) != nil { return true }
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }
}
