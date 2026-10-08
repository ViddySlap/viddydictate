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

    private static var _lastWarmStatus: DaemonWarmStatus?

    /// The latest `/health` answer's warm-up account, refreshed by every health read (including each
    /// `ensureUp` poll); nil when nothing usable answered. The HUD reads it while a take waits.
    static var lastWarmStatus: DaemonWarmStatus? {
        get { modelLock.lock(); defer { modelLock.unlock() }; return _lastWarmStatus }
        set { modelLock.lock(); _lastWarmStatus = newValue; modelLock.unlock() }
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
            if let error = error {
                lastWarmStatus = nil
                completion(.unreachable(detail: error.localizedDescription)); return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastWarmStatus = nil
                completion(.unreachable(detail: "bad response")); return
            }
            let status = DaemonWarmStatus.parse(obj, observedAt: Date())
            lastWarmStatus = status
            let ready = (obj["ready"] as? Bool) ?? false
            let model = (obj["model"] as? String) ?? "?"
            guard ready else {
                // A daemon that reports its phase says which one ("downloading for 45s"); an older
                // daemon keeps the plain "loading".
                let detail = (obj["error"] as? String)
                    ?? DaemonWarmingHUD.preflightDetail(for: status) ?? "loading"
                completion(.notReady(detail: detail)); return
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

    /// Ensure the daemon is up + warm: if /health isn't ready, load the agent if launchd does not have
    /// it yet and `launchctl kickstart` it, then poll /health until ready (bounded ~20 s for the cold
    /// model load).
    static func ensureUp(_ completion: @escaping (Bool) -> Void) {
        health { ready, _ in
            if ready { completion(true); return }
            kickstart()
            pollReady(deadline: Date().addingTimeInterval(20), completion: completion)
        }
    }

    /// The same load-if-needed path the installer uses, so an agent that was never loaded (a fresh
    /// account before its next login) is bootstrapped here too. Plain kickstart, no `-k`: a daemon that
    /// is still loading its model is left alone. launchctl blocks, so it runs on its own queue and the
    /// poll starts at once, as it did when this was fire-and-forget.
    private static func kickstart() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = WhisperdAgentLoader.forCurrentUser().loadAndStart(restartIfLoaded: false)
        }
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

    /// POST raw WAV bytes -> (transcript, error, segments). The daemon decodes via ffmpeg, so a WAV at
    /// the mic's native sample rate is fine. `segments` (vdtpwg4 repair, master ruling item v) is the
    /// response's real per-dictation diagnostics, decoded via `parseSegments` -- `[]` on any failure
    /// path (transport error, bad body, no transcript) or against an old daemon that never sends them,
    /// exactly as `parseSegments`'s own contract already guarantees.
    static func transcribe(_ wav: Data, takeID: UUID? = nil,
                           completion: @escaping (String?, String?, [TailCheck.Segment]) -> Void) {
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
            if let error = error { completion(nil, error.localizedDescription, []); return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "bad response", []); return
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
                completion(t, nil, parseSegments(from: obj))
            }
            else { completion(nil, (obj["error"] as? String) ?? "no transcript", []) }
        }.resume()
    }

    /// Parse the `/transcribe` response's `segments` field (I1's additive per-segment diagnostics --
    /// `viddydictate_whisperd.py`'s `_clean_segments`, proven by `scripts/test-tailcheck-diagnostics.py`)
    /// into `[TailCheck.Segment]`.
    ///
    /// vdtpwg4 repair (master ruling item v): real contract, replacing the gate-author `[]` stub.
    /// Decodes each entry's `start`/`end`/`raw_text` (the three fields every entry has, old daemon or
    /// new); a missing or JSON-`null` `no_speech_prob`/`avg_logprob`/`compression_ratio` decodes to
    /// `TailCheck.missingSegmentMetricDefault`, never throws, and never drops the segment. An OLD
    /// response with no `segments` key at all (pre-I1 daemon), or where `segments` is present but not
    /// an array, decodes to `[]` without error -- `daemon-segments-decoded` pins both the new-body and
    /// old-body shapes against this exact contract.
    static func parseSegments(from responseObject: [String: Any]) -> [TailCheck.Segment] {
        guard let rawSegments = responseObject["segments"] as? [[String: Any]] else { return [] }
        func metric(_ dict: [String: Any], _ key: String) -> Double {
            (dict[key] as? Double) ?? TailCheck.missingSegmentMetricDefault
        }
        return rawSegments.compactMap { entry in
            guard let start = entry["start"] as? Double,
                  let end = entry["end"] as? Double,
                  let rawText = entry["raw_text"] as? String else { return nil }
            return TailCheck.Segment(
                start: start, end: end, rawText: rawText,
                noSpeechProb: metric(entry, "no_speech_prob"),
                avgLogprob: metric(entry, "avg_logprob"),
                compressionRatio: metric(entry, "compression_ratio"))
        }
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
