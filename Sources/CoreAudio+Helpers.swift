import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let action: String
    let status: OSStatus
    var errorDescription: String? { "\(action) failed (\(status.fourCharCode))" }
}

/// Thin wrappers over the Core Audio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw CoreAudioError(action: action, status: status) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = address(selector, scope)
        return AudioObjectHasProperty(object, &address)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var address = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "Reading audio property")
        return pointer.load(as: T.self)
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Reading audio property")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "Reading audio property")
        return Array(UnsafeBufferPointer(start: pointer, count: Int(size) / MemoryLayout<T>.stride))
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
        let device: AudioDeviceID = try value(system, kAudioHardwarePropertyDefaultOutputDevice)
        guard device != kAudioObjectUnknown else {
            throw CoreAudioError(action: "Finding an output device", status: kAudioHardwareBadDeviceError)
        }
        return device
    }

    static func processObject(pid: pid_t) throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "Finding audio process \(pid)")
        guard object != kAudioObjectUnknown else {
            throw CoreAudioError(action: "Finding audio process \(pid)", status: kAudioHardwareBadObjectError)
        }
        return object
    }

    static func ownProcessObject() throws -> AudioObjectID {
        try processObject(pid: getpid())
    }
}

extension OSStatus {
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
