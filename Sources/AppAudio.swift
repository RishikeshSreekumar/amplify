import AppKit
import CoreAudio

/// An app that has (or had) audio processes, grouped by the app responsible for them.
/// Browsers play audio from helper processes (Chrome Helper, WebKit GPU), so those
/// are folded into the app the user sees.
struct AudioApp: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let isPlaying: Bool
    /// A regular app with a Dock icon (as opposed to a background daemon).
    let isUserApp: Bool
    let processes: [AudioObjectID]

    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}

enum AppAudio {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    /// Every app with an audio process right now, excluding Amplify itself.
    static func apps() -> [AudioApp] {
        let objects: [AudioObjectID] = (try? CA.array(CA.system, kAudioHardwarePropertyProcessObjectList)) ?? []
        var groups: [String: (name: String, playing: Bool, userApp: Bool, processes: [AudioObjectID])] = [:]
        let me = getpid()

        for object in objects {
            guard let pid: pid_t = try? CA.value(object, kAudioProcessPropertyPID), pid != me else { continue }
            let ownBundle = try? CA.string(object, kAudioProcessPropertyBundleID)
            let running: UInt32 = (try? CA.value(object, kAudioProcessPropertyIsRunningOutput)) ?? 0
            let playing = running != 0

            let owner = responsible?(pid) ?? pid
            let app = NSRunningApplication(processIdentifier: owner > 0 ? owner : pid)
                ?? NSRunningApplication(processIdentifier: pid)
            guard let bundleID = app?.bundleIdentifier ?? ownBundle, !bundleID.isEmpty,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            let name = app?.localizedName ?? bundleID.components(separatedBy: ".").last ?? bundleID

            var group = groups[bundleID] ?? (name, false, app?.activationPolicy == .regular, [])
            group.playing = group.playing || playing
            group.processes.append(object)
            groups[bundleID] = group
        }

        return groups.map {
            AudioApp(bundleID: $0.key, name: $0.value.name, isPlaying: $0.value.playing,
                     isUserApp: $0.value.userApp, processes: $0.value.processes)
        }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
