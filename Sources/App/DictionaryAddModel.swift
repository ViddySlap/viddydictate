import Foundation

/// The pure model behind the add-to-dictionary pop-up (right-Option+D): which existing entries look like
/// what is being typed (a ranked search), and whether the typed pair may be added (a verdict). Foundation
/// only, no store and no UI, so it compiles and is checked on Linux as well as in the app.

enum DictionaryColumn: String, Equatable {
    case hardCoded, contextAware
}

/// One existing dictionary row, tagged with the column it lives in.
struct DictionaryAddEntry: Equatable {
    let heard: String
    let intended: String
    let column: DictionaryColumn
}

enum DictionaryAddModel {
    /// The most rows the pop-up lists.
    static let maxHints = 5

    /// Lowercase, split on any whitespace (tabs, newlines, no-break spaces), join with one space.
    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .joined(separator: " ")
            .lowercased()
    }

    /// How an entry matched the query, best first. An entry gets the best tier it reaches.
    enum Tier: Int, Comparable {
        case exact = 0, heardPrefix, heardWordPrefix, heardContains, intendedContains, near

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    struct Match: Equatable {
        let entry: DictionaryAddEntry
        let tier: Tier
        /// Edit distance for a near match; 0 for every other tier.
        let distance: Int
    }

    /// Levenshtein distance over Characters.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// The largest edit distance that still counts as a near-miss for a query of `n` characters:
    /// none under 3 characters, 1 up to 5, 2 beyond.
    static func nearLimit(forLength n: Int) -> Int {
        if n < 3 { return -1 }
        return n <= 5 ? 1 : 2
    }

    /// Existing entries that look like `query`, best first, at most `limit`. Nothing for a blank query.
    /// Order: tier, edit distance, shorter normalized heard text, hard-coded before context-aware, then
    /// normalized heard, normalized intended, raw heard, raw intended (plain `<` on String), so the result
    /// never depends on the order of `entries`.
    static func search(query: String, entries: [DictionaryAddEntry], limit: Int = maxHints) -> [Match] {
        let q = normalize(query)
        guard !q.isEmpty, limit > 0 else { return [] }
        let qChars = Array(q)
        let maxNear = nearLimit(forLength: qChars.count)

        struct Keyed { let match: Match; let heard: String; let intended: String }
        var found: [Keyed] = []
        for entry in entries {
            let h = normalize(entry.heard)
            let i = normalize(entry.intended)
            var tier: Tier?
            var distance = 0
            let words = h.split(separator: " ").map { String($0) }
            if h == q {
                tier = .exact
            } else if h.hasPrefix(q) {
                tier = .heardPrefix
            } else if words.contains(where: { $0.hasPrefix(q) }) {
                tier = .heardWordPrefix
            } else if h.range(of: q) != nil {
                tier = .heardContains
            } else if i.range(of: q) != nil {
                tier = .intendedContains
            } else if maxNear >= 0 {
                var best = editDistance(qChars, Array(h))
                for w in words { best = min(best, editDistance(qChars, Array(w))) }
                if best <= maxNear {
                    tier = .near
                    distance = best
                }
            }
            if let tier = tier {
                found.append(Keyed(match: Match(entry: entry, tier: tier, distance: distance), heard: h, intended: i))
            }
        }

        found.sort { a, b in
            if a.match.tier != b.match.tier { return a.match.tier < b.match.tier }
            if a.match.distance != b.match.distance { return a.match.distance < b.match.distance }
            if a.heard.count != b.heard.count { return a.heard.count < b.heard.count }
            if a.match.entry.column != b.match.entry.column { return a.match.entry.column == .hardCoded }
            if a.heard != b.heard { return a.heard < b.heard }
            if a.intended != b.intended { return a.intended < b.intended }
            if a.match.entry.heard != b.match.entry.heard { return a.match.entry.heard < b.match.entry.heard }
            return a.match.entry.intended < b.match.entry.intended
        }
        return found.prefix(limit).map { $0.match }
    }

    enum Verdict: Equatable {
        case blank
        case duplicate(DictionaryAddEntry)
        case ok
    }

    /// `.blank` when either side has no visible text; `.duplicate(first listed entry)` when an entry in
    /// either column has the same normalized "heard" text, whatever its "intended" side says; else `.ok`.
    /// A near-miss never blocks.
    static func verdict(heard: String, intended: String, entries: [DictionaryAddEntry]) -> Verdict {
        let h = normalize(heard)
        if h.isEmpty || normalize(intended).isEmpty { return .blank }
        if let hit = entries.first(where: { normalize($0.heard) == h }) { return .duplicate(hit) }
        return .ok
    }
}
