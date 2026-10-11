import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac is playing with a Core Audio process tap (muting the
/// original stream), applies gain plus a peak limiter, and plays the result on the
/// default output device. Needs macOS 14.2+ and the System Audio Recording permission.
final class AudioBooster {
    var gain: Float {
        get { processor.targetGain }
        set { processor.targetGain = max(1, newValue) }
    }
    private(set) var isRunning = false
    private(set) var outputName: String?
    /// Called on the main queue when the output device changes or the engine fails.
    var onChange: ((Error?) -> Void)?

    private let processor = GainProcessor()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputID = AudioObjectID(kAudioObjectUnknown)
    private var listener: AudioObjectPropertyListenerBlock?
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() throws {
        stop()
        do {
            try build()
        } catch {
            teardown()
            throw error
        }
        isRunning = true
        addListener()
    }

    func stop() {
        removeListener()
        teardown()
        isRunning = false
    }

    // MARK: - Engine

    private func build() throws {
        let output = try CA.defaultOutputDevice()
        let outputUID = try CA.string(output, kAudioDevicePropertyDeviceUID)

        // Never tap our own output, or the boosted audio would feed back into itself.
        let me = try CA.ownProcessObject()
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        tap.uuid = UUID()
        tap.name = "Amplify"
        tap.isPrivate = true
        // Originals are muted only while we read the tap, so audio comes back if we die.
        tap.muteBehavior = .mutedWhenTapped
        try CA.check(AudioHardwareCreateProcessTap(tap, &tapID), "Creating the audio tap")

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Amplify",
            kAudioAggregateDeviceUIDKey: "work.mando.amplify.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try CA.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                     "Creating the output device")

        let format: AudioStreamBasicDescription = try CA.value(tapID, kAudioTapPropertyFormat)
        let rate: Float64 = (try? CA.value(aggregateID, kAudioDevicePropertyNominalSampleRate)) ?? format.mSampleRate
        processor.reset(sampleRate: rate, tapChannels: Int(format.mChannelsPerFrame))

        try CA.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [processor] _, input, _, output, _ in
            processor.process(input, output)
        }, "Creating the audio callback")
        try CA.check(AudioDeviceStart(aggregateID, procID), "Starting audio")

        outputID = output
        outputName = try? CA.string(output, kAudioObjectPropertyName)
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        outputID = AudioObjectID(kAudioObjectUnknown)
        outputName = nil
    }

    // MARK: - Follow the default output device (headphones plugged in, AirPods, etc.)

    private func addListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning,
                  let output = try? CA.defaultOutputDevice(), output != self.outputID else { return }
            self.teardown()
            do {
                try self.build()
                self.onChange?(nil)
            } catch {
                self.teardown()
                self.removeListener()
                self.isRunning = false
                self.onChange?(error)
            }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, .main, block)
    }

    private func removeListener() {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, .main, listener)
        self.listener = nil
    }
}

// MARK: - DSP

/// Runs on the real-time audio thread: no allocation, no locks.
final class GainProcessor: @unchecked Sendable {
    /// Written on the main thread, read on the audio thread (aligned Float stores are atomic).
    var targetGain: Float = 1

    private struct Channel {
        var data: UnsafeMutablePointer<Float>
        var stride: Int
    }

    private static let maxChannels = 64
    private let inputs = UnsafeMutablePointer<Channel>.allocate(capacity: maxChannels)
    private let outputs = UnsafeMutablePointer<Channel>.allocate(capacity: maxChannels)
    private var tapChannels = 2
    private var gain: Float = 1
    private var reduction: Float = 1
    private var smoothing: Float = 0.001
    private var release: Float = 0.0001
    /// Limiter ceiling, -1 dBFS.
    private let ceiling: Float = 0.891

    deinit {
        inputs.deallocate()
        outputs.deallocate()
    }

    /// Call before the audio callback starts.
    func reset(sampleRate: Double, tapChannels: Int) {
        let rate = Float(sampleRate > 0 ? sampleRate : 48_000)
        smoothing = 1 - exp(-1 / (0.03 * rate))   // ~30 ms gain glide, no zipper noise
        release = 1 - exp(-1 / (0.25 * rate))     // ~250 ms limiter release
        self.tapChannels = max(1, tapChannels)
        gain = targetGain
        reduction = 1
    }

    func process(_ inList: UnsafePointer<AudioBufferList>, _ outList: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inList))
        let outs = UnsafeMutableAudioBufferListPointer(outList)
        var frames = Int.max

        // The tap's streams come after any input streams the output device itself has.
        var first = ins.count
        var found = 0
        while first > 0 && found < tapChannels {
            first -= 1
            found += Int(ins[first].mNumberChannels)
        }
        var inCount = 0
        for b in first..<ins.count { collect(ins[b], into: inputs, &inCount, &frames) }
        var outCount = 0
        for b in outs { collect(b, into: outputs, &outCount, &frames) }
        guard outCount > 0, frames != .max else { return }

        guard inCount > 0 else {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }

        let target = targetGain
        for f in 0..<frames {
            gain += (target - gain) * smoothing

            var peak: Float = 0
            for c in 0..<inCount {
                peak = max(peak, abs(inputs[c].data[f * inputs[c].stride]))
            }
            peak *= gain
            // Peak limiter: instant attack, smooth release.
            reduction += (1 - reduction) * release
            if peak * reduction > ceiling { reduction = ceiling / peak }
            let m = gain * reduction

            for c in 0..<outCount {
                let sample: Float
                if outCount == 1 && inCount > 1 {
                    sample = (inputs[0].data[f * inputs[0].stride] + inputs[1].data[f * inputs[1].stride]) * 0.5
                } else if c < inCount {
                    sample = inputs[c].data[f * inputs[c].stride]
                } else if inCount == 1 && c == 1 {
                    sample = inputs[0].data[f * inputs[0].stride]
                } else {
                    sample = 0
                }
                outputs[c].data[f * outputs[c].stride] = sample * m
            }
        }
    }

    private func collect(_ buffer: AudioBuffer, into list: UnsafeMutablePointer<Channel>, _ count: inout Int, _ frames: inout Int) {
        let channels = Int(buffer.mNumberChannels)
        guard let data = buffer.mData, channels > 0 else { return }
        frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        let samples = data.assumingMemoryBound(to: Float.self)
        for c in 0..<channels where count < Self.maxChannels {
            list[count] = Channel(data: samples + c, stride: channels)
            count += 1
        }
    }
}

// MARK: - Core Audio helpers

struct CoreAudioError: LocalizedError {
    let action: String
    let status: OSStatus
    var errorDescription: String? { "\(action) failed (\(status.fourCharCode))" }
}

enum CA {
    static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw CoreAudioError(action: action, status: status) }
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "Reading audio property")
        return pointer.load(as: T.self)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Reading audio property")
        guard let value else { throw CoreAudioError(action: "Reading audio property", status: kAudioHardwareUnknownPropertyError) }
        return value.takeRetainedValue() as String
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        let device: AudioDeviceID = try value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        guard device != kAudioObjectUnknown else {
            throw CoreAudioError(action: "Finding an output device", status: kAudioHardwareBadDeviceError)
        }
        return device
    }

    static func ownProcessObject() throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "Finding this app's audio process")
        guard object != kAudioObjectUnknown else {
            throw CoreAudioError(action: "Finding this app's audio process", status: kAudioHardwareBadObjectError)
        }
        return object
    }
}

private extension OSStatus {
    var fourCharCode: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: self >> $0) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(self) }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

// MARK: - Permission

/// "System Audio Recording Only" permission, via the TCC calls Apple's own apps use.
/// Falls back to letting macOS prompt on first capture if they're unavailable.
enum AudioCapturePermission {
    enum Status { case granted, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static var status: Status {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Calls back on the main queue. Reports granted when the request can't be made,
    /// so starting the tap triggers the system prompt instead.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else {
            completion(true)
            return
        }
        unsafeBitCast(sym, to: RequestFn.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
