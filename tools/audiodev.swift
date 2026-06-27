// tools/audiodev.swift — tiny CoreAudio device utility (Phase 1 component #2 seed)
//
// Usage:
//   audiodev list                  list all output-capable devices (id + name)
//   audiodev get-output            print current default output device id+name
//   audiodev set-output <substr>   set default output (and system output) to the
//                                  first output device whose name contains <substr>
//
// No entitlement required. Compile: swiftc tools/audiodev.swift -o <bin>

import CoreAudio
import Foundation

func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let r = ref else { return "<?>" }
    return r.takeRetainedValue() as String
}

func outputChannelCount(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let abl = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { abl.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, abl) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(abl.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func currentDefaultOutput() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return dev
}

func setDefaultOutput(_ id: AudioDeviceID, system: Bool) -> OSStatus {
    var dev = id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice
                          : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &dev)
}

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "list"

switch cmd {
case "list":
    for id in allDevices() where outputChannelCount(id) > 0 {
        print("\(id)\t\(outputChannelCount(id))ch\t\(deviceName(id))")
    }
case "get-output":
    let id = currentDefaultOutput()
    print("\(id)\t\(deviceName(id))")
case "get-both":
    // Show BOTH the main (app-audio) and system (alert-sound) default outputs.
    var sysId = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &sysId)
    let mainId = currentDefaultOutput()
    print("main   \(mainId)\t\(deviceName(mainId))")
    print("system \(sysId)\t\(deviceName(sysId))")
case "set-output", "set-main", "set-system":
    guard args.count > 2 else { FileHandle.standardError.write("usage: \(cmd) <substr>\n".data(using:.utf8)!); exit(2) }
    let needle = args[2].lowercased()
    let match = allDevices().first { outputChannelCount($0) > 0 && deviceName($0).lowercased().contains(needle) }
    guard let dev = match else { FileHandle.standardError.write("no output device matching '\(needle)'\n".data(using:.utf8)!); exit(1) }
    switch cmd {
    case "set-main":
        let s = setDefaultOutput(dev, system: false)
        print("set MAIN default output -> \(dev) \(deviceName(dev))  (status=\(s))")
    case "set-system":
        let s = setDefaultOutput(dev, system: true)
        print("set SYSTEM default output -> \(dev) \(deviceName(dev))  (status=\(s))")
    default:
        let s1 = setDefaultOutput(dev, system: false)
        let s2 = setDefaultOutput(dev, system: true)
        print("set default output (both) -> \(dev) \(deviceName(dev))  (status main=\(s1) system=\(s2))")
    }
default:
    FileHandle.standardError.write("commands: list | get-output | get-both | set-output <substr> | set-main <substr> | set-system <substr>\n".data(using:.utf8)!); exit(2)
}
