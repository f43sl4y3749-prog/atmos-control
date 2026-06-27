// SpatialEngine/ProcessTap.swift — Core Audio process tap + tap-only aggregate.
//
// Captures the whole system mix (optionally MUTING the original apps so we can
// re-render it) WITHOUT becoming the system default output. AirPods therefore stay
// the default, and Apple's personalized HRTF (AUSpatialMixer property 3116) keeps
// engaging — the thing the virtual-default-loopback path fundamentally blocks.
// It also removes the black-hole failure mode (no default-device hijack). macOS 14.2+.

import CoreAudio
import AudioToolbox
import Foundation

public enum ProcessTapError: Error, CustomStringConvertible {
    case createTapFailed(OSStatus)
    case tapUIDUnavailable
    case createAggregateFailed(OSStatus)
    public var description: String {
        switch self {
        case .createTapFailed(let s):       return "AudioHardwareCreateProcessTap failed (\(s)) — needs macOS 14.2+ / audio-capture consent"
        case .tapUIDUnavailable:            return "process tap UID unavailable"
        case .createAggregateFailed(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))"
        }
    }
}

/// Owns one muting process tap + its private aggregate device. Create on the main
/// thread; the returned aggregate id is used as a normal capture device.
public final class ProcessTap {
    public private(set) var aggregateID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    public init() {}

    public var isActive: Bool { aggregateID != AudioDeviceID(kAudioObjectUnknown) }

    /// Create the tap + private aggregate; returns the aggregate device id to capture from.
    /// `muted` silences the tapped apps at the hardware (we re-render their audio ourselves).
    @discardableResult
    public func start(muted: Bool = true) throws -> AudioDeviceID {
        let selfObj = ProcessTap.translatePID(getpid())   // exclude ourselves → no feedback
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObj])
        desc.isPrivate = true
        // .mutedWhenTapped silences the tapped apps only while we're actively reading, so
        // if audio-capture consent is denied the user hears the original audio, not silence.
        desc.muteBehavior = muted ? CATapMuteBehavior.mutedWhenTapped : CATapMuteBehavior.unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let ts = AudioHardwareCreateProcessTap(desc, &tap)
        guard ts == noErr, tap != AudioObjectID(kAudioObjectUnknown) else { throw ProcessTapError.createTapFailed(ts) }
        tapID = tap

        guard let uid = ProcessTap.tapUID(tap) else { destroy(); throw ProcessTapError.tapUIDUnavailable }

        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey as String: uid,
            kAudioSubTapDriftCompensationKey as String: true,
        ]
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:          "atmos-control-tap",
            kAudioAggregateDeviceUIDKey as String:           UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String:     true,
            kAudioAggregateDeviceIsStackedKey as String:     false,
            kAudioAggregateDeviceTapAutoStartKey as String:  true,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String:       [tapEntry],
        ]
        var agg = AudioDeviceID(kAudioObjectUnknown)
        let asg = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &agg)
        guard asg == noErr, agg != AudioDeviceID(kAudioObjectUnknown) else { destroy(); throw ProcessTapError.createAggregateFailed(asg) }
        aggregateID = agg
        return agg
    }

    public func stop() { destroy() }

    private func destroy() {
        if aggregateID != AudioDeviceID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: helpers

    private static func translatePID(_ pid: pid_t) -> AudioObjectID {
        var p = pid
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), &p, &sz, &obj)
        return obj
    }

    private static func tapUID(_ id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>? = nil
        var sz = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &cf) == noErr, let s = cf else { return nil }
        return s.takeRetainedValue() as String
    }
}
