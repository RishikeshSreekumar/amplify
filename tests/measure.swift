// End-to-end boost measurement. Plays a sine tone, then uses two Core Audio
// process taps to read (1) this tool's own output: the reference signal Amplify
// receives, and (2) Amplify's output: the boosted signal it sends to the device.
// Taps read audio before the device volume, so speaker volume doesn't matter.
//
// Prints: reference_rms=… boosted_rms=… boosted_peak=… gain=…
// Usage: measure [--amplitude 0.1] [--frequency 1000] [--seconds 2]
// Run through tests/run.sh, which wraps it in an app bundle so macOS can grant it
// System Audio Recording permission.
import AppKit
import AVFoundation
import CoreAudio

func arg(_ name: String, _ fallback: Double) -> Double {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count, let v = Double(a[i + 1]) else { return fallback }
    return v
}

let amplitude = Float(arg("--amplitude", 0.1))
let frequency = arg("--frequency", 1000)
let seconds = arg("--seconds", 2)

/// Accumulates RMS and peak of everything a tap delivers while `measuring` is on.
final class Meter: @unchecked Sendable {
    var measuring = false
    private(set) var sumSquares = 0.0
    private(set) var samples = 0
    private(set) var peak: Float = 0
    var rms: Double { samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0 }

    func process(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        for b in UnsafeMutableAudioBufferListPointer(output) {
            if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
        }
        guard measuring else { return }
        for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let d = b.mData else { continue }
            let p = d.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(b.mDataByteSize) / MemoryLayout<Float>.size {
                let s = p[i]
                sumSquares += Double(s * s)
                peak = max(peak, abs(s))
            }
            samples += Int(b.mDataByteSize) / MemoryLayout<Float>.size
        }
    }
}

/// Taps one process (without muting it) and feeds its audio to a Meter.
func tap(_ process: AudioObjectID, into meter: Meter) throws {
    let outputUID = try CA.string(try CA.defaultOutputDevice(), kAudioDevicePropertyDeviceUID)
    let desc = CATapDescription(stereoMixdownOfProcesses: [process])
    desc.uuid = UUID()
    desc.isPrivate = true
    desc.muteBehavior = .unmuted
    var tapID = AudioObjectID(kAudioObjectUnknown)
    try CA.check(AudioHardwareCreateProcessTap(desc, &tapID), "Creating tap")

    let aggregate: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Amplify Test",
        kAudioAggregateDeviceUIDKey: "work.mando.amplify.test.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
    ]
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    try CA.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "Creating aggregate device")
    var procID: AudioDeviceIOProcID?
    try CA.check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, _, output, _ in
        meter.process(input, output)
    }, "Creating IOProc")
    try CA.check(AudioDeviceStart(deviceID, procID), "Starting tap")
    // Taps and aggregate devices are destroyed automatically when this process exits.
}

guard let amplify = NSRunningApplication.runningApplications(withBundleIdentifier: "work.mando.amplify").first else {
    FileHandle.standardError.write("Amplify is not running\n".data(using: .utf8)!)
    exit(2)
}

// --wait <seconds>: just wait until Amplify is playing audio (i.e. it has its own
// permission and its engine is running), then exit.
if CommandLine.arguments.contains("--wait") {
    let deadline = Date().addingTimeInterval(arg("--wait", 120))
    while Date() < deadline {
        if let object = try? CA.processObject(pid: amplify.processIdentifier),
           let running: UInt32 = try? CA.value(object, kAudioProcessPropertyIsRunningOutput), running != 0 {
            print("Amplify is running")
            exit(0)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    FileHandle.standardError.write("Amplify never started playing audio: allow its System Audio Recording permission.\n".data(using: .utf8)!)
    exit(4)
}

// Ask for System Audio Recording up front.
switch AudioCapturePermission.status {
case .granted: break
case .denied:
    FileHandle.standardError.write("System Audio Recording is denied for Amplify Test. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording.\n".data(using: .utf8)!)
    exit(3)
case .unknown:
    var answered = false
    AudioCapturePermission.request { granted in
        answered = true
        if !granted {
            FileHandle.standardError.write("System Audio Recording was not allowed.\n".data(using: .utf8)!)
            exit(3)
        }
    }
    while !answered { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
}

let reference = Meter()
let boosted = Meter()

// Play the tone.
let engine = AVAudioEngine()
let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
var phase = 0.0
let step = 2 * Double.pi * frequency / rate
let source = AVAudioSourceNode(format: format) { _, _, frameCount, list in
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    for f in 0..<Int(frameCount) {
        let s = amplitude * Float(sin(phase))
        phase += step
        if phase > 2 * .pi { phase -= 2 * .pi }
        for b in buffers { b.mData!.assumingMemoryBound(to: Float.self)[f] = s }
    }
    return noErr
}
engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: format)

do {
    try engine.start()
    try tap(try CA.ownProcessObject(), into: reference)
    // With boost off, Amplify never touches audio and has no audio process: nothing to tap.
    if let object = try? CA.processObject(pid: amplify.processIdentifier) {
        try tap(object, into: boosted)
    }
} catch {
    FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

// Let device switching, the gain glide and drift compensation settle, then measure.
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
reference.measuring = true
boosted.measuring = true
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
reference.measuring = false
boosted.measuring = false
engine.stop()

let gain = reference.rms > 0 ? boosted.rms / reference.rms : 0
print(String(format: "reference_rms=%.5f boosted_rms=%.5f boosted_peak=%.5f gain=%.4f",
             reference.rms, boosted.rms, boosted.peak, gain))
if reference.rms == 0 {
    FileHandle.standardError.write("Reference tap is silent: allow System Audio Recording for Amplify Test.\n".data(using: .utf8)!)
    exit(3)
}
