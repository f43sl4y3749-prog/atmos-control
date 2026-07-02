// AtmosDaemon — thin CLI over SpatialEngine. The Phase-1/2 debug harness:
// env-configurable, prints a 1 Hz diagnostic (captured/played/ringFill/peak + the
// 3116 personalized-HRTF signal). The real audio engine lives in SpatialEngine.
//
// Env:
//   SPATIALIZE=0|1   insert the spatial mixer (default 1; 0 = direct passthrough)
//   SRC_MODE=dual|bed|point|surround|surroundbed   dual PointSource L/R (default) |
//            stereo AmbienceBed | mono PointSource | 7.1.4 12-bus points | 7.1.4 AmbienceBed
//   OUTPUT_TYPE=headphones|builtin|external
//   HRTF_MODE=auto|on|off    PersonalizedHRTFMode
//   ALGO=useoutputtype|hrtf|hrtfhq
//   HEAD_TRACK=0|1   EnableHeadTracking (default 1)
//   DIST_ATTEN=0|1   distance-attenuate loudness (default 0 = distance-invariant)
//   REVERB=0|1       internal reverb (default 1; only audible under ALGO=hrtf/hrtfhq)
//   REVERB_BLEND=<0..100>   reverb wet/dry blend percent (default 20)
//   ROOM=small|medium|large ReverbRoomType (default medium)
//   OUTPUT_DEVICE=<substr>   real output device (default: AirPods, else default output)
//   RUN_SECONDS=N    auto-stop after N seconds (0/unset = until Ctrl-C)

import Foundation
import CoreAudio
import SpatialEngine

setvbuf(stdout, nil, _IONBF, 0)
print("=== AtmosDaemon (SpatialEngine CLI) ===")

func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
func envFlag(_ k: String, default def: Bool) -> Bool {
    guard let v = env(k)?.lowercased() else { return def }
    return v == "1" || v == "yes" || v == "true" || v == "on"
}

// --- Build config from env ---
var cfg = SpatialConfig()
cfg.spatialize = envFlag("SPATIALIZE", default: true)
switch env("SRC_MODE")?.lowercased() {
case "bed":        cfg.sourceMode = .ambienceBedStereo
case "point":      cfg.sourceMode = .pointSourceMono
case "surround":   cfg.sourceMode = .surround714
case "surroundbed": cfg.sourceMode = .surroundBed714
default:           cfg.sourceMode = .dualPointStereo
}
switch env("OUTPUT_TYPE")?.lowercased() {
case "builtin":  cfg.outputType = .builtInSpeakers
case "external": cfg.outputType = .externalSpeakers
default:         cfg.outputType = .headphones
}
switch env("HRTF_MODE")?.lowercased() {
case "on":  cfg.hrtfMode = .on
case "off": cfg.hrtfMode = .off
default:    cfg.hrtfMode = .auto
}
switch env("ALGO")?.lowercased() {
case "hrtf":   cfg.algorithm = .hrtf
case "hrtfhq": cfg.algorithm = .hrtfHQ
default:       cfg.algorithm = .useOutputType
}
cfg.headTracking = envFlag("HEAD_TRACK", default: true)
cfg.distanceAttenuation = envFlag("DIST_ATTEN", default: false)
cfg.reverbEnabled = envFlag("REVERB", default: true)
if let b = env("REVERB_BLEND").flatMap({ Float($0) }) { cfg.reverbBlend = b }
switch env("ROOM")?.lowercased() {
case "small": cfg.reverbRoomType = .small
case "large": cfg.reverbRoomType = .large
case "medium": cfg.reverbRoomType = .medium
default: break
}

let engine = SpatialEngine()
engine.logger = { print($0) }
engine.config = cfg

// --- Resolve output device from OUTPUT_DEVICE substring ---
var requestedOutput: AudioDeviceID? = nil
if let needle = env("OUTPUT_DEVICE")?.lowercased() {
    requestedOutput = engine.outputDevices().first { $0.name.lowercased().contains(needle) }?.id
    if requestedOutput == nil { print("WARNING: no output device matches OUTPUT_DEVICE='\(needle)' — using default") }
} else {
    requestedOutput = engine.outputDevices().first { $0.isAirPods }?.id
}

print("Mode           : \(cfg.spatialize ? "SPATIALIZE (\(cfg.sourceMode.label))" : "PASSTHROUGH")  HeadTrack=\(cfg.headTracking ? 1 : 0)")
print("Config         : OutputType=\(cfg.outputType.label)  HRTFMode=\(cfg.hrtfMode.label)  Algo=\(cfg.algorithm.label)")
print()

do {
    try engine.start(outputDeviceID: requestedOutput)
} catch {
    print("FATAL: \(error)")
    exit(1)
}
print("\nRunning. Press Ctrl-C to stop.\n")

// --- SIGINT ---
nonisolated(unsafe) var shouldQuit = false
signal(SIGINT) { _ in shouldQuit = true }

// --- Diagnostic loop (1 Hz) ---
let runSeconds = UInt64(env("RUN_SECONDS") ?? "") ?? 0
var lastCap: UInt64 = 0, lastPlay: UInt64 = 0, tick: UInt64 = 0
var everEngaged = false

while !shouldQuit {
    if runSeconds > 0 && tick >= runSeconds { break }
    usleep(1_000_000)
    tick += 1
    let s = engine.pollState()
    let dCap = s.totalCaptured - lastCap, dPlay = s.totalPlayed - lastPlay
    let pk = max(s.peakL, s.peakR)
    let pkDb = pk > 0 ? 20 * log10(Double(pk)) : -120.0
    if s.personalizedHRTFEngaged { everEngaged = true }
    let tag = cfg.spatialize ? "  3116=\(s.personalizedHRTFEngaged ? "YES" : "NO")" : ""
    print(String(format: "t=%2lus  captured=%llu (+%llu)  played=%llu (+%llu)  ringFill=%llu  peak=%.4f (%.1f dBFS)%@",
                 tick, s.totalCaptured, dCap, s.totalPlayed, dPlay, s.ringFill, Double(pk), pkDb, tag))
    if tick >= 3 && s.totalCaptured == 0 {
        print("WARNING: captured==0 — is atmos-control the default output with an active audio source?")
    }
    lastCap = s.totalCaptured; lastPlay = s.totalPlayed
}

print("\nStopping...")
engine.stop()
if cfg.spatialize {
    print("3116 personalized HRTF ever engaged: \(everEngaged ? "YES" : "NO")")
}
print("Done.")
