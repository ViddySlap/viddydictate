import Foundation

/// Pure media-sniffing / attachment-ordering helpers, extracted verbatim from
/// StickyNotesStore (zero-behavior code motion). These take no store instance state; the
/// accepted-extension sets and the AttachmentKind type still live on StickyNotesStore and
/// are referenced here by qualified name. Callers invoke MediaSniffer.imageExtension(...) etc.
enum MediaSniffer {
    /// Detect an accepted image format from the leading magic bytes, or nil if the data is not one.
    static func imageExtension(forData data: Data) -> String? {
        let n = data.count
        func byte(_ i: Int) -> UInt8 { data[data.index(data.startIndex, offsetBy: i)] }
        if n >= 8, byte(0) == 0x89, byte(1) == 0x50, byte(2) == 0x4E, byte(3) == 0x47,
           byte(4) == 0x0D, byte(5) == 0x0A, byte(6) == 0x1A, byte(7) == 0x0A { return "png" }
        if n >= 3, byte(0) == 0xFF, byte(1) == 0xD8, byte(2) == 0xFF { return "jpg" }
        if n >= 6, byte(0) == 0x47, byte(1) == 0x49, byte(2) == 0x46, byte(3) == 0x38 { return "gif" }
        if n >= 12, byte(0) == 0x52, byte(1) == 0x49, byte(2) == 0x46, byte(3) == 0x46,
           byte(8) == 0x57, byte(9) == 0x45, byte(10) == 0x42, byte(11) == 0x50 { return "webp" }
        return nil
    }

    static func mediaKind(forExtension rawExt: String) -> StickyNotesStore.AttachmentKind? {
        let ext = rawExt.lowercased()
        if StickyNotesStore.allowedImageExtensions.contains(ext) { return .image }
        if StickyNotesStore.allowedVideoExtensions.contains(ext) { return .video }
        return nil
    }

    /// The leading integer of a stored filename (`01-shot.png` -> 1); `Int.max` when there is no prefix so
    /// unexpected files sort last rather than first.
    static func numericPrefix(of filename: String) -> Int {
        var digits = ""
        for ch in filename { if ch.isNumber { digits.append(ch) } else { break } }
        return Int(digits) ?? Int.max
    }
}
