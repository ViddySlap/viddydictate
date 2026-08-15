import Cocoa

/// The one owner of every pasteboard write ViddyDictate performs itself: the Cmd+V bridge text,
/// clipboard park + restore, copy-to-clipboard fallbacks, and history-entry restores.
///
/// Every write stamps an app-private marker type on the written item, and `ClipboardHistory.poll()`
/// skips a pasteboard that carries the marker — so the app's own writes never land in the user's
/// clipboard history. The marker travels with the data, so there is no per-call-site bookkeeping
/// (the old ignore-changeCount convention) to get right or race: writing through this type IS the
/// whole rule.
///
/// The one pasteboard write the app provokes but cannot mark is the synthetic Cmd+C in
/// `TargetResolver.captureSelectionViaCopy` — the FRONTMOST app performs that write. That flow is
/// covered by `ClipboardHistory.suppressCapture(for:)` instead; see the comment there.
enum SyntheticPasteboard {
    private final class MarkedURL: NSObject, NSPasteboardWriting {
        private let wrapped: NSURL

        init(url: URL) {
            wrapped = url as NSURL
        }

        func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
            let types = wrapped.writableTypes(for: pasteboard)
            return types.contains(markerType) ? types : types + [markerType]
        }

        func writingOptions(forType type: NSPasteboard.PasteboardType,
                            pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
            type == markerType ? [] : wrapped.writingOptions(forType: type, pasteboard: pasteboard)
        }

        func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
            type == markerType ? Data() : wrapped.pasteboardPropertyList(forType: type)
        }
    }

    /// App-private marker stamped on every synthetic write. Other apps ignore unknown types. The
    /// marker's data is deliberately empty: `PasteboardSnapshot.capture` skips empty-data types, so
    /// snapshots never carry the marker and `restore` re-stamps it — the stamp exists only here.
    static let markerType = NSPasteboard.PasteboardType(AppIdentity.queueLabel("synthetic"))

    /// Replace the pasteboard with plain text, marked.
    static func write(_ text: String, to pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: markerType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Replace the pasteboard with file URLs, preserving NSURL's native representations while
    /// stamping the synthetic marker on every item.
    static func writeURLs(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { makeURLWriter($0) })
    }

    /// Deterministic seam for inspecting the same writer objects `writeURLs` sends to AppKit.
    static func makeURLWriter(_ url: URL) -> NSPasteboardWriting {
        MarkedURL(url: url)
    }

    /// Put a captured snapshot back on the pasteboard, marked (a restore is still the app writing).
    /// Restoring an empty snapshot clears the pasteboard — the faithful restore of an empty or
    /// unrestorable clipboard. That bare clear carries no marker (there is no item to stamp), which
    /// is safe: `ClipboardHistory` never records an empty pasteboard.
    static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard = .general) {
        let pbItems = snapshot.items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for value in stored.types {
                item.setData(value.data, forType: NSPasteboard.PasteboardType(value.name))
            }
            return item
        }
        pbItems.first?.setData(Data(), forType: markerType)
        pasteboard.clearContents()
        pasteboard.writeObjects(pbItems)
    }

    /// True when the current pasteboard contents were written by the app.
    static func isMarked(_ pasteboard: NSPasteboard = .general) -> Bool {
        (pasteboard.pasteboardItems ?? []).contains { $0.types.contains(markerType) }
    }
}
