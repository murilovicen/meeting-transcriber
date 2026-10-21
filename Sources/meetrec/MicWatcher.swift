import CoreAudio
import Foundation

struct MicUser: Hashable {
    let pid: pid_t
    let bundleID: String
}

/// Bundle IDs that grab the mic but are never a meeting.
let ignoredBundlePrefixes = [
    "com.apple.siri",
    "com.apple.speechrecognitioncore",
    "com.apple.corespeech",
    "com.apple.assistantd",
    "com.apple.dictation",
    "com.apple.accessibility",
    "com.apple.hearing",
]

/// Every process except us that is currently capturing audio input (macOS 14.4+).
func currentMicUsers() -> [MicUser] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

    let me = getpid()
    var users: [MicUser] = []
    for id in ids {
        var running: UInt32 = 0
        var s = UInt32(MemoryLayout<UInt32>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running) == noErr, running != 0 else { continue }

        var pid: pid_t = 0
        s = UInt32(MemoryLayout<pid_t>.size)
        a.mSelector = kAudioProcessPropertyPID
        AudioObjectGetPropertyData(id, &a, 0, nil, &s, &pid)
        if pid == me { continue }

        var bundle: Unmanaged<CFString>?
        s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        a.mSelector = kAudioProcessPropertyBundleID
        AudioObjectGetPropertyData(id, &a, 0, nil, &s, &bundle)
        let bundleID = (bundle?.takeRetainedValue() as String?) ?? "pid-\(pid)"
        if ignoredBundlePrefixes.contains(where: { bundleID.lowercased().hasPrefix($0) }) { continue }

        users.append(MicUser(pid: pid, bundleID: bundleID))
    }
    return users
}
