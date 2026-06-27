// SpatialEngine/Devices.swift — CoreAudio device enumeration + default-output
// routing (no entitlement required).

import CoreAudio

let kAtmosControlUID = "atmos-control:loopback:0"

func allDeviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
          dataSize > 0 else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr
        else { return [] }
    return ids
}

func deviceUID(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cfStr: Unmanaged<CFString>? = nil
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, &cfStr) == noErr, let s = cfStr else { return "" }
    return s.takeRetainedValue() as String
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cfStr: Unmanaged<CFString>? = nil
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, &cfStr) == noErr, let s = cfStr else { return "" }
    return s.takeRetainedValue() as String
}

func deviceHasChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else { return false }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    var sz = dataSize
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, raw) == noErr else { return false }
    return raw.bindMemory(to: AudioBufferList.self, capacity: 1).pointee.mNumberBuffers > 0
}

func findAtmosControlDevice() -> AudioDeviceID? {
    for id in allDeviceIDs() where deviceUID(id) == kAtmosControlUID { return id }
    for id in allDeviceIDs() where deviceName(id).lowercased().contains("atmos-control") { return id }
    return nil
}

func defaultOutputDeviceID(system: Bool = false) -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
        mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice
                          : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(kAudioObjectUnknown)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev)
    return dev
}

@discardableResult
func setDefaultOutputDeviceID(_ id: AudioDeviceID, system: Bool) -> OSStatus {
    var dev = id
    var addr = AudioObjectPropertyAddress(
        mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice
                          : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}
