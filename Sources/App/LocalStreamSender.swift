import Foundation

/// Stall-based timeout behaviour for the opted-in LM Studio streaming sender.
///
/// The fixed `Settings.cleanupTimeout` (12 s) was a total ceiling, which kills a reasoning model that
/// is thinking for 20-60 s while still making progress. An opted-in request is read as an SSE stream
/// instead, and the only ways it can fail are (1) no byte of progress for the stall window, or
/// (2) the absolute hard ceiling, so a trickle cannot hold the user hostage. Both are the same
/// `URLError.timedOut` the callers already classify.
///
/// The clock is injected (see `LocalStreamProgressClock`) so a test drives minutes in microseconds.
struct LocalStreamStallPolicy: Equatable {
    let stallWindow: TimeInterval
    let hardCeiling: TimeInterval

    /// The fallback stall window when a request carries no positive timeout (today's cleanup value).
    static let defaultStallWindow: TimeInterval = 12
    /// The floor under the hard ceiling, so even a very short stall window leaves a model room to answer.
    static let minimumHardCeiling: TimeInterval = 45

    init(stallWindow: TimeInterval) {
        let window = stallWindow > 0 ? stallWindow : Self.defaultStallWindow
        self.stallWindow = window
        // The absolute cap on one request: max(4 x stall window, 45 s), so an endless trickle still ends.
        self.hardCeiling = max(4 * window, Self.minimumHardCeiling)
    }

    /// The window comes from the request's own `timeoutInterval` (today's 12 s cleanup timeout).
    init(request: URLRequest) {
        self.init(stallWindow: request.timeoutInterval)
    }

    /// Which limit fired, if any.
    enum Verdict: Equatable {
        case stalled   // no byte of progress for `stallWindow`
        case ceiling   // the request has run for `hardCeiling` no matter how much progress it made
    }

    /// The transport error a fired limit reports: exactly the `URLError.timedOut` the callers classify.
    static func timedOutError() -> URLError { URLError(.timedOut) }
}

/// Pure progress clock for one streaming request: request start, the last byte-arrival time, and the
/// verdict at an injected `now`. Every received chunk (content, reasoning, or even bytes a parser
/// could not decode) calls `recordProgress`.
struct LocalStreamProgressClock {
    let policy: LocalStreamStallPolicy
    let startedAt: Date
    private(set) var lastProgressAt: Date

    init(policy: LocalStreamStallPolicy, startedAt: Date) {
        self.policy = policy
        self.startedAt = startedAt
        self.lastProgressAt = startedAt
    }

    mutating func recordProgress(at now: Date) {
        lastProgressAt = now
    }

    /// The ceiling is checked first: a stream that is trickling is still over the absolute cap.
    func verdict(at now: Date) -> LocalStreamStallPolicy.Verdict? {
        if now.timeIntervalSince(startedAt) >= policy.hardCeiling { return .ceiling }
        if now.timeIntervalSince(lastProgressAt) >= policy.stallWindow { return .stalled }
        return nil
    }
}

/// Incremental OpenAI-compatible SSE parser for an opted-in chat completion.
///
/// It never throws. `content` and `reasoning_content` deltas accumulate (a model that is thinking is
/// making progress), `[DONE]` ends the stream, event lines split across network chunks are joined,
/// keep-alive comment lines are ignored, and malformed JSON in one event is skipped. Which bytes
/// count as *progress* is the sender's decision: every non-empty chunk resets the stall clock.
struct LocalStreamAccumulator {
    private var buffer = Data()
    private(set) var content = ""
    private(set) var reasoningContent = ""
    private(set) var usage: [String: Any]?
    private(set) var sawDone = false

    /// Feed one network chunk. Returns true when it carried at least one byte (progress).
    mutating func consume(_ chunk: Data) -> Bool {
        guard !chunk.isEmpty else { return false }
        buffer.append(chunk)
        let newline = Data([0x0A])
        while let range = buffer.range(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            handle(line: String(decoding: lineData, as: UTF8.self))
        }
        return true
    }

    private mutating func handle(line raw: String) {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        // Keep-alive comments start with ':'; event:, id: and retry: carry nothing this parser needs.
        guard line.hasPrefix("data:") else { return }
        var payload = String(line.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        if payload == "[DONE]" {
            sawDone = true
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        else { return } // malformed JSON in one event: bytes already counted as progress, skip it
        if let value = object["usage"] as? [String: Any] { usage = value }
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else { return }
        if let text = delta["content"] as? String { content += text }
        if let text = delta["reasoning_content"] as? String { reasoningContent += text }
    }

    /// The exact non-stream JSON shape the callers already parse
    /// (`choices[0].message.content`, optional `reasoning_content`, optional `usage`).
    func reassembledJSON() -> Data {
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !reasoningContent.isEmpty { message["reasoning_content"] = reasoningContent }
        var root: [String: Any] = [
            "choices": [["index": 0, "message": message, "finish_reason": "stop"]],
        ]
        if let usage { root["usage"] = usage }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
}

/// The LM Studio send closure the transport uses: a plain `dataTask` for an ordinary request, and the
/// streaming sender for one that opted in with `LocalStreamSender.progressHeader`.
///
/// `session` is the seam: production passes `URLSession.shared`; a deterministic test injects a session
/// whose `configuration.protocolClasses` script the wire with no socket and no real network.
enum LocalStreamSender {
    /// The request header that opts one LM Studio chat into the streaming progress path.
    static let progressHeader = "X-ViddyDictate-Progress-Timeout"

    static func sender(session: URLSession = .shared)
        -> (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void {
        { request, completion in
            if request.value(forHTTPHeaderField: progressHeader) == "1" {
                LocalStreamingRequest(baseSession: session, request: request, completion: completion).start()
            } else {
                session.dataTask(with: request, completionHandler: completion).resume()
            }
        }
    }
}

/// One opted-in request read as an SSE stream. The task is cancelled the moment either limit fires,
/// so no connection is leaked.
private final class LocalStreamingRequest: NSObject, URLSessionDataDelegate {
    private let baseSession: URLSession
    private let request: URLRequest
    private let completion: (Data?, URLResponse?, Error?) -> Void
    private let policy: LocalStreamStallPolicy
    private let lock = NSLock()

    private var accumulator = LocalStreamAccumulator()
    private var rawBody = Data()
    private var httpResponse: HTTPURLResponse?
    private var startedAt = Date()
    private var lastProgressAt = Date()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchSourceTimer?
    private var finished = false

    init(baseSession: URLSession, request: URLRequest,
         completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        self.baseSession = baseSession
        self.request = request
        self.completion = completion
        self.policy = LocalStreamStallPolicy(request: request)
    }

    func start() {
        // Copy the injected session's configuration so its URLProtocol classes survive, and give the
        // request the full hard ceiling so URLSession's own idle timer never pre-empts this policy.
        let configuration = (baseSession.configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let streamRequest = Self.streamingRequest(from: request, timeout: policy.hardCeiling)
        let task = session.dataTask(with: streamRequest)
        let now = Date()
        lock.lock()
        self.session = session
        self.startedAt = now
        self.lastProgressAt = now
        self.task = task
        lock.unlock()
        startTimer()
        task.resume()
    }

    /// A COPY of the request with `"stream": true` set on the decoded body; every other key (including
    /// a `reasoning_effort` the reasoning-off chain added) is preserved.
    private static func streamingRequest(from request: URLRequest, timeout: TimeInterval) -> URLRequest {
        var out = request
        out.timeoutInterval = timeout
        guard let body = request.httpBody,
              var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return out
        }
        object["stream"] = true
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            out.httpBody = data
        }
        return out
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        let interval = max(0.02, policy.stallWindow / 4)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.checkLimits() }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    private func checkLimits() {
        lock.lock()
        let finished = self.finished
        let startedAt = self.startedAt
        let lastProgressAt = self.lastProgressAt
        lock.unlock()
        guard !finished else { return }
        let now = Date()
        if now.timeIntervalSince(startedAt) >= policy.hardCeiling
            || now.timeIntervalSince(lastProgressAt) >= policy.stallWindow {
            failTimeout()
        }
    }

    private func failTimeout() {
        guard finishTimeout(response: responseSnapshot()) else { return }
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func finishTimeout(response: URLResponse?) -> Bool {
        lock.lock()
        if finished { lock.unlock(); return false }
        finished = true
        let timer = self.timer
        self.timer = nil
        let session = self.session
        lock.unlock()
        timer?.cancel()
        session?.finishTasksAndInvalidate()
        completion(nil, response, LocalStreamStallPolicy.timedOutError())
        return true
    }

    private func responseSnapshot() -> URLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return httpResponse
    }

    @discardableResult
    private func finish(data: Data?, response: URLResponse?, error: Error?) -> Bool {
        lock.lock()
        if finished { lock.unlock(); return false }
        finished = true
        let timer = self.timer
        self.timer = nil
        let session = self.session
        lock.unlock()
        timer?.cancel()
        session?.finishTasksAndInvalidate()
        completion(data, response, error)
        return true
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            lock.lock()
            httpResponse = http
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if finished { lock.unlock(); return }
        lastProgressAt = Date()
        var sawDone = false
        if let http = httpResponse, !(200..<300).contains(http.statusCode) {
            rawBody.append(data) // a non-2xx body is error JSON, not SSE: keep it byte-for-byte
        } else {
            _ = accumulator.consume(data)
            // SSE `[DONE]` is the model's own end-of-answer marker: the transport may keep the
            // connection open (keep-alive), so finish here rather than waiting for it to close.
            sawDone = accumulator.sawDone
        }
        let http = httpResponse
        let assembled = sawDone ? accumulator.reassembledJSON() : nil
        lock.unlock()
        guard sawDone else { return }
        // Complete exactly once with the reassembled non-stream body and the real response. `finish`
        // cancels the polling timer and invalidates the session; cancelling the task releases the
        // connection, and a later `didCompleteWithError`/timer callback sees `finished` and is a no-op.
        if finish(data: assembled, response: http, error: nil) {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if finished { lock.unlock(); return }
        let http = httpResponse
        let accumulator = self.accumulator
        let raw = rawBody
        lock.unlock()
        if let error {
            finish(data: nil, response: http, error: error)
            return
        }
        if let http, !(200..<300).contains(http.statusCode) {
            finish(data: raw, response: http, error: nil)
            return
        }
        finish(data: accumulator.reassembledJSON(), response: http, error: nil)
    }
}
