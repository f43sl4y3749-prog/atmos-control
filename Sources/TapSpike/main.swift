// TapSpike — Phase 4 premium-tier proof. Captures the system mix via a MUTING
// process tap and re-spatializes it through our AUSpatialMixer, WITHOUT making any
// virtual device the system default. AirPods stay the default output, so Apple's
// personalized HRTF (property 3116) keeps engaging — the thing the virtual-default
// loopback architecture blocks.
//
// PRE-REQ: AirPods (with a scanned Personalized Spatial Audio profile) selected as
// the system output. No virtual driver / daemon needed.
//
// Env:
//   RUN_SECONDS=N        run length (default 15)
//   MUTE=0|1             1 = silence the original apps (default); 0 = capture only
//                        (non-disruptive, for plumbing checks)
//   OUTPUT_DEVICE=<sub>  output device substring (default: AirPods, else default)
//   HRTF_MODE=on|auto    PersonalizedHRTFMode (default on)

import Foundation
import CoreAudio
import AudioToolbox
import SpatialEngine

setvbuf(stdout, nil, _IONBF, 0)
func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
let runSeconds = Int(env("RUN_SECONDS") ?? "") ?? 15
let muted = (env("MUTE") ?? "1") != "0"

print("=== TapSpike — personalized HRTF (3116) via muting process tap ===")

// --- 0. Our own process object — excluded from the tap to avoid a feedback loop ---
func translatePID(_ pid: pid_t) -> AudioObjectID {
    var p = pid
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var obj = AudioObjectID(kAudioObjectUnknown)
    var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                        UInt32(MemoryLayout<pid_t>.size), &p, &sz, &obj)
    if st != noErr { print("  ERR TranslatePIDToProcessObject \(st)") }
    return obj
}
let selfObj = translatePID(getpid())
print("self process object = \(selfObj)")

// --- 1. Muted, private, global tap of all processes except ourselves ---
let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObj])
desc.isPrivate = true
desc.muteBehavior = muted ? CATapMuteBehavior.muted : CATapMuteBehavior.unmuted
print("tap: muted=\(muted) private=true exclude=[\(selfObj)]")

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
    print("  ERR AudioHardwareCreateProcessTap \(tapStatus)"); exit(1)
}
print("CreateProcessTap -> 0  tapID=\(tapID)")

func tapUID(_ id: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>? = nil
    var sz = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &cf) == noErr, let s = cf else { return nil }
    return s.takeRetainedValue() as String
}
@MainActor func destroyTap() { AudioHardwareDestroyProcessTap(tapID) }

guard let uid = tapUID(tapID) else { print("  ERR read tap UID"); destroyTap(); exit(1) }
print("tap UID = \(uid)")

// --- 2. Tap-only PRIVATE aggregate (no sub-devices, never the default) ---
let aggUID = UUID().uuidString
let tapEntry: [String: Any] = [
    kAudioSubTapUIDKey as String: uid,
    kAudioSubTapDriftCompensationKey as String: true,
]
let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey as String:          "atmos-tap-spike",
    kAudioAggregateDeviceUIDKey as String:           aggUID,
    kAudioAggregateDeviceIsPrivateKey as String:     true,
    kAudioAggregateDeviceIsStackedKey as String:     false,
    kAudioAggregateDeviceTapAutoStartKey as String:  true,
    kAudioAggregateDeviceSubDeviceListKey as String: [],
    kAudioAggregateDeviceTapListKey as String:       [tapEntry],
]
var aggID = AudioDeviceID(kAudioObjectUnknown)
let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
guard aggStatus == noErr, aggID != kAudioObjectUnknown else {
    print("  ERR AudioHardwareCreateAggregateDevice \(aggStatus)"); destroyTap(); exit(1)
}
print("CreateAggregate -> 0  aggID=\(aggID)")
@MainActor func destroyAgg() { AudioHardwareDestroyAggregateDevice(aggID) }

// --- 3. Resolve the real output (AirPods); confirm the default is UNCHANGED ---
let engine = SpatialEngine()
engine.logger = { print($0) }
let outs = engine.outputDevices()
let wanted = env("OUTPUT_DEVICE")
let out: AudioOutputDevice? = {
    if let w = wanted, !w.isEmpty { return outs.first { $0.name.localizedCaseInsensitiveContains(w) } }
    return outs.first { $0.isAirPods } ?? outs.first { $0.id == SpatialEngine.currentDefaultOutput().id }
}()
let defBefore = SpatialEngine.currentDefaultOutput()
print("default output = [\(defBefore.id)] \(defBefore.name)  (must be AirPods for 3116=YES)")
if out?.isAirPods != true { print("  WARN no AirPods output found — 3116 will read NO (plumbing-only run)") }

// --- 4. Spatialize the tapped mix → AirPods, with personalization forced on ---
var cfg = SpatialConfig()
cfg.spatialize = true
cfg.outputType = .headphones
cfg.algorithm = .useOutputType
cfg.hrtfMode = (env("HRTF_MODE")?.lowercased() == "auto") ? .auto : .on
cfg.headTracking = true
engine.config = cfg

do {
    try engine.start(outputDeviceID: out?.id, captureDeviceID: aggID)
} catch {
    print("  ERR engine.start \(error)"); destroyAgg(); destroyTap(); exit(1)
}
print("engine started: capture=aggregate[\(aggID)] output=[\(out?.id ?? 0)] \(out?.name ?? "?")")
print("--- play audio in any app now ---")

var everEngaged = false
let firstCaptured = engine.pollState().totalCaptured
var lastCaptured = firstCaptured
for t in 1...max(1, runSeconds) {
    Thread.sleep(forTimeInterval: 1)
    let s = engine.pollState()
    let on = engine.readPersonalizedHRTFEngaged()
    if on { everEngaged = true }
    lastCaptured = s.totalCaptured
    print(String(format: "t=%2ds  captured=%llu  played=%llu  ringFill=%llu  peak=%.4f  3116=%@",
                 t, s.totalCaptured, s.totalPlayed, s.ringFill, s.peakL, on ? "YES" : "NO"))
}

engine.stop()
destroyAgg()
destroyTap()

let defAfter = SpatialEngine.currentDefaultOutput()
let captureRose = lastCaptured > firstCaptured
print("---")
print("default output after = [\(defAfter.id)] \(defAfter.name)  (\(defAfter.id == defBefore.id ? "UNCHANGED ✅" : "CHANGED ❌"))")
print("captured rose (audio flowed through the tap): \(captureRose ? "YES ✅" : "NO — was anything playing?")")
print("3116 personalized HRTF engaged at any point: \(everEngaged ? "YES ✅ — premium unlock CONFIRMED" : "NO ❌")")
