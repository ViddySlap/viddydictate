import Foundation

/// The web-search backend for the search modes (Option+L / Option+G). Shells to the production venv
/// helper (`~/.local/share/viddydictate/websearch.py`, a `ddgs` wrapper) and parses its JSON.
///
/// Why a Python helper, not native Swift HTML scraping or the zero-dep Node web MCP server: the
/// process-shape bench proved DuckDuckGo's raw HTML endpoint walls off scrapers with a 202 anomaly
/// response (0 parseable results). The maintained `ddgs` library rotates html/lite/api backends and
/// backs off, so it is the robust source — and it is the SAME backend the signed-off bench used, so
/// the production results match what was judged. Node is already an app dependency (the keep-alive),
/// and Python is the search source; consistent with how the app already shells to `lms` and the STT
/// daemon. The helper + venv live at stable absolute paths under ~/.local/share (out of the synced
/// vault), installed by `install-websearch-helper.sh`.
enum WebSearchBackend {

    /// One search hit (mirrors the bench's result shape).
    struct Result { let title: String; let href: String; let body: String }

    private static let venvPython = "\(NSHomeDirectory())/.local/share/viddydictate/venv/bin/python"
    private static let helper = "\(NSHomeDirectory())/.local/share/viddydictate/websearch.py"

    /// Build the complete helper transport in one pure seam so the argv/stdin privacy contract is
    /// deterministic and directly testable. The helper path is the only argv element; all user text
    /// and the result cap travel in the JSON stdin request.
    static func processTransport(query: String, maxResults: Int) -> (arguments: [String], stdin: Data)? {
        let request: [String: Any] = ["query": query, "maxResults": maxResults]
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
            return nil
        }
        return ([helper], data)
    }

    static func parseFailureLogLine(query: String, outputBytes: Int) -> String {
        "websearch: classification=parse_failure query_bytes=\(query.utf8.count) output_bytes=\(outputBytes)"
    }

    static func successLogLine(query: String, resultCount: Int) -> String {
        "websearch: classification=success query_bytes=\(query.utf8.count) results=\(resultCount)"
    }

    /// Whether the backend is installed (both the venv python and the helper exist). Used by the
    /// selftest + the controller to surface a clean "run install-websearch-helper.sh" message rather
    /// than a cryptic failure.
    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: venvPython) && fm.isReadableFile(atPath: helper)
    }

    /// Synchronous DuckDuckGo search via the helper. Returns [] on any failure (missing backend,
    /// launch error, timeout, throttle) so the caller degrades gracefully to "no results". Blocks the
    /// calling thread — call OFF the main thread (the agentic loop runs on a background queue).
    static func search(_ query: String, maxResults: Int = 6, timeout: TimeInterval = 30) -> [Result] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        guard isInstalled else {
            Log.write("websearch: classification=backend_not_installed")
            return []
        }
        guard let transport = processTransport(query: q, maxResults: maxResults) else {
            Log.write("websearch: classification=request_encode_failed")
            return []
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: venvPython)
        proc.arguments = transport.arguments
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()   // discard the helper's stderr diagnostics
        do { try proc.run() } catch {
            inPipe.fileHandleForWriting.closeFile()
            Log.write("websearch: classification=process_launch_failed")
            return []
        }
        inPipe.fileHandleForWriting.write(transport.stdin)
        inPipe.fileHandleForWriting.closeFile()
        // Watchdog: ddgs can stall on a flaky network; kill anything pathological past the timeout.
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        killer.cancel()

        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Log.write(parseFailureLogLine(query: q, outputBytes: data.count))
            return []
        }
        let results = arr.map {
            Result(title: ($0["title"] as? String) ?? "",
                   href: ($0["href"] as? String) ?? "",
                   body: ($0["body"] as? String) ?? "")
        }
        Log.write(successLogLine(query: q, resultCount: results.count))
        return results
    }

    /// Format a result set into the numbered title / body / url block the bench fed the models.
    /// Coupled to the SYNTH_PROMPT + agentic tool-result wording.
    static func format(_ results: [Result]) -> String {
        guard !results.isEmpty else { return "(no results)" }
        return results.enumerated().map { i, r in
            "[\(i + 1)] \(r.title)\n\(r.body)\n(\(r.href))"
        }.joined(separator: "\n\n")
    }
}
