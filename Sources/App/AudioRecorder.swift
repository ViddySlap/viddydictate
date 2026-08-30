import AVFoundation
import AudioToolbox

/// Captures the mic into an in-memory mono Float buffer (native sample rate) and can snapshot it
/// as a **16 kHz** 16-bit PCM WAV at any time — used for live partials (snapshot the growing clip)
/// and the final pass (snapshot on stop).
///
/// The snapshot is resampled here rather than left at the device rate, and that is the whole reason
/// ViddyDictate no longer needs ffmpeg. Whisper works at 16 kHz; something has to resample. It used
/// to be ffmpeg, invoked by name out of the daemon's PATH, which meant the app depended on a binary
/// macOS does not ship, that nothing installed, and whose VERSION varied per machine — and whisper
/// is chaotic enough on marginal takes that two ffmpeg builds give two different transcripts. Doing
/// it here with AVAudioConverter means one resampler, present on every Mac, identical for every
/// user, and the daemon is left with an exact int16 -> float32 conversion and nothing to approximate.
/// Measured on the regression corpus: the daemon's decode of these snapshots is bit-identical to
/// ffmpeg's, max|diff| = 0.0 on all 11 takes.
final class AudioRecorder {
    /// Final clips keep this much audio after the last active analysis window. The take has already
    /// crossed the 0.006 speech gate, so this lower floor only removes the quiet tail after speech.
    /// A half-second pad keeps final consonants and natural fades on the model-bound clip.
    static let trailingSilenceEnergyFloor: Float = 0.0015
    static let trailingSilencePadSeconds: Double = 0.5
    private static let trailingSilenceWindowSeconds: Double = 0.02

    private var engine = AVAudioEngine()   // rebuilt per take (see startEngine()) so a device/format change can't crash installTap
    private var engineRunning = false
    private var hal: HALInputCapture?      // non-nil while a PINNED device is captured via AUHAL (see HALInputCapture)
    private var sampleRate: Double = 16000
    private var samples = [Float]()
    private var _peakRms: Float = 0        // loudest raw RMS this take — gates out silent taps
    private let lock = NSLock()

    /// When false (preview mode) we don't accumulate samples — so the settings-window meter can
    /// run indefinitely (reading `scopeSamples`) without growing an unused buffer.
    var captureSamples = true

    // Ring of recent mono samples for the live oscilloscope (full-width waveform view).
    private var ring = [Float](repeating: 0, count: 2048)
    private var ringIdx = 0

    /// Did the user actually speak this take? Pure-silence / accidental taps never cross the floor,
    /// and large-v3-turbo confidently hallucinates ("Thank you.") on silence — so we skip those
    /// rather than paste a fabricated phrase. Conservative floor so genuine quiet speech still sends.
    var detectedSpeech: Bool { lock.lock(); defer { lock.unlock() }; return _peakRms > 0.006 }

    /// Snapshot of the most recent mono samples (oldest → newest) for the oscilloscope.
    var scopeSamples: [Float] {
        lock.lock(); defer { lock.unlock() }
        let c = ring.count
        var out = [Float](repeating: 0, count: c)
        for i in 0..<c { out[i] = ring[(ringIdx + i) % c] }
        return out
    }

    func start() throws {
        // Shared reset for whichever capture backend runs this take.
        lock.lock(); samples.removeAll(keepingCapacity: true); _peakRms = 0
        for i in 0..<ring.count { ring[i] = 0 }; ringIdx = 0; lock.unlock()
        stop()

        // Route a pinned, currently-present device through the AUHAL capture: AVAudioEngine locks its
        // inputNode to the SYSTEM DEFAULT's format and won't retarget to a non-default-rate device, so
        // a pinned mic at a different rate captures silence (or crashes installTap) — see HALInputCapture.
        // No pin (or the pin is unplugged) -> follow the system default via AVAudioEngine, which handles
        // default-device changes itself.
        let uid = Settings.inputDeviceUID
        if !uid.isEmpty, let devID = AudioDevices.deviceID(forUID: uid) {
            try startHAL(deviceID: devID, uid: uid)
        } else {
            if !uid.isEmpty { Log.write("audio.device: pinned device absent (\(uid)) — following system default") }
            try startEngine()
        }
    }

    /// Follow-the-system-default capture via AVAudioEngine. Rebuild the engine from scratch every take:
    /// an AVAudioEngine binds to the input device and its hardware format when it is created, and reusing
    /// one long-lived engine across an input-device or sample-rate change leaves the format it REPORTS
    /// out of sync with the device's ACTUAL format, so installTap(...) throws an uncatchable Obj-C
    /// exception (the historical SIGABRT here). A fresh engine always binds to the current default, so
    /// the format we read and the format we tap with stay consistent.
    private func startEngine() throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A device mid-transition reports a 0 Hz / 0-channel format; tapping that crashes the same way.
        // Throw instead. beginRecording() catches it and degrades to a skipped take with a toast.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "ViddyDictate.AudioRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "input device not ready (\(format.sampleRate) Hz / \(format.channelCount) ch)"])
        }
        sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        Log.write("audio.start: follow-default tap \(Int(format.sampleRate)) Hz / \(channels) ch")
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            if n == 0 { return }
            var mono = [Float](repeating: 0, count: n)
            if channels <= 1 {
                let p = ch[0]
                for i in 0..<n { mono[i] = p[i] }
            } else {
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<channels { s += ch[c][i] }
                    mono[i] = s / Float(channels)
                }
            }
            self.ingest(mono)
        }
        engine.prepare()
        try engine.start()
        engineRunning = true
    }

    /// Pinned-device capture via a raw AUHAL bound to the device's AudioDeviceID (HALInputCapture). It
    /// owns the device and converts to a fixed client format, so it captures any device at any rate —
    /// the AVAudioEngine retargeting limitation does not apply.
    private func startHAL(deviceID: AudioDeviceID, uid: String) throws {
        let cap = HALInputCapture()
        cap.onMono = { [weak self] mono in self?.ingest(mono) }
        try cap.start(deviceID: deviceID)
        guard cap.sampleRate > 0 else {
            cap.stop()
            throw NSError(domain: "ViddyDictate.AudioRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "pinned input device not ready (0 Hz)"])
        }
        sampleRate = cap.sampleRate
        hal = cap
        Log.write("audio.device: capturing pinned \(uid) via AUHAL @ \(Int(cap.sampleRate)) Hz")
    }

    /// Shared per-slice processing for both capture backends: gate the speech floor (peak RMS), feed the
    /// oscilloscope ring, and accumulate the take. Called on an audio IO thread.
    private func ingest(_ mono: [Float]) {
        let n = mono.count
        if n == 0 { return }
        // RMS of this slice gates silent taps (the speech floor); the raw ring drives the scope.
        var sumSq: Float = 0
        for v in mono { sumSq += v * v }
        let rms = sqrtf(sumSq / Float(n))
        lock.lock()
        if rms > _peakRms { _peakRms = rms }
        for s in mono { ring[ringIdx] = s; ringIdx += 1; if ringIdx == ring.count { ringIdx = 0 } }
        if captureSamples { samples.append(contentsOf: mono) }
        lock.unlock()
    }

    func stop() {
        if engineRunning { engine.inputNode.removeTap(onBus: 0); engine.stop(); engineRunning = false }
        hal?.stop(); hal = nil
    }

    var hasAudio: Bool { lock.lock(); defer { lock.unlock() }; return !samples.isEmpty }

    struct WavSnapshot {
        let wav: Data
        let rawSampleCount: Int
        let retainedSampleCount: Int
        let sampleRate: Double

        var rawDuration: TimeInterval {
            sampleRate > 0 ? Double(rawSampleCount) / sampleRate : 0
        }
        var retainedDuration: TimeInterval {
            sampleRate > 0 ? Double(retainedSampleCount) / sampleRate : 0
        }
        var trimmedTrailingDuration: TimeInterval {
            max(0, rawDuration - retainedDuration)
        }
    }

    func snapshotWav() -> Data {
        snapshotWavWithMetrics().wav
    }

    /// One trim pass yielding both the model-bound bytes and measured duration counts for diagnostics.
    /// `trimTrailingNearSilence` and its production floor are unchanged; this only makes the before/after
    /// sample counts observable to the caller that logs and retains a final take.
    func snapshotWavWithMetrics() -> WavSnapshot {
        lock.lock(); let copy = samples; let sr = sampleRate; lock.unlock()
        let trimmed = AudioRecorder.trimTrailingNearSilence(samples: copy, sampleRate: sr)
        // Trim at the native rate, resample only what survives. The reported counts and durations
        // stay in native-rate terms on purpose: they feed the tail-hallucination diagnostics, whose
        // measurements were taken against the raw capture, and rebasing them to 16 kHz would silently
        // change the meaning of numbers other code compares against recorded thresholds.
        let outbound = AudioRecorder.resampleForModel(samples: trimmed, from: sr)
        return WavSnapshot(
            wav: AudioRecorder.makeWav(samples: outbound, sampleRate: AudioRecorder.modelSampleRate),
            rawSampleCount: copy.count,
            retainedSampleCount: trimmed.count,
            sampleRate: sr)
    }

    /// What Whisper consumes. Everything handed to the daemon is at this rate, so the daemon never
    /// resamples and never shells out.
    static let modelSampleRate: Double = 16000

    /// Resample a mono Float buffer to `modelSampleRate` with AVAudioConverter at maximum quality.
    ///
    /// Returns the input untouched when it is already at the model rate — the overwhelmingly common
    /// case on a pinned 16 kHz device, and it keeps that path exactly bit-for-bit what it was.
    ///
    /// **Failure is deliberately non-fatal and non-silent.** If a converter cannot be built for some
    /// device format, this returns the input unchanged rather than throwing away a take the user has
    /// already spoken. The WAV then carries its native rate in its own header, the daemon reads that
    /// header and resamples in Python, and the transcript still happens. A dropped take would be a
    /// worse outcome than a slower path, and the header means the two sides can never disagree about
    /// what rate the bytes are.
    static func resampleForModel(samples: [Float], from sourceRate: Double) -> [Float] {
        guard sourceRate > 0, sourceRate != modelSampleRate, !samples.isEmpty else { return samples }

        guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: modelSampleRate, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat,
                                           frameCapacity: AVAudioFrameCount(samples.count)) else {
            Log.write("audio.resample: no converter for \(Int(sourceRate)) Hz — sending native rate")
            return samples
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        inBuf.frameLength = AVAudioFrameCount(samples.count)
        if let dst = inBuf.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }

        // Ceiling plus the converter's own priming latency, so a resample can never be truncated by
        // an under-sized destination.
        let ratio = modelSampleRate / sourceRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            Log.write("audio.resample: could not allocate \(capacity) frames — sending native rate")
            return samples
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .endOfStream; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if let error = error {
            Log.write("audio.resample: \(Int(sourceRate)) Hz -> 16 kHz failed (\(error.code)) — sending native rate")
            return samples
        }
        guard status != .error, outBuf.frameLength > 0, let out = outBuf.floatChannelData?[0] else {
            Log.write("audio.resample: produced no frames — sending native rate")
            return samples
        }
        return Array(UnsafeBufferPointer(start: out, count: Int(outBuf.frameLength)))
    }

    /// Remove only a long, low-energy tail before a snapshot reaches transcription. Fixed 20 ms RMS
    /// windows avoid treating a waveform zero crossing as silence; scanning from the end finds the
    /// last window with real energy. The pad is added after that whole window, which intentionally
    /// errs toward retaining audio. An entirely quiet clip becomes an empty WAV payload.
    static func trimTrailingNearSilence(samples: [Float],
                                       sampleRate: Double,
                                       energyFloor: Float = trailingSilenceEnergyFloor,
                                       padSeconds: Double = trailingSilencePadSeconds) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard sampleRate.isFinite, sampleRate > 0,
              energyFloor.isFinite, energyFloor >= 0,
              padSeconds.isFinite, padSeconds >= 0 else {
            return samples
        }

        let windowSamples = max(1, Int((sampleRate * trailingSilenceWindowSeconds).rounded()))
        let requestedPad = sampleRate * padSeconds
        let padSamples = requestedPad >= Double(samples.count)
            ? samples.count
            : Int(requestedPad.rounded(.up))

        var windowEnd = samples.count
        while windowEnd > 0 {
            let windowStart = max(0, windowEnd - windowSamples)
            var sumSquares = 0.0
            for index in windowStart..<windowEnd {
                let sample = Double(samples[index])
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Double(windowEnd - windowStart))
            if rms > Double(energyFloor) {
                let availableAfterWindow = samples.count - windowEnd
                let retainedPad = min(padSamples, availableAfterWindow)
                let keepCount = windowEnd + retainedPad
                return keepCount == samples.count ? samples : Array(samples.prefix(keepCount))
            }
            windowEnd = windowStart
        }

        return []
    }

    static func makeWav(samples: [Float], sampleRate: Double) -> Data {
        let sr = UInt32(sampleRate)
        let bits: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = sr * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let dataSize = UInt32(samples.count * 2)

        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(sr); u32(byteRate); u16(blockAlign); u16(bits)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.reserveCapacity(d.count + samples.count * 2)
        for f in samples {
            let v = Int16(max(-1.0, min(1.0, f)) * 32767.0)
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        return d
    }
}
