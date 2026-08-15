import AVFoundation
import CoreAudio
import Foundation

/// `--mic-probe`: a headless diagnostic for the Settings mic-picker device-pinning bug.
///
/// For each input-capable device it builds a FRESH AVAudioEngine (the per-take pattern AudioRecorder
/// uses), binds the engine's HAL input to that device via `kAudioOutputUnitProperty_CurrentDevice`,
/// and prints what the engine then reports: `inputFormat` (the hardware side), `outputFormat` (the
/// engine side — the rate the shipped AudioRecorder installs its tap with), the device's Core Audio
/// nominal sample rate (the hardware truth), and a readback of `CurrentDevice` (did the bind take?).
///
/// No tap, no `engine.start()` — so it needs NO microphone permission and is safe to run headless.
/// The bug signature is `outputFormat` stuck at the rate the node was realized with (the system
/// default) instead of the bound device's rate, so the tap is installed at the wrong rate and no
/// audio flows. This probe confirms the mechanism before the fix and verifies the formats line up
/// after it.
enum MicProbe {
    static func run() -> Bool {
        print("=== ViddyDictate mic-probe (device-pinning format diagnostic) ===")
        let defID = defaultInputDeviceID()
        print("system default input device id=\(defID.map(String.init) ?? "nil")\n")

        let devices = AudioDevices.inputDevices()
        guard !devices.isEmpty else { print("no input devices found"); return false }

        var anyMismatch = false
        for d in devices {
            if probe(device: d, isSystemDefault: d.id == defID) { anyMismatch = true }
        }

        print("Reading: a non-default device whose outputFormat != nominalRate is the bug — the shipped")
        print("AudioRecorder taps with outputFormat. The fix taps with the hardware truth instead.")
        print(anyMismatch ? "\nMISMATCH(es) PRESENT — reproduces the bug ✗" : "\nno mismatch — formats track the bound device ✓")
        return true
    }

    /// Returns true when this device shows the stale-format mismatch.
    @discardableResult
    private static func probe(device d: AudioDevices.Device, isSystemDefault: Bool) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let bound = bind(input, to: d.id)
        let inFmt = input.inputFormat(forBus: 0)
        let outFmt = input.outputFormat(forBus: 0)
        let nominal = AudioDevices.nominalSampleRate(of: d.id) ?? -1
        let readback = currentDevice(of: input)
        // Does engine.prepare() (and a re-bind after it) reconfigure the node to the bound device's
        // format? installTap validates the tap format against the node's REALIZED hw format, so the fix
        // needs the node realized against the pinned device. These post-prepare reads tell us if that
        // happens synchronously.
        engine.prepare()
        let inFmtP = input.inputFormat(forBus: 0)
        let outFmtP = input.outputFormat(forBus: 0)
        // Does the engine reconfigure ASYNCHRONOUSLY after the device change? Spin the runloop briefly
        // (the AVAudioEngineConfigurationChange notification, if any, fires on it) then re-read.
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.4, false)
        let inFmtD = input.inputFormat(forBus: 0)
        let outFmtD = input.outputFormat(forBus: 0)
        let mismatch = !isSystemDefault && Int(outFmt.sampleRate) != Int(nominal)

        print("• \(d.name)\(isSystemDefault ? "  [system default]" : "")")
        print("    uid=\(d.uid)  id=\(d.id)")
        print("    bind set=\(bound)  CurrentDevice readback=\(readback.map(String.init) ?? "nil") (want \(d.id))")
        print("    CA nominalRate          = \(Int(nominal)) Hz   (hardware truth)")
        print("    pre-prepare  in/out     = \(Int(inFmt.sampleRate)) / \(Int(outFmt.sampleRate)) Hz")
        print("    post-prepare in/out     = \(Int(inFmtP.sampleRate)) / \(Int(outFmtP.sampleRate)) Hz")
        print("    after 0.4s runloop  i/o = \(Int(inFmtD.sampleRate)) / \(Int(outFmtD.sampleRate)) Hz")
        print("    => \(mismatch ? "MISMATCH at pre-prepare outputFormat ✗" : "ok ✓")\n")
        engine.stop()
        return mismatch
    }

    // MARK: recorder test (real AudioRecorder integration: routing + ingest + snapshotWav)

    /// `--recorder-test [uid]`: drive the real `AudioRecorder` for ~1.5s and report whether it captured
    /// samples. With a `uid` it force-pins that device (so the AUHAL/`startHAL` path runs) and RESTORES
    /// the user's original setting on exit. Proves the full pinned-device integration end to end, not just the
    /// standalone capture. "samples captured" holds even in silence — it confirms the pipeline flows.
    static func runRecorderTest(forcedUID: String?) -> Bool {
        print("=== ViddyDictate recorder-test (real AudioRecorder integration) ===")
        let original = Settings.inputDeviceUID
        if let u = forcedUID { Settings.inputDeviceUID = u }
        defer { Settings.inputDeviceUID = original }   // restore the user's setting no matter what
        let active = Settings.inputDeviceUID
        print("inputDeviceUID = \(active.isEmpty ? "(follow system default)" : active)   [original restored on exit]")

        let rec = AudioRecorder()
        do { try rec.start() } catch {
            print("AudioRecorder.start failed: \(error.localizedDescription)"); return false
        }
        Thread.sleep(forTimeInterval: 1.5)
        let spoke = rec.detectedSpeech
        let wav = rec.snapshotWav()
        rec.stop()
        let samples = max(0, wav.count - 44) / 2
        print("detectedSpeech=\(spoke)  wav=\(wav.count) bytes (~\(samples) samples)")
        print(samples > 0 ? "AudioRecorder captured samples ✓" : "no samples captured ✗")
        return samples > 0
    }

    // MARK: capture test (does audio actually flow per device with an inputFormat tap?)

    /// `--mic-capture-test`: for each input device, capture ~1.2s through the AUHAL path (the actual
    /// fix — HALInputCapture) and report whether slices arrived with non-zero energy. Needs Microphone
    /// permission; testing the system default too lets us tell a real capture problem (default flows,
    /// pinned silent) from a TCC problem (everything silent under a CLI run). With a non-default device
    /// as a reliable source (e.g. the MacBook mic while AirPods are default), a FLOW confirms the fix.
    static func runCapture() -> Bool {
        print("=== ViddyDictate mic-capture-test (AUHAL HALInputCapture — does audio flow per device?) ===")
        let defID = defaultInputDeviceID()
        let devices = AudioDevices.inputDevices()
        guard !devices.isEmpty else { print("no input devices"); return false }

        var anyFlow = false
        for d in devices {
            let r = capture(device: d)
            let flow = r.peak > 0.0008
            if flow { anyFlow = true }
            print("• \(d.name)\(d.id == defID ? "  [default]" : "")")
            print("    tap format \(Int(r.rate)) Hz   started=\(r.started)\(r.err.map { "  err=\($0)" } ?? "")")
            print("    buffers=\(r.buffers)  peakRMS=\(String(format: "%.5f", r.peak))  => \(flow ? "AUDIO FLOWS ✓" : "silent ✗")\n")
        }
        if anyFlow {
            print("Mic permission reached this run. A non-default device that FLOWS confirms the inputFormat fix.")
        } else {
            print("ALL devices silent — most likely the CLI lacks Microphone TCC permission (not a format bug).")
            print("Inconclusive for the fix from here; confirm via the GUI app instead.")
        }
        return true
    }

    private static func capture(device d: AudioDevices.Device)
        -> (rate: Double, buffers: Int, peak: Float, started: Bool, err: String?) {
        let cap = HALInputCapture()
        let lock = NSLock()
        var buffers = 0
        var peak: Float = 0
        cap.onMono = { mono in
            let n = max(1, mono.count)
            var sumSq: Float = 0
            for v in mono { sumSq += v * v }
            let rms = (sumSq / Float(n)).squareRoot()
            lock.lock(); buffers += 1; if rms > peak { peak = rms }; lock.unlock()
        }
        var started = false
        var err: String?
        do { try cap.start(deviceID: d.id); started = true } catch { err = error.localizedDescription }
        Thread.sleep(forTimeInterval: 1.2)
        cap.stop()
        lock.lock(); let b = buffers; let pk = peak; lock.unlock()
        return (cap.sampleRate, b, pk, started, err)
    }

    private static func bind(_ input: AVAudioInputNode, to devID: AudioDeviceID) -> Bool {
        guard let au = input.audioUnit else { return false }
        var dev = devID
        return AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &dev,
                                    UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    private static func currentDevice(of input: AVAudioInputNode) -> AudioDeviceID? {
        guard let au = input.audioUnit else { return nil }
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &dev, &size)
        return st == noErr ? dev : nil
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return st == noErr ? dev : nil
    }
}
