import Foundation

/// Headless verification of the infinite dictation-history store (L4). Run with
/// `--history-selftest`. No LM Studio, audio, or UI.
///
/// Every case runs against a fresh scratch directory under the OS temp dir (never the real app-local
/// store) and drives the toggle through `DictationHistoryStore`'s injectable `enabled` seam (never
/// `UserDefaults`), so it touches none of the user's real prefs or data. It proves the two locked contracts:
/// toggle OFF = zero writes (no directory, no file, no side effects); toggle ON = the correct per-day
/// file name, header + entry format, mode + timestamp labels, and append-accumulation across entries,
/// days, and reopened store instances. It also pins that the production default directory sits outside
/// any Obsidian vault.
enum DictationHistorySelfTest {

    static func run() -> Bool {
        print("--- dictation history store: infinite append-only per-day log (L4) ---\n")

        let reporter = SelfTestReporter()
        let check = reporter

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-history-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        // Fixed timestamps so both the filenames and the entry stamps are deterministic. Built in the
        // local timezone (as the store formats them), so the round-trip holds on any machine.
        let day1a = date(2026, 7, 6, 9, 5, 1)
        let day1b = date(2026, 7, 6, 14, 23, 47)
        let day1c = date(2026, 7, 6, 18, 0, 0)
        let day2  = date(2026, 7, 7, 0, 0, 5)

        // --- toggle OFF: zero writes, zero side effects ---
        let offDir = root.appendingPathComponent("off", isDirectory: true)
        let off = DictationHistoryStore(directory: offDir, enabled: { false })
        off.append(text: "must never be written", mode: "raw", at: day1a)
        off.flush()   // drain the queue so the assertion sees the final state
        check("toggle OFF creates no directory and no file",
              !fm.fileExists(atPath: offDir.path))

        // --- toggle ON: per-day files, format, labels, append ---
        let onDir = root.appendingPathComponent("on", isDirectory: true)
        let on = DictationHistoryStore(directory: onDir, enabled: { true })
        on.append(text: "first raw transcript", mode: "raw", at: day1a)
        on.append(text: "second, cleaned up", mode: "cleanup", at: day1b)
        on.append(text: "next day, one line", mode: "email", at: day2)
        on.flush()

        let file1 = onDir.appendingPathComponent("2026-07-06.md")
        let file2 = onDir.appendingPathComponent("2026-07-07.md")
        check("per-day file for day 1 exists", fm.fileExists(atPath: file1.path), file1.lastPathComponent)
        check("per-day file for day 2 exists", fm.fileExists(atPath: file2.path), file2.lastPathComponent)
        check("no stray files (exactly the two per-day files)",
              (try? fm.contentsOfDirectory(atPath: onDir.path))?.sorted() == ["2026-07-06.md", "2026-07-07.md"])

        let c1 = (try? String(contentsOf: file1, encoding: .utf8)) ?? ""
        let c2 = (try? String(contentsOf: file2, encoding: .utf8)) ?? ""

        check("new day file gets a dated header", c1.hasPrefix("# Dictation history 2026-07-06\n"))
        check("day-1 file accumulates both same-day entries",
              c1.contains("first raw transcript") && c1.contains("second, cleaned up"))
        check("day split: day-2 file holds only its own entry",
              c2.contains("next day, one line") && !c2.contains("first raw transcript"))
        check("entries labeled with mode",
              c1.contains("(raw)") && c1.contains("(cleanup)") && c2.contains("(email)"))
        check("entries labeled with a full timestamp",
              c1.contains("## 2026-07-06 09:05:01") && c1.contains("## 2026-07-06 14:23:47")
              && c2.contains("## 2026-07-07 00:00:05"))
        check("append order preserved (raw entry precedes the later cleanup entry)",
              orderedBefore("first raw transcript", "second, cleaned up", in: c1))

        // --- append is additive across store instances (reopen the same day file, never truncate) ---
        let onReopened = DictationHistoryStore(directory: onDir, enabled: { true })
        onReopened.append(text: "third, later same day", mode: "search", at: day1c)
        onReopened.flush()
        let c1b = (try? String(contentsOf: file1, encoding: .utf8)) ?? ""
        check("reopening a day file appends, never truncates",
              c1b.contains("first raw transcript") && c1b.contains("second, cleaned up")
              && c1b.contains("third, later same day"))
        check("reopened file keeps exactly one header",
              c1b.components(separatedBy: "# Dictation history 2026-07-06").count == 2)

        // --- blank delivered text is a defensive no-op (caller already guards, so does the store) ---
        let blankDir = root.appendingPathComponent("blank", isDirectory: true)
        let blank = DictationHistoryStore(directory: blankDir, enabled: { true })
        blank.append(text: "   \n\t  ", mode: "raw", at: day1a)
        blank.flush()
        check("blank delivered text writes nothing",
              !fm.fileExists(atPath: blankDir.appendingPathComponent("2026-07-06.md").path))

        // --- production default directory is app-local, outside any Obsidian vault ---
        let defPath = DictationHistoryStore.defaultDirectory().path
        check("default store dir is app-local, outside the vaults",
              defPath.hasSuffix("/Library/Application Support/ViddyDictate/history")
              && !defPath.contains("ViddyVault") && !defPath.lowercased().contains("obsidian"),
              defPath)

        print("\n=== RESULT ===")
        print(reporter.passed ? "\nGREEN BAR CLEARED ✅" : "\nGREEN BAR NOT CLEARED ❌")
        return reporter.passed
    }

    /// True iff the first occurrence of `a` precedes the first occurrence of `b` in `text` (both present).
    private static func orderedBefore(_ a: String, _ b: String, in text: String) -> Bool {
        guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
        return ra.lowerBound < rb.lowerBound
    }

    /// A local-timezone `Date` from wall-clock components (matches how the store formats its stamps).
    private static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return cal.date(from: c)!
    }
}
