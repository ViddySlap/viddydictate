import Foundation

/// Preview rule for the recent-dictations pop-up (item 6): a take of 100 Characters or fewer is
/// returned whole; longer text is `prefix(50)` + "\u{2026}" + `suffix(50)` by Swift `Character`,
/// never UTF-16 offsets, so an emoji (a single grapheme) is never split. Newlines are kept here;
/// the row label shows them as spaces.
enum HistoryPreview {
    static func preview(_ s: String, maxPrefix: Int = 50, maxSuffix: Int = 50) -> String {
        if s.count <= 100 { return s }
        return String(s.prefix(maxPrefix)) + "\u{2026}" + String(s.suffix(maxSuffix))
    }
}
