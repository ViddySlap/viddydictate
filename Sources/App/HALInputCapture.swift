import AudioToolbox
import CoreAudio
import Foundation

/// Raw AUHAL (HAL Output unit, input-enabled) capture from a SPECIFIC input device.
///
/// Why this exists: AVAudioEngine locks its `inputNode`'s format to the SYSTEM DEFAULT device when the
/// node is realized and never retargets it when you set `kAudioOutputUnitProperty_CurrentDevice`. So
/// pinning a device whose sample rate differs from the default leaves the engine tapping at the wrong
/// rate (no audio reaches the tap -> "no speech"), and forcing the device's rate into the tap crashes
/// `installTap` ("Input HW format and tap format not matching"). Verified end-to-end with --mic-probe.
/// An AUHAL bound directly to the device's `AudioDeviceID` owns the device and runs an internal
/// converter to a fixed client format, so it captures ANY device at ANY rate. `AudioRecorder` uses this
/// for the pinned-device path and keeps AVAudioEngine for follow-the-system-default (which works).
///
/// Delivers each render slice downmixed to mono via `onMono`, called on a CoreAudio IO thread.
final class HALInputCapture {
    /// The device's capture sample rate (the client format rate) — read after `start()` succeeds.
    private(set) var sampleRate: Double = 0

    private var unit: AudioUnit?
    private var channels: Int = 1
    private var maxFrames: Int = 4096
    private var renderBuf: UnsafeMutablePointer<Float>?
    private var renderCap: Int = 0   // capacity in floats (maxFrames * channels)

    /// One render slice as mono samples. Called on the IO thread — keep the work light.
    var onMono: (([Float]) -> Void)?

    func start(deviceID: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw err("no HAL component") }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        guard let unit = au else { throw err("nil audio unit") }
        self.unit = unit

        // Enable input (element 1), disable output (element 0).
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                       &enable, UInt32(MemoryLayout<UInt32>.size)), "EnableIO input")
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                       &disable, UInt32(MemoryLayout<UInt32>.size)), "DisableIO output")

        // Bind the chosen device (this is what AVAudioEngine could not make stick).
        var dev = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "CurrentDevice")

        // The device's hardware input format (input scope, element 1).
        var hw = AudioStreamBasicDescription()
        var hsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                       &hw, &hsize), "get hw format")
        let rate = hw.mSampleRate > 0 ? hw.mSampleRate : 48000
        let chs = max(1, Int(hw.mChannelsPerFrame))

        // Client format the callback receives (output scope, element 1): interleaved Float32 at the
        // device's rate and channel count. The AUHAL converts to this; we downmix to mono ourselves
        // (the AUHAL won't reliably mix arbitrary channel counts down to one).
        var client = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * chs),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * chs),
            mChannelsPerFrame: UInt32(chs),
            mBitsPerChannel: 32,
            mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                       &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "set client format")

        // Size the reusable render buffer from the unit's max slice.
        var maxF: UInt32 = 4096
        var msize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                 &maxF, &msize)
        self.channels = chs
        self.sampleRate = rate
        self.maxFrames = max(Int(maxF), 4096)
        self.renderCap = self.maxFrames * chs
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: renderCap)
        buf.initialize(repeating: 0, count: renderCap)
        self.renderBuf = buf

        // Install the input callback, then initialize + start.
        var cb = AURenderCallbackStruct(inputProc: halInputCallback,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
        Log.write("hal.start: device=\(deviceID) \(Int(rate)) Hz / \(chs) ch (AUHAL, maxFrames=\(maxFrames))")
    }

    func stop() {
        if let unit = unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        if let buf = renderBuf { buf.deinitialize(count: renderCap); buf.deallocate(); renderBuf = nil }
        renderCap = 0
    }

    /// Pull one slice from the unit and hand mono samples to `onMono`. Called from the C callback on
    /// the IO thread. The unit fills our preallocated buffer when we call `AudioUnitRender`.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ ts: UnsafePointer<AudioTimeStamp>,
                            _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit = unit, let buf = renderBuf else { return noErr }
        let chs = channels
        let n = Int(frames)
        if n <= 0 || n * chs > renderCap { return noErr }
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: UInt32(chs),
                                  mDataByteSize: UInt32(n * chs * 4),
                                  mData: UnsafeMutableRawPointer(buf)))
        let st = AudioUnitRender(unit, flags, ts, bus, frames, &abl)
        if st != noErr { return st }
        var mono = [Float](repeating: 0, count: n)
        if chs == 1 {
            for i in 0..<n { mono[i] = buf[i] }
        } else {
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<chs { s += buf[i * chs + c] }
                mono[i] = s / Float(chs)
            }
        }
        onMono?(mono)
        return noErr
    }

    private func check(_ st: OSStatus, _ what: String) throws {
        guard st == noErr else { throw err("\(what) failed (OSStatus \(st))") }
    }
    private func err(_ msg: String) -> NSError {
        NSError(domain: "ViddyDictate.HALInputCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

/// C input callback -> hop to the instance (no captures, so it converts to a C function pointer).
private func halInputCallback(_ refCon: UnsafeMutableRawPointer,
                              _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
                              _ inBusNumber: UInt32,
                              _ inNumberFrames: UInt32,
                              _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let me = Unmanaged<HALInputCapture>.fromOpaque(refCon).takeUnretainedValue()
    return me.render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}
