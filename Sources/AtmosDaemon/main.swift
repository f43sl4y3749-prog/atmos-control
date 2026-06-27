// AtmosDaemon — thin CLI over SpatialEngine. The Phase-1/2 debug harness:
// env-configurable, prints a 1 Hz diagnostic (captured/played/ringFill/peak + the
// 3116 personalized-HRTF signal). The real audio engine lives in SpatialEngine.
//
// Env:
//   SPATIALIZE=0|1   insert the spatial mixer (default 1; 0 = direct passthrough)
//   SRC_MODE=bed|point   stereo AmbienceBed (default) vs mono PointSource
//   OUTPUT_TYPE=headphones|builtin|external
//   HRTF_MODE=auto|on|off    PersonalizedHRTFMode
//   ALGO=useoutputtype|hrtf|hrtfhq
//   HEAD_TRACK=0|1   EnableHeadTracking (default 1)
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
cfg.sourceMode = (env("SRC_MODE")?.lowercased() == "point") ? .pointSourceMono : .ambienceBedStereo
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
