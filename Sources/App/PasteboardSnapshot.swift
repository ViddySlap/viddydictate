import Cocoa

/// A restorable capture of the general pasteboard.
///
/// The app uses the clipboard as a temporary bridge for universal Cmd+V insertion. Capturing the
/// raw pasteboard items lets us put the user's previous clipboard back after that synthetic paste.
/// Pure data: putting a snapshot back on the pasteboard is `SyntheticPasteboard.restore`, so every
/// app write carries the synthetic marker.
struct PasteboardSnapshot: Codable {
    struct StoredItem: Codable, Equatable {
        struct StoredType: Codable, Equatable {
            let name: String
            let data: Data
        }

        let types: [StoredType]
    }

    let items: [StoredItem]
    let totalBytes: Int

    var isEmpty: Bool { items.isEmpty }

    /// `maxBytes` is a persistence budget, not a capture policy: pass it only when the snapshot is
    /// being written to disk (`ClipboardHistory`, which owns the 10MB cap). The park/copy-capture
    /// callers hold a snapshot for seconds and put it right back, so they capture uncapped (the `nil`
    /// default) — a capped park could silently truncate or, when every representation is over budget,
    /// wipe the user's real clipboard on restore. A skipped over-budget type is logged so the loss is
    /// diagnosable.
    ///
    /// Never nil: "nothing restorable" (every representation skipped by the byte budget, or
    /// promise-only/empty data) is the EMPTY snapshot. `isEmpty` is the one honest signal to
    /// branch on — restoring an empty snapshot clears the pasteboard, which IS the faithful
    /// restore of an empty/unrestorable clipboard.
    static func capture(from pasteboard: NSPasteboard = .general,
                        maxBytes: Int? = nil) -> PasteboardSnapshot {
        var storedItems: [StoredItem] = []
        var total = 0

        for item in pasteboard.pasteboardItems ?? [] {
            var storedTypes: [StoredItem.StoredType] = []
            for type in item.types {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                if let maxBytes = maxBytes, total + data.count > maxBytes {
                    Log.write("pasteboard snapshot skipped over-budget type \(type.rawValue): \(data.count) bytes would exceed \(maxBytes)-byte budget")
                    continue
                }
                storedTypes.append(.init(name: type.rawValue, data: data))
                total += data.count
            }
            if !storedTypes.isEmpty {
                storedItems.append(.init(types: storedTypes))
            }
        }

        return PasteboardSnapshot(items: storedItems, totalBytes: total)
    }
}
