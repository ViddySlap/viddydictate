import Foundation

/// Talks to the local warm STT daemon (`viddydictate_whisperd.py`) on 127.0.0.1:8765,
/// and wakes it on demand via launchd (see spec "Daemon lifecycle", ADR 0008).
enum DaemonClient {
    static let base = URL(string: "http://127.0.0.1:8765")!
    static let agentLabel = "com.viddydictate.whisperd"
    private static let modelLock = NSLock()
    private static var _lastKnownModel: String?

    private static var lastKnownModel: String? {
        get { modelLock.lock(); defer { modelLock.unlock() }; return _lastKnownModel }
        set { modelLock.lock(); _lastKnownModel = newValue; modelLock.unlock() }
    }

    /// The three distinguishable answers to "is the daemon up". `health` below collapses the two failure
    /// shapes into one Boolean because that is all its callers need; preflight (W5) needs them apart,
    /// since "it answered and is still loading its model" and "nothing answered at all" send a user to
    /// different remedies.
    enum HealthOutcome: Equatable {
        case ready(model: String)
        case notReady(detail: String)
        case unreachable(detail: String)
    }

    /// GET /health. A transport error or an unparseable body is `unreachable`: in both cases nothing
    /// usable is listening on the port, whatever the socket did.
    static func healthOutcome(completion: @escaping (HealthOutcome) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 2.0
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { completion(.unreachable(detail: error.localizedDescription)); return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.unreachable(detail: "bad response")); return
            }
            let ready = (obj["ready"] as? Bool) ?? false
            let model = (obj["model"] as? String) ?? "?"
            guard ready else {
                completion(.notReady(detail: (obj["error"] as? String) ?? "loading")); return
            }
            lastKnownModel = model
            completion(.ready(model: model))
        }.resume()
    }

    /// GET /health -> (ready, detail). `detail` is the model name when ready, else error/loading.
    static func health(completion: @escaping (Bool, String) -> Void) {
        healthOutcome { outcome in
            switch outcome {
            case .ready(let model): completion(true, model)
            case .notReady(let detail): completion(false, detail)
            case .unreachable(let detail): completion(false, detail)
            }
        }
    }

    /// Ensure the daemon is up + warm: if /health isn't ready, `launchctl kickstart` the agent
    /// and poll /health until ready (bounded ~20 s for the cold model load).
    static func ensureUp(_ completion: @escaping (Bool) -> Void) {
        health { ready, _ in
            if ready { completion(true); return }
            kickstart()
            pollReady(deadline: Date().addingTimeInterval(20), completion: completion)
        }
    }

    private static func kickstart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/\(agentLabel)"]
        try? p.run()
    }

    private static func pollReady(deadline: Date, completion: @escaping (Bool) -> Void) {
        health { ready, _ in
            if ready { completion(true); return }
            if Date() > deadline { completion(false); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                pollReady(deadline: deadline, completion: completion)
            }
        }
    }

    /// POST raw WAV bytes -> (transcript, error). The daemon decodes via ffmpeg, so a WAV at the
    /// mic's native sample rate is fine.
    static func transcribe(_ wav: Data, takeID: UUID? = nil,
                           completion: @escaping (String?, String?) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent("transcribe"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("wav", forHTTPHeaderField: "X-Audio-Format")
        // Per-request hallucination prefs (the daemon defaults to hardened for other callers).
        let conditionPrevious = Settings.conditionOnPreviousText
        let clean = Settings.cleanTranscript
        req.setValue(conditionPrevious ? "1" : "0", forHTTPHeaderField: "X-Condition-Previous-Text")
        req.setValue(clean ? "1" : "0", forHTTPHeaderField: "X-Clean")
        // Correction dictionary Layer 0 (whisper bias): a derived `initial_prompt` carried per-request,
        // parallel to the X-* headers above, so the recognizer is nudged toward the dictionary's
        // intended vocabulary BEFORE transcription. Base64 so arbitrary terms survive the header
        // (latin1 / no-newline) transport intact. ViddyDictate opts in; callers that omit the header
        // keep the daemon's default behavior.
        let bias = CorrectionDictionary.shared.whisperBias()
        if !bias.isEmpty, let b64 = bias.data(using: .utf8)?.base64EncodedString() {
            req.setValue(b64, forHTTPHeaderField: "X-Initial-Prompt-B64")
        }
        req.httpBody = wav
        let take = takeID?.uuidString ?? "partial-preview"
        Log.write("stt.request take=\(take) model=\(lastKnownModel ?? "health-unknown") "
            + "params={condition_on_previous_text=\(conditionPrevious), clean=\(clean), "
            + "initial_prompt_chars=\(bias.count), format=wav, timeout_s=120} wav_bytes=\(wav.count)")
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { completion(nil, error.localizedDescription); return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "bad response"); return
            }
            if let t = obj["transcript"] as? String {
                let model = (obj["model"] as? String) ?? lastKnownModel ?? "daemon-unreported"
                lastKnownModel = model
                let parameters = obj["parameters"] as? [String: Any]
                let parameterDetail = responseParameterDetail(parameters)
                if let takeID {
                    let raw = (obj["raw_transcript"] as? String) ?? t
                    Log.write("stt.result take=\(takeID.uuidString) model=\(model) params={\(parameterDetail)} "
                        + "raw=\(String(reflecting: raw)) daemon_postprocessed=\(String(reflecting: t))")
                } else {
                    Log.write("stt.partial result model=\(model) params={\(parameterDetail)} chars=\(t.count)")
                }
                completion(t, nil)
            }
            else { completion(nil, (obj["error"] as? String) ?? "no transcript") }
        }.resume()
    }

    private static func responseParameterDetail(_ parameters: [String: Any]?) -> String {
        guard let parameters else { return "daemon-unreported" }
        func value(_ key: String) -> String { parameters[key].map { String(describing: $0) } ?? "?" }
        return "condition_on_previous_text=\(value("condition_on_previous_text")), "
            + "clean=\(value("clean")), no_speech_threshold=\(value("no_speech_threshold")), "
            + "logprob_threshold=\(value("logprob_threshold")), "
            + "compression_ratio_threshold=\(value("compression_ratio_threshold")), "
            + "language=\(value("language")), initial_prompt_chars=\(value("initial_prompt_chars"))"
    }
}
