import AVFoundation
import CoreAudio

/// Records the default input device as 16 kHz mono 16-bit PCM (Whisper's native rate).
/// When that is a Bluetooth headset, the built-in microphone is used instead:
/// opening the headset's microphone switches it to its call profile, which
/// lowers and degrades whatever is playing.
final class Recorder {
    static let sampleRate = 16000
    /// Audio kept from just before `start()` while the microphone is kept ready.
    private static let prerollBytes = 2 * sampleRate * 4 / 10  // 0.4 s

    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(Recorder.sampleRate),
        channels: 1, interleaved: true)!
    private var unit: AudioUnit?
    private var converter: AVAudioConverter?
    private var renderBuffer: AVAudioPCMBuffer?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private let lock = NSLock()
    private var warm = false
    private var capturing = false
    private var pcm = Data()
    private var preroll = Data()

    struct NoInput: LocalizedError {
        var errorDescription: String? { "No microphone input (check Microphone permission)" }
    }

    /// Starts capturing. With the microphone kept ready, the last 0.4 s before
    /// the call is included, so a word spoken with the tap is not clipped.
    func start() throws {
        if unit == nil { try startEngine() }
        lock.withLock {
            pcm = preroll
            preroll.removeAll()
            capturing = true
        }
    }

    /// Stops capturing and returns everything captured since `start()`.
    func stop() -> Data {
        let data = lock.withLock { () -> Data in
            capturing = false
            defer { pcm.removeAll() }
            return pcm
        }
        if !lock.withLock({ warm }) { stopEngine() }
        return data
    }

    /// Keeps the microphone running between recordings (macOS then shows its
    /// microphone indicator), or releases it when not recording.
    func setWarm(_ keepReady: Bool) {
        let isCapturing = lock.withLock { () -> Bool in
            warm = keepReady
            if !keepReady { preroll.removeAll() }
            return capturing
        }
        if keepReady, unit == nil { try? startEngine() }
        if !keepReady, !isCapturing { stopEngine() }
    }

    // MARK: - Engine

    /// Opens the input device directly through an AUHAL unit. AVAudioEngine
    /// first opens the default input, which already flips Bluetooth headphones
    /// into their call profile even when it is pointed elsewhere afterwards.
    /// A fresh unit per use: one built for a previous microphone can fail when
    /// the input device has changed since.
    private func startEngine() throws {
        guard let device = recordingDevice() else { throw NoInput() }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance
        else { throw NoInput() }
        do {
            try configure(unit, device: device)
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }
        self.unit = unit

        // A new default input (AirPods, a headset) or a changed sample rate
        // invalidates the unit; rebuild it and carry on, keeping what was
        // already captured.
        let rebuild: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.unit != nil else { return }
            self.stopEngine()
            if self.lock.withLock({ self.warm || self.capturing }) { try? self.startEngine() }
        }
        listeners = [
            (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
            (device, kAudioDevicePropertyNominalSampleRate),
        ].map { object, selector in
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(object, &address, .main, rebuild)
            return (object, address, rebuild)
        }
    }

    private func configure(_ unit: AudioUnit, device: AudioDeviceID) throws {
        func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: UInt32, _ value: T) throws {
            let status = withUnsafeBytes(of: value) { bytes in
                AudioUnitSetProperty(unit, property, scope, element, bytes.baseAddress, UInt32(bytes.count))
            }
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        // Element 1 is the input side of the unit, element 0 the output side.
        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0))
        try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device)

        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                   &hardware, &size) == noErr,
              hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
              let inFormat = AVAudioFormat(
                  standardFormatWithSampleRate: hardware.mSampleRate,
                  channels: hardware.mChannelsPerFrame)
        else { throw NoInput() }
        // The unit does not resample its input, so it delivers float samples at
        // the device's rate and the converter takes them to 16 kHz.
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, inFormat.streamDescription.pointee)

        var maxFrames: UInt32 = 4096
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                             &maxFrames, &size)
        renderBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: max(maxFrames, 4096))
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        // Take the first channel of a multichannel input; without an explicit
        // map the conversion to mono can come out silent.
        converter?.channelMap = [0]

        try set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                Unmanaged<Recorder>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags, timeStamp, bus, frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()))
        var status = AudioUnitInitialize(unit)
        if status == noErr { status = AudioOutputUnitStart(unit) }
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// Called on the audio thread with each block of input.
    private func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32, _ frames: UInt32
    ) -> OSStatus {
        guard let unit, let buffer = renderBuffer, frames <= buffer.frameCapacity else { return noErr }
        // The buffer list's byte sizes follow frameLength when it is read.
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        append(buffer)
        return noErr
    }

    private func stopEngine() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners = []
        guard let unit else { return }
        // Stopping waits for a running render callback to return.
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = out.int16ChannelData, out.frameLength > 0 else { return }
        let bytes = Data(bytes: samples[0], count: Int(out.frameLength) * 2)
        lock.withLock {
            if capturing {
                pcm.append(bytes)
            } else if warm {
                preroll.append(bytes)
                if preroll.count > Self.prerollBytes { preroll.removeFirst(preroll.count - Self.prerollBytes) }
            }
        }
    }
}

// MARK: - Input devices

/// A UInt32-valued property (device IDs and transport types are both UInt32).
private func audioProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

private func defaultInputDevice() -> AudioDeviceID? {
    audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
}

private func transportType(_ device: AudioDeviceID) -> UInt32? {
    audioProperty(device, kAudioDevicePropertyTransportType)
}

private func isBluetooth(_ device: AudioDeviceID?) -> Bool {
    guard let device, let transport = transportType(device) else { return false }
    return transport == kAudioDeviceTransportTypeBluetooth
        || transport == kAudioDeviceTransportTypeBluetoothLE
}

/// The default input, or the built-in microphone in place of a Bluetooth one.
private func recordingDevice() -> AudioDeviceID? {
    guard let device = defaultInputDevice(), device != kAudioObjectUnknown else { return nil }
    return isBluetooth(device) ? builtInInputDevice() ?? device : device
}

/// The Mac's own microphone, if it has one.
private func builtInInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
    return devices.first { device in
        var streams = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        return transportType(device) == kAudioDeviceTransportTypeBuiltIn
            && AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == noErr
            && streamsSize > 0
    }
}

/// Largest absolute sample value. Whisper turns silence into phrases such as
/// "Thank you.", so near-silent recordings are not sent at all.
func peakLevel(_ pcm: Data) -> Int {
    pcm.withUnsafeBytes { raw in
        raw.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) }
    }
}

/// Wraps 16 kHz mono 16-bit PCM in a WAV header.
func wavData(_ pcm: Data, sampleRate: Int = Recorder.sampleRate) -> Data {
    var d = Data()
    func ascii(_ s: String) { d.append(s.data(using: .ascii)!) }
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    ascii("RIFF"); u32(UInt32(36 + pcm.count)); ascii("WAVE")
    ascii("fmt "); u32(16); u16(1); u16(1)
    u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    ascii("data"); u32(UInt32(pcm.count))
    d.append(pcm)
    return d
}
