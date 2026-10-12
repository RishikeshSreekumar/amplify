import AudioToolbox
import CoreAudio
import Foundation

/// The current default output, described for the UI and per-device memory.
struct OutputDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    /// Device UID plus, for devices with switchable outputs, which one is active.
    let key: String
    let isHeadphones: Bool

    static func current() -> OutputDevice? {
        guard let id = try? CA.defaultOutputDevice() else { return nil }
        let uid = (try? CA.string(id, kAudioDevicePropertyDeviceUID)) ?? String(id)
        let name = (try? CA.string(id, kAudioObjectPropertyName)) ?? "Output"
        var key = uid
        var dataSource: UInt32?
        if CA.has(id, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput) {
            dataSource = try? CA.value(id, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
            if let dataSource { key += "/" + OSStatus(bitPattern: dataSource).fourCharCode }
        }
        let transport: UInt32 = (try? CA.value(id, kAudioDevicePropertyTransportType)) ?? 0
        let headphones = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
            || dataSource == 0x6864_706E  // 'hdpn'
            || name.localizedCaseInsensitiveContains("headphone")
        return OutputDevice(id: id, name: name, key: key, isHeadphones: headphones)
    }

    /// The device's own volume (0–1) and mute state, or nil if it has no volume control.
    var volume: (level: Float, muted: Bool)? {
        let scope = kAudioDevicePropertyScopeOutput
        var level: Float32?
        if CA.has(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope) {
            level = try? CA.value(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
        }
        if level == nil {
            for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
                var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
                var value: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectHasProperty(id, &address), AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr {
                    level = value
                    break
                }
            }
        }
        guard let level else { return nil }
        let muted: UInt32 = (try? CA.value(id, kAudioDevicePropertyMute, scope)) ?? 0
        return (level, muted != 0)
    }
}

/// Captures what the Mac is playing with Core Audio process taps (muting the originals),
/// runs it through `AudioProcessor`, and plays the result on the default output.
///
/// One global tap carries every app at its normal level. Each app with its own level
/// gets a separate tap (and is excluded from the global one), so it can be mixed in
/// at a different gain. All taps and the output device live in one private aggregate
/// device, so they share a clock. Needs macOS 14.2+ and System Audio Recording permission.
final class AudioEngine {
    /// Effects and boost. Tap gains are filled in from `appGains`.
    var params = DSPParams() { didSet { push() } }
    /// Gain per app bundle ID (0 = muted). Apps not listed play at 1.
    var appGains: [String: Float] = [:] {
        didSet {
            if isRunning && Set(appGains.keys) != Set(oldValue.keys) { syncTaps() } else { push() }
        }
    }
    private(set) var isRunning = false
    private(set) var output = OutputDevice.current()
    var onOutputChange: (() -> Void)?
    var onProcessesChange: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private let processor = AudioProcessor()
    private var tapIDs: [AudioObjectID] = []
    /// Apps with their own tap and the processes it covers.
    private var tappedApps: [(bundleID: String, processes: Set<AudioObjectID>)] = []
    /// Which app each input stream's tap carries, in stream order (nil = the global tap).
    private var tapBundleIDs: [String?] = [nil]
    /// Stream order of the taps as last built (indices into creation order), for tests.
    private(set) var debugTapOrder: [Int] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var runningOutput = AudioObjectID(kAudioObjectUnknown)
    private var watchedDevice = AudioObjectID(kAudioObjectUnknown)

    private var defaultOutputAddress = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
    private var processListAddress = CA.address(kAudioHardwarePropertyProcessObjectList)
    private var dataSourceAddress = CA.address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
    private lazy var outputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputChanged() }
    private lazy var processListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processesChanged() }
    private lazy var dataSourceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        self.output = OutputDevice.current()
        self.onOutputChange?()
    }

    init() {
        AudioObjectAddPropertyListenerBlock(CA.system, &defaultOutputAddress, .main, outputListener)
        AudioObjectAddPropertyListenerBlock(CA.system, &processListAddress, .main, processListener)
        watchDataSource()
    }

    func start() throws {
        stop()
        do {
            try build()
        } catch {
            teardown()
            throw error
        }
        isRunning = true
    }

    func stop() {
        teardown()
        isRunning = false
    }

    /// Peak levels and limiter reduction since the last call.
    func readMeters() -> (input: Float, output: Float, reduction: Float) {
        processor.readMeters()
    }

    // MARK: - Engine

    private func build() throws {
        let device = try CA.defaultOutputDevice()
        let outputUID = try CA.string(device, kAudioDevicePropertyDeviceUID)
        let groups = desiredTapGroups()

        // Never tap our own output, or the boosted audio would feed back into itself.
        let me = try CA.ownProcessObject()
        var descriptions = [CATapDescription(stereoGlobalTapButExcludeProcesses: [me] + groups.flatMap(\.processes))]
        descriptions += groups.map { CATapDescription(stereoMixdownOfProcesses: Array($0.processes)) }

        var ids: [AudioObjectID] = []
        for d in descriptions {
            d.uuid = UUID()
            d.name = "Amplify"
            d.isPrivate = true
            // Originals are muted only while we read the tap, so audio comes back if we die.
            d.muteBehavior = .mutedWhenTapped
            var id = AudioObjectID(kAudioObjectUnknown)
            try CA.check(AudioHardwareCreateProcessTap(d, &id), "Creating the audio tap")
            ids.append(id)
            tapIDs.append(id)  // tracked right away so teardown cleans up a partial build
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Amplify",
            kAudioAggregateDeviceUIDKey: "work.mando.amplify.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: descriptions.map {
                [kAudioSubTapUIDKey: $0.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            },
        ]
        try CA.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                     "Creating the output device")

        // Input streams follow the aggregate's active tap order, which may differ from ours.
        var order = Array(ids.indices)
        let uuids = descriptions.map { $0.uuid.uuidString.uppercased() }
        if let subTaps: [AudioObjectID] = try? CA.array(aggregateID, kAudioAggregateDevicePropertySubTapList) {
            let found = subTaps.compactMap { (try? CA.string($0, kAudioTapPropertyUID)).flatMap { uuids.firstIndex(of: $0.uppercased()) } }
            if found.count == ids.count, Set(found).count == ids.count { order = found }
        }
        debugTapOrder = order
        tappedApps = groups
        tapBundleIDs = order.map { $0 == 0 ? nil : groups[$0 - 1].bundleID }

        let channels = order.map { i -> Int in
            let format: AudioStreamBasicDescription? = try? CA.value(ids[i], kAudioTapPropertyFormat)
            return Int(format?.mChannelsPerFrame ?? 2)
        }
        let rate: Float64 = (try? CA.value(aggregateID, kAudioDevicePropertyNominalSampleRate)) ?? 48_000
        push()
        processor.reset(sampleRate: rate, tapChannels: channels)

        try CA.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [processor] _, input, _, output, _ in
            processor.process(input, output)
        }, "Creating the audio callback")
        try CA.check(AudioDeviceStart(aggregateID, procID), "Starting audio")
        runningOutput = device
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        tapIDs.forEach { AudioHardwareDestroyProcessTap($0) }
        tapIDs = []
        tappedApps = []
        tapBundleIDs = [nil]
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        runningOutput = AudioObjectID(kAudioObjectUnknown)
    }

    /// Sends the effect settings plus per-tap gains (in stream order) to the audio thread.
    private func push() {
        var p = params
        p.tapGains = SIMD16(repeating: 1)
        for (position, bundleID) in tapBundleIDs.prefix(AudioProcessor.maxTaps).enumerated() {
            if let bundleID { p.tapGains[position] = appGains[bundleID] ?? 1 }
        }
        processor.update(p)
    }

    /// Apps with their own level that currently have audio processes.
    private func desiredTapGroups() -> [(bundleID: String, processes: Set<AudioObjectID>)] {
        guard !appGains.isEmpty else { return [] }
        return AppAudio.apps()
            .filter { appGains[$0.bundleID] != nil && !$0.processes.isEmpty }
            .prefix(AudioProcessor.maxTaps - 1)
            .map { ($0.bundleID, Set($0.processes)) }
            .sorted { $0.bundleID < $1.bundleID }
    }

    /// Rebuilds the taps if the set of separately-levelled app processes changed.
    private func syncTaps() {
        let desired = desiredTapGroups()
        guard desired.map(\.bundleID) != tappedApps.map(\.bundleID)
              || desired.map(\.processes) != tappedApps.map(\.processes) else { return push() }
        restart()
    }

    private func restart() {
        teardown()
        do {
            try build()
        } catch {
            teardown()
            isRunning = false
            onFailure?(error)
        }
    }

    // MARK: - Listeners

    private func outputChanged() {
        output = OutputDevice.current()
        watchDataSource()
        if isRunning, let output, output.id != runningOutput { restart() }
        onOutputChange?()
    }

    private func processesChanged() {
        if isRunning { syncTaps() }
        onProcessesChange?()
    }

    private func watchDataSource() {
        if watchedDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &dataSourceAddress, .main, dataSourceListener)
            watchedDevice = AudioObjectID(kAudioObjectUnknown)
        }
        guard let id = output?.id, CA.has(id, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput) else { return }
        AudioObjectAddPropertyListenerBlock(id, &dataSourceAddress, .main, dataSourceListener)
        watchedDevice = id
    }
}
