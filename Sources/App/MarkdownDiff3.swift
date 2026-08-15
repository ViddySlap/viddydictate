import Foundation

/// A line-level three-way merge for markdown bodies. Swift's collection-difference engine supplies the two
/// base-relative edit scripts; contiguous changed lines naturally form blocks. This intentionally never splits
/// prose into fixed word chunks: two edits to the same source line conflict, while edits to distinct lines or
/// blocks compose without conflict.
enum MarkdownDiff3 {
    enum Result: Equatable {
        case merged(String)
        case conflict
    }

    private struct Edit: Equatable {
        let baseRange: Range<Int>
        let replacement: [String]
    }

    static func merge(base: String, mine: String, theirs: String) -> Result {
        if mine == theirs { return .merged(mine) }
        if mine == base { return .merged(theirs) }
        if theirs == base { return .merged(mine) }

        let baseLines = linesPreservingEndings(base)
        let mineLines = linesPreservingEndings(mine)
        let theirLines = linesPreservingEndings(theirs)
        guard let mineEdits = edits(from: baseLines, to: mineLines),
              let theirEdits = edits(from: baseLines, to: theirLines) else {
            return .conflict
        }

        var combined = mineEdits
        for theirEdit in theirEdits {
            // The same change made independently is already present and needs applying only once.
            if mineEdits.contains(theirEdit) { continue }
            // Only edits that touch the same source line (or insert at the same boundary) conflict. An
            // insertion exactly before/after another side's changed block remains non-overlapping.
            if mineEdits.contains(where: { overlaps($0.baseRange, theirEdit.baseRange) }) {
                return .conflict
            }
            combined.append(theirEdit)
        }

        combined.sort {
            if $0.baseRange.lowerBound != $1.baseRange.lowerBound {
                return $0.baseRange.lowerBound < $1.baseRange.lowerBound
            }
            if $0.baseRange.isEmpty != $1.baseRange.isEmpty {
                return $0.baseRange.isEmpty
            }
            return $0.baseRange.upperBound < $1.baseRange.upperBound
        }

        var cursor = 0
        var merged: [String] = []
        for edit in combined {
            guard cursor <= edit.baseRange.lowerBound else { return .conflict }
            merged.append(contentsOf: baseLines[cursor..<edit.baseRange.lowerBound])
            merged.append(contentsOf: edit.replacement)
            cursor = edit.baseRange.upperBound
        }
        merged.append(contentsOf: baseLines[cursor..<baseLines.count])
        return .merged(merged.joined())
    }

    private static func linesPreservingEndings(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            guard let newline = text[start...].firstIndex(of: "\n") else {
                lines.append(String(text[start...]))
                break
            }
            let next = text.index(after: newline)
            lines.append(String(text[start..<next]))
            start = next
        }
        return lines
    }

    /// Convert CollectionDifference's removal offsets (in base) and insertion offsets (in target) into
    /// base-relative replacement hunks. A mismatch outside marked changes fails closed instead of guessing.
    private static func edits(from base: [String], to target: [String]) -> [Edit]? {
        let difference = target.difference(from: base)
        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }

        var edits: [Edit] = []
        var baseIndex = 0
        var targetIndex = 0
        while baseIndex < base.count || targetIndex < target.count {
            let removesHere = baseIndex < base.count && removals.contains(baseIndex)
            let insertsHere = targetIndex < target.count && insertions.contains(targetIndex)
            if !removesHere && !insertsHere {
                guard baseIndex < base.count, targetIndex < target.count,
                      base[baseIndex] == target[targetIndex] else { return nil }
                baseIndex += 1
                targetIndex += 1
                continue
            }

            let start = baseIndex
            var replacement: [String] = []
            repeat {
                while targetIndex < target.count && insertions.contains(targetIndex) {
                    replacement.append(target[targetIndex])
                    targetIndex += 1
                }
                while baseIndex < base.count && removals.contains(baseIndex) {
                    baseIndex += 1
                }
            } while (baseIndex < base.count && removals.contains(baseIndex))
                || (targetIndex < target.count && insertions.contains(targetIndex))
            edits.append(Edit(baseRange: start..<baseIndex, replacement: replacement))
        }
        return edits
    }

    private static func overlaps(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        if lhs.isEmpty && rhs.isEmpty { return lhs.lowerBound == rhs.lowerBound }
        if lhs.isEmpty {
            return rhs.lowerBound < lhs.lowerBound && lhs.lowerBound < rhs.upperBound
        }
        if rhs.isEmpty {
            return lhs.lowerBound < rhs.lowerBound && rhs.lowerBound < lhs.upperBound
        }
        return max(lhs.lowerBound, rhs.lowerBound) < min(lhs.upperBound, rhs.upperBound)
    }
}
