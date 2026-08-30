import Foundation

/// Synthetic PCM coverage for the physical trailing-silence trim. The quiet-final-word fixture is
/// intentionally separated from earlier loud speech by more than the production pad: if the floor
/// becomes aggressive enough to miss that quiet word, the production-policy survival check goes red.
enum AudioTrimSelfTest {
    private static let sampleRate = 16_000.0

    static func run() -> Bool {
        print("--- trailing near-silence audio trim synthetic selftest ---")
        let reporter = SelfTestReporter()

        reporter.record(
            "production energy floor remains the locked 0.0015",
            AudioRecorder.trailingSilenceEnergyFloor == 0.0015,
            "floor=\(AudioRecorder.trailingSilenceEnergyFloor)")

        let measured = AudioRecorder.WavSnapshot(
            wav: Data("synthetic".utf8), rawSampleCount: 24_000,
            retainedSampleCount: 16_000, sampleRate: sampleRate)
        reporter.record(
            "snapshot diagnostics measure raw, retained, and trimmed durations from sample counts",
            measured.rawDuration == 1.5
                && measured.retainedDuration == 1.0
                && measured.trimmedTrailingDuration == 0.5)

        let active = voicedSamples(seconds: 0.4, amplitude: 0.018)
        let longQuietTail = nearSilence(seconds: 1.2)
        let trimmedTail = AudioRecorder.trimTrailingNearSilence(
            samples: active + longQuietTail,
            sampleRate: sampleRate)
        let expectedPadSamples = Int(sampleRate * AudioRecorder.trailingSilencePadSeconds)
        reporter.record(
            "long near-silence tail is trimmed after the conservative pad",
            trimmedTail.count == active.count + expectedPadSamples,
            "kept=\(trimmedTail.count) expected=\(active.count + expectedPadSamples)")

        let entirelyQuiet = AudioRecorder.trimTrailingNearSilence(
            samples: nearSilence(seconds: 1.0),
            sampleRate: sampleRate)
        reporter.record(
            "entirely silent clip becomes an empty audio payload",
            entirelyQuiet.isEmpty,
            "kept=\(entirelyQuiet.count)")

        let activeThroughEnd = voicedSamples(seconds: 0.6, amplitude: 0.018)
        let activeThroughEndTrimmed = AudioRecorder.trimTrailingNearSilence(
            samples: activeThroughEnd,
            sampleRate: sampleRate)
        reporter.record(
            "clip with no trailing silence is unchanged",
            activeThroughEndTrimmed == activeThroughEnd,
            "kept=\(activeThroughEndTrimmed.count) original=\(activeThroughEnd.count)")

        let shortQuietTail = nearSilence(seconds: 0.25)
        let shortTailClip = active + shortQuietTail
        let shortTailTrimmed = AudioRecorder.trimTrailingNearSilence(
            samples: shortTailClip,
            sampleRate: sampleRate)
        reporter.record(
            "quiet tail shorter than the pad is unchanged",
            shortTailTrimmed == shortTailClip,
            "kept=\(shortTailTrimmed.count) original=\(shortTailClip.count)")

        let preface = voicedSamples(seconds: 0.25, amplitude: 0.018)
        let gapLongerThanPad = nearSilence(
            seconds: AudioRecorder.trailingSilencePadSeconds + 0.25)
        let quietFinalWord = voicedSamples(seconds: 0.36, amplitude: 0.0038)
        let quietWordPeak = quietFinalWord.map(abs).max() ?? 0
        let quietFinalClip = preface + gapLongerThanPad + quietFinalWord
        let productionTrimmed = AudioRecorder.trimTrailingNearSilence(
            samples: quietFinalClip,
            sampleRate: sampleRate)

        reporter.record(
            "negative control is genuinely quiet relative to the take gate",
            quietWordPeak < 0.006,
            "peak=\(quietWordPeak) takeGate=0.006")
        reporter.record(
            "quiet final word survives the production trim intact",
            productionTrimmed == quietFinalClip,
            "kept=\(productionTrimmed.count) original=\(quietFinalClip.count)")

        // This is a fixture-sensitivity canary, not production policy. It proves that the earlier
        // speech plus the normal pad cannot accidentally shelter the final word: an aggressive
        // floor misses the quiet word and clips it. Raising the production floor the same way makes
        // the survival assertion above fail.
        let aggressiveTrimmed = AudioRecorder.trimTrailingNearSilence(
            samples: quietFinalClip,
            sampleRate: sampleRate,
            energyFloor: 0.004,
            padSeconds: AudioRecorder.trailingSilencePadSeconds)
        let quietWordStart = preface.count + gapLongerThanPad.count
        reporter.record(
            "negative control bites under an aggressive floor",
            aggressiveTrimmed.count <= quietWordStart,
            "kept=\(aggressiveTrimmed.count) quietWordStart=\(quietWordStart)")

        // ---- The 16 kHz snapshot contract -------------------------------------------------------
        // This is what replaced ffmpeg. The daemon no longer resamples and no longer shells out; it
        // does an exact int16 -> float32 conversion, which is only correct because everything the app
        // sends is already at the model rate. If any assertion here goes red, the daemon silently
        // falls back to resampling in Python and the two sides stop agreeing about the audio.

        reporter.record(
            "the model rate the app targets is Whisper's 16 kHz",
            AudioRecorder.modelSampleRate == 16_000)

        // Identity at the model rate. The pinned case: a clip already at 16 kHz must come back
        // bit-for-bit, never round-tripped through a converter that would perturb it for no reason.
        let atModelRate = voicedSamples(seconds: 0.5, amplitude: 0.02)
        let passedThrough = AudioRecorder.resampleForModel(
            samples: atModelRate, from: AudioRecorder.modelSampleRate)
        reporter.record(
            "audio already at 16 kHz is returned untouched, sample for sample",
            passedThrough == atModelRate,
            "in=\(atModelRate.count) out=\(passedThrough.count)")

        reporter.record(
            "an empty clip resamples to an empty clip rather than trapping",
            AudioRecorder.resampleForModel(samples: [], from: 44_100).isEmpty)

        // Real device rates. The count is checked against the exact ratio with a small tolerance,
        // because a sample-rate converter's priming latency legitimately shifts the tail by a few
        // frames; what must NOT happen is a wholesale truncation or a doubling.
        for deviceRate in [44_100.0, 48_000.0] {
            let oneSecond = (0..<Int(deviceRate)).map { index -> Float in
                Float(0.2 * sin(2.0 * Double.pi * 440.0 * Double(index) / deviceRate))
            }
            let resampled = AudioRecorder.resampleForModel(samples: oneSecond, from: deviceRate)
            let expected = Int(AudioRecorder.modelSampleRate)
            reporter.record(
                "\(Int(deviceRate)) Hz resamples to within a few frames of 16 kHz",
                abs(resampled.count - expected) <= 256,
                "out=\(resampled.count) expected=\(expected)")

            // A resample that produced silence, or clipped, would still have the right length. Check
            // the signal actually survived: a 440 Hz tone is far below the 8 kHz Nyquist limit here,
            // so its amplitude must come through essentially intact.
            let peak = resampled.map(abs).max() ?? 0
            reporter.record(
                "\(Int(deviceRate)) Hz resample preserves the tone rather than gating it",
                peak > 0.15 && peak < 0.25,
                "peak=\(peak) source=0.2")
        }

        // The header is the contract the daemon reads. Whatever the device was doing, the bytes that
        // leave this app must announce 16 kHz, because that is what makes the daemon's exact decode
        // path correct rather than merely lucky.
        let snapshotRate = readWavSampleRate(
            AudioRecorder.makeWav(samples: AudioRecorder.resampleForModel(
                samples: (0..<48_000).map { Float(0.1 * sin(Double($0) / 12.0)) }, from: 48_000),
                sampleRate: AudioRecorder.modelSampleRate))
        reporter.record(
            "a snapshot taken from a 48 kHz device declares 16 kHz in its WAV header",
            snapshotRate == 16_000,
            "header=\(snapshotRate ?? -1)")

        print(reporter.summaryLine(prefix: reporter.passed
            ? "[audio-trim-selftest] PASS"
            : "[audio-trim-selftest] FAIL"))
        return reporter.passed
    }

    /// Read the sample rate straight out of the RIFF header, so the assertion is against the bytes
    /// the daemon will actually parse rather than against the value we passed in.
    private static func readWavSampleRate(_ wav: Data) -> Int? {
        guard wav.count >= 28 else { return nil }
        let bytes = [UInt8](wav[24..<28])
        return Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
    }

    private static func nearSilence(seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { $0.isMultiple(of: 2) ? 0.00025 : -0.00025 }
    }

    /// Deterministic voiced, speech-like energy with a short attack and release. The two harmonics
    /// keep this from being a flat fixture while remaining synthetic and content-free.
    private static func voicedSamples(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(sampleRate * seconds)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let phase = 2.0 * Double.pi * 170.0 * Double(index) / sampleRate
            let attack = min(1.0, Double(index) / (sampleRate * 0.03))
            let release = min(1.0, Double(count - index) / (sampleRate * 0.04))
            let envelope = Float(min(attack, release))
            let voiced = Float(0.72 * sin(phase) + 0.28 * sin(phase * 2.03))
            return amplitude * envelope * voiced
        }
    }
}
