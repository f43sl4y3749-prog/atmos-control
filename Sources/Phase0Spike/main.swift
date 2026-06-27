// Sources/Phase0Spike/main.swift
//
// Phase 0 de-risk spike — AUSpatialMixer personalised + head-tracked binaural.
//
// Instantiates AUSpatialMixer, sets every relevant property (personalized HRTF,
// head tracking, output type = headphones), plays a test signal to the default
// output device, and polls property 3116 every second to report whether
// personalized HRTF actually engaged.
//
// Build:   swift build
// Run:     .build/debug/Phase0Spike [optional-audio-file.wav]
// Env:     SECONDS=N   override run duration (default 25 s)
//          SWEEP=1     sweep azimuth from -90° to +90° across the run
//
// Swift 6 strict-concurrency notes
// ---------------------------------
// This file runs as top-level main.swift code.  All mutable globals that are
// shared with DispatchSource handlers are declared nonisolated(unsafe) — the
// programmer ensures they are only accessed on the main thread / main queue.
// The AVAudioUnit instantiation result is captured via a semaphore-protected
// module-level variable.

import Foundation
@preconcurrency import AVFAudio   // @preconcurrency: suppresses Sendable warnings from AVFAudio types
import AudioToolbox
import CoreAudio

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Property IDs
//
// The four-digit numeric IDs are used because some are not exported as Swift
// symbols in the AudioToolbox overlay on CLT-only installs.
// Values are from <AudioToolbox/AudioUnitProperties.h> / macOS 26.5 SDK.
// ─────────────────────────────────────────────────────────────────────────────

let kPropSourceMode:                    AudioUnitPropertyID = 3005
// ^ kAudioUnitProperty_SpatialMixerSourceMode

let kPropOutputType:                    AudioUnitPropertyID = 3100
// ^ kAudioUnitProperty_SpatialMixerOutputType

let kPropEnableHeadTracking:            AudioUnitPropertyID = 3111
// ^ kAudioUnitProperty_SpatialMixerEnableHeadTracking  (macOS 12.3+)

let kPropPersonalizedHRTFMode:          AudioUnitPropertyID = 3113
// ^ kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode  (macOS 13+)

let kPropAnyInputUsingPersonalizedHRTF: AudioUnitPropertyID = 3116
// ^ kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF (macOS 14+)
//   READ-ONLY, UInt32 0/1.  This is the primary signal we are testing.

// Enum values
let kSpatAlgUseOutputType:  UInt32 = 7   // kSpatializationAlgorithm_UseOutputType
let kSrcModePointSource:    UInt32 = 2   // kSpatialMixerSourceMode_PointSource
let kOutputTypeHeadphones:  UInt32 = 1   // kSpatialMixerOutputType_Headphones
let kPersonalizedHRTFOn:    UInt32 = 1   // kSpatialMixerPersonalizedHRTFMode_On

// Spatial mixer parameter IDs (raw values — symbolic names may not be in overlay)
let kParamAzimuth:   AudioUnitParameterID = 0   // kSpatialMixerParam_Azimuth   ±180°
let kParamElevation: AudioUnitParameterID = 1   // kSpatialMixerParam_Elevation  ±90°
let kParamDistance:  AudioUnitParameterID = 2   // kSpatialMixerParam_Distance   metres
let kParamGain:      AudioUnitParameterID = 3   // kSpatialMixerParam_Gain        dB

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Mutable globals (Swift 6 nonisolated(unsafe))
//
// gShouldStop : written by the SIGINT DispatchSource (dispatched to main queue)
//               and read in the polling loop on the main thread — safe.
// gAVUnit     : written once by AVAudioUnit.instantiate's callback before
//               the semaphore.signal(), then read after semaphore.wait() on the
//               main thread — no concurrent access.
// ─────────────────────────────────────────────────────────────────────────────

nonisolated(unsafe) var gShouldStop: Bool = false
nonisolated(unsafe) var gAVUnit: AVAudioUnit? = nil

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OSStatus formatting
// ─────────────────────────────────────────────────────────────────────────────

/// Returns "0 (OK)" for noErr, or "–10878 ('typ?')" otherwise.
func fmtStatus(_ s: OSStatus) -> String {
    guard s != noErr else { return "0 (OK)" }
    let bytes: [UInt8] = [
        UInt8((s >> 24) & 0xFF),
        UInt8((s >> 16) & 0xFF),
        UInt8((s >>  8) & 0xFF),
        UInt8( s        & 0xFF)
    ]
    if bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
       let cc = String(bytes: bytes, encoding: .ascii) {
        return "\(s) ('\(cc)')"
    }
    return "\(s)"
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Property helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Sets a UInt32 property, prints the set result, reads it back, prints the
/// read-back value, and returns whether the Set call succeeded.
@discardableResult
func setPropU32(au: AudioUnit,
                prop: AudioUnitPropertyID,
                scope: AudioUnitScope,
                element: AudioUnitElement,
                value: UInt32,
                label: String) -> Bool {
    var v = value
    let setStatus = AudioUnitSetProperty(au, prop, scope, element,
                                         &v, UInt32(MemoryLayout<UInt32>.size))
    let ok = (setStatus == noErr)
    print("  set \(label) -> \(fmtStatus(setStatus))")

    // Read-back to confirm the AU stored the value
    var rv: UInt32 = 0xDEAD_BEEF
    var rsz = UInt32(MemoryLayout<UInt32>.size)
    let getStatus = AudioUnitGetProperty(au, prop, scope, element, &rv, &rsz)
    if getStatus == noErr {
        print("  get \(label) -> \(rv)")
    } else {
        print("  get \(label) -> FAILED: \(fmtStatus(getStatus))")
    }
    return ok
}

/// Reads a UInt32 property; returns nil if the Get call fails.
func getPropU32(au: AudioUnit,
                prop: AudioUnitPropertyID,
                scope: AudioUnitScope,
                element: AudioUnitElement) -> UInt32? {
    var v: UInt32 = 0
    var sz = UInt32(MemoryLayout<UInt32>.size)
    return AudioUnitGetProperty(au, prop, scope, element, &v, &sz) == noErr ? v : nil
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Default output device name
// ─────────────────────────────────────────────────────────────────────────────

func defaultOutputDeviceName() -> String {
    // 1. Resolve default output device ID
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain)
    let s1 = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &deviceID)
    guard s1 == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
        return "<no default device; status \(fmtStatus(s1))>"
    }

    // 2. Fetch device name as a +1-retained CFString (Create rule)
    //    Using Unmanaged<CFString>? so we can call takeRetainedValue() and
    //    avoid a retain-count imbalance that would occur with a plain CFString? var.
    var nameRef: Unmanaged<CFString>? = nil
    var nameSz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    addr.mSelector = kAudioDevicePropertyDeviceNameCFString
    let s2 = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &nameSz, &nameRef)
    guard s2 == noErr, let ref = nameRef else {
        return "<name error: \(fmtStatus(s2))>"
    }
    return ref.takeRetainedValue() as String
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - White-noise generator
//
// Broadband noise localises more convincingly than a pure tone because the
// brain uses inter-aural level and phase differences across many frequencies.
// ─────────────────────────────────────────────────────────────────────────────

func generateWhiteNoise(sampleRate: Double = 48_000,
                        durationSeconds: Double = 2.0,
                        amplitude: Float = 0.15) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
    buf.frameLength = frameCount
    let ch = buf.floatChannelData![0]
    for i in 0..<Int(frameCount) {
        ch[i] = amplitude * Float.random(in: -1.0...1.0)
    }
    return buf
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Audio file loader
//
// Reads the entire file then converts it to mono 48 kHz float32 in one pass.
// We avoid chunk-by-chunk reading to sidestep any potential Swift 6 Sendable
// issues with the AVAudioConverter input callback capturing AVAudioFile state.
// ─────────────────────────────────────────────────────────────────────────────

func loadAudioFileMono48k(path: String) -> AVAudioPCMBuffer? {
    guard FileManager.default.fileExists(atPath: path) else {
        print("WARNING: file not found at \(path)")
        return nil
    }
    let url = URL(fileURLWithPath: path)
    guard let file = try? AVAudioFile(forReading: url) else {
        print("WARNING: could not open audio file \(path)")
        return nil
    }

    // Read entire source file into one buffer
    let srcCount = AVAudioFrameCount(file.length)
    guard let srcBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: srcCount) else { return nil }
    do {
        try file.read(into: srcBuf)
    } catch {
        print("WARNING: read error: \(error)")
        return nil
    }

    let targetFmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    if file.processingFormat == targetFmt {
        print("File already mono 48 kHz float32 — no conversion needed")
        return srcBuf
    }

    guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFmt) else {
        print("WARNING: no AVAudioConverter available for \(file.processingFormat)")
        return nil
    }

    let ratio = 48_000.0 / file.processingFormat.sampleRate
    let outCapacity = AVAudioFrameCount(Double(srcBuf.frameLength) * ratio) + 512
    guard let dstBuf = AVAudioPCMBuffer(pcmFormat: targetFmt,
                                         frameCapacity: outCapacity) else { return nil }

    // The input callback is called synchronously, at most twice per convert() call:
    // once to provide data, once to signal EOF.  We use a reference-type flag so
    // the @Sendable closure can mutate it without triggering Swift 6 warnings about
    // captured var mutation in concurrent code (the conversion is actually serial,
    // but AVAudioConverterInputBlock is typed @Sendable).
    final class InputGivenFlag: @unchecked Sendable { var value = false }
    let inputGivenFlag = InputGivenFlag()
    var convErr: NSError? = nil
    let convStatus = converter.convert(to: dstBuf, error: &convErr) { _, outStatus in
        if inputGivenFlag.value {
            outStatus.pointee = .endOfStream
            return nil
        }
        inputGivenFlag.value = true
        outStatus.pointee = .haveData
        return srcBuf
    }

    if convStatus == .error {
        print("WARNING: conversion failed: \(convErr?.localizedDescription ?? "unknown")")
        return nil
    }

    print("Loaded \(url.lastPathComponent): \(srcBuf.frameLength) fr @ \(file.processingFormat.sampleRate) Hz "
          + "-> \(dstBuf.frameLength) fr @ 48 kHz mono")
    return dstBuf
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Runtime configuration (env vars)
// ─────────────────────────────────────────────────────────────────────────────

let runSeconds: Int = {
    if let s = ProcessInfo.processInfo.environment["SECONDS"],
       let n = Int(s), n > 0 { return n }
    return 25
}()
let doSweep = (ProcessInfo.processInfo.environment["SWEEP"] == "1")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Context header
// ─────────────────────────────────────────────────────────────────────────────

print("═══════════════════════════════════════════════════════════════════════")
print("  Phase 0 Spike — AUSpatialMixer Personalized HRTF de-risk")
print("═══════════════════════════════════════════════════════════════════════")
print("macOS  : \(ProcessInfo.processInfo.operatingSystemVersionString)")
let devName = defaultOutputDeviceName()
print("Output : \(devName)")
if devName.localizedCaseInsensitiveContains("airpods") {
    print("         AirPods detected — personalized HRTF + head tracking possible")
} else {
    print("         WARNING: Not AirPods — property 3116 may remain NO")
}
print("Dur    : \(runSeconds) s    Sweep: \(doSweep ? "YES (-90 -> +90 deg)" : "NO (fixed front 0 deg)")")
print()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AVAudioEngine + player node
// ─────────────────────────────────────────────────────────────────────────────

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Instantiate AUSpatialMixer
//
// AVAudioUnit.instantiate is async (callback on arbitrary queue).
// We protect the result with a DispatchSemaphore: write in callback, read after wait().
// ─────────────────────────────────────────────────────────────────────────────

print("Instantiating AUSpatialMixer…")
var spatialDesc = AudioComponentDescription(
    componentType:         kAudioUnitType_Mixer,
    componentSubType:      kAudioUnitSubType_SpatialMixer,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags:        0,
    componentFlagsMask:    0)

let instantiateSema = DispatchSemaphore(value: 0)
AVAudioUnit.instantiate(with: spatialDesc, options: []) { unit, error in
    // Runs on an Audio Unit thread — write to nonisolated(unsafe) global,
    // then signal.  No concurrent read until after semaphore.wait() below.
    if let e = error {
        print("ERROR from AVAudioUnit.instantiate: \(e)")
    }
    gAVUnit = unit
    instantiateSema.signal()
}
instantiateSema.wait()

guard let spatialAVUnit = gAVUnit else {
    print("FATAL: AUSpatialMixer instantiation returned nil. Exiting.")
    exit(1)
}
print("  -> AUSpatialMixer instantiated OK")
engine.attach(spatialAVUnit)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Connect audio graph
//
//   player (mono 48 kHz)
//       -> spatialMixer  (applies binaural HRTF, head tracking)
//           -> mainMixerNode
//               -> outputNode (AirPods)
//
// Mono input on bus 0 is required for PointSource spatialization — the AU
// treats the single-channel signal as a point in 3-D space.
// For the spatialMixer -> mainMixer leg we pass format:nil so the engine
// queries the mixer's output format (binaural stereo at the device rate).
//
// Crash-avoidance (AVFAudio DidConnectToMixer null-deref)
// ------------------------------------------------------
// AVAudioEngine creates `mainMixerNode` and `outputNode` lazily.  If the very
// first connection wires an UPSTREAM leg (player -> spatialMixer) before any
// downstream path to a realized output mixer exists, AVFAudio's
// DidConnectToMixer / InformNodesAboutMixerConnection traversal walks downstream
// looking for the output mixer, finds nothing realized, and dereferences null.
//
// Two complementary measures make this robust:
//   (1) Force lazy realization of mainMixerNode + outputNode BEFORE any connect,
//       so the downstream chain (mainMixer -> outputNode) already exists.
//   (2) Connect DOWNSTREAM-FIRST: spatialMixer -> mainMixer before
//       player -> spatialMixer, so every node has a downstream path to the
//       output mixer at the moment it is wired.
// Also: compute nextAvailableInputBus into a local AFTER the mixer is realized,
// because evaluating it inline can itself realize the mixer mid-expression.
// ─────────────────────────────────────────────────────────────────────────────

let monoFmt   = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
let stereoFmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

// (1) Realize the output chain first.  Referencing these properties forces the
//     engine to create the nodes and the implicit mainMixer -> outputNode edge.
let mainMixer = engine.mainMixerNode
_ = engine.outputNode

// Compute the destination bus into a local now that the mixer is realized.
let mainMixerInputBus = mainMixer.nextAvailableInputBus

// (1b) Prepare the engine so the lazily-created nodes have their internal
//      implementation objects fully realized before we wire the AUSpatialMixer.
engine.prepare()

// (2) Downstream-first: spatialMixer -> mainMixer BEFORE player -> spatialMixer.
//     Pass an EXPLICIT stereo format for the spatial output leg.  With format:nil
//     the engine queries the freshly-instantiated AUSpatialMixer's output format,
//     which is uninitialised and yields a malformed connection record; the
//     subsequent player -> spatialMixer wiring then walks that record in
//     DidConnectToMixer and dereferences garbage.  An explicit binaural stereo
//     format gives the mixer a valid output bus to reason about.
engine.connect(spatialAVUnit, to: mainMixer,
               fromBus: 0, toBus: mainMixerInputBus,
               format: stereoFmt)
engine.connect(player, to: spatialAVUnit,
               fromBus: 0, toBus: 0,
               format: monoFmt)
print("Graph: player(mono48k) -> spatialMixer -> mainMixer -> outputNode")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Configure AUSpatialMixer properties
// ─────────────────────────────────────────────────────────────────────────────

let au: AudioUnit = spatialAVUnit.audioUnit
print()
print("─── Spatial Mixer Property Configuration ──────────────────────────────")

// Property set success flags — collected for SUMMARY
var ok_spatAlg    = false
var ok_srcMode    = false
var ok_outType    = false
var ok_headTrack  = false
var ok_hrtfMode   = false

// 1. SpatializationAlgorithm = UseOutputType (7)
//    Makes the AU pick the rendering algorithm based on kPropOutputType.
//    Scope: Input, element 0
var spatAlgVal = kSpatAlgUseOutputType
let s_spatAlg = AudioUnitSetProperty(au,
    kAudioUnitProperty_SpatializationAlgorithm,
    kAudioUnitScope_Input, 0,
    &spatAlgVal, UInt32(MemoryLayout<UInt32>.size))
ok_spatAlg = (s_spatAlg == noErr)
print("  set SpatializationAlgorithm=UseOutputType(7) [Input/0] -> \(fmtStatus(s_spatAlg))")
if let v = getPropU32(au: au, prop: kAudioUnitProperty_SpatializationAlgorithm,
                      scope: kAudioUnitScope_Input, element: 0) {
    print("  get SpatializationAlgorithm -> \(v)")
}

// 2. SourceMode = PointSource (2)
//    Tells the AU this is a directional point source, not ambient.
//    Scope: Input, element 0
ok_srcMode = setPropU32(au: au, prop: kPropSourceMode,
                        scope: kAudioUnitScope_Input, element: 0,
                        value: kSrcModePointSource,
                        label: "SourceMode=PointSource(2) [3005/Input/0]")

// 3. OutputType = Headphones (1)
//    Documented scope is Global; some builds may require Input.  Try both.
print("  trying OutputType=Headphones(1) on Global scope…")
var outTypeVal = kOutputTypeHeadphones
let s_outGlobal = AudioUnitSetProperty(au, kPropOutputType,
    kAudioUnitScope_Global, 0,
    &outTypeVal, UInt32(MemoryLayout<UInt32>.size))
print("    set OutputType/Global -> \(fmtStatus(s_outGlobal))")
if s_outGlobal != noErr {
    print("  Global failed — retrying OutputType=Headphones(1) on Input scope…")
    let s_outInput = AudioUnitSetProperty(au, kPropOutputType,
        kAudioUnitScope_Input, 0,
        &outTypeVal, UInt32(MemoryLayout<UInt32>.size))
    print("    set OutputType/Input  -> \(fmtStatus(s_outInput))")
    ok_outType = (s_outInput == noErr)
} else {
    ok_outType = true
}
// Read back from whichever scope has the value
if let v = getPropU32(au: au, prop: kPropOutputType,
                      scope: kAudioUnitScope_Global, element: 0) {
    print("  get OutputType/Global -> \(v)  (1=Headphones)")
} else if let v = getPropU32(au: au, prop: kPropOutputType,
                              scope: kAudioUnitScope_Input, element: 0) {
    print("  get OutputType/Input  -> \(v)  (1=Headphones)")
} else {
    print("  get OutputType -> unreadable from both Global and Input scopes")
}

// 4. EnableHeadTracking = 1  (macOS 12.3+)
//    Requires CMHeadphoneMotionManager entitlement at runtime; the property Set
//    itself should succeed regardless.
ok_headTrack = setPropU32(au: au, prop: kPropEnableHeadTracking,
                          scope: kAudioUnitScope_Global, element: 0,
                          value: 1,
                          label: "EnableHeadTracking=1 [3111/Global]")

// 5. PersonalizedHRTFMode = On (1)  (macOS 13+)
//    Instructs the AU to use the user's scanned ear profile if available.
//    Falls back to generic HRTF if the profile is absent or the entitlement
//    (spatial-audio.profile-access) is not granted.
ok_hrtfMode = setPropU32(au: au, prop: kPropPersonalizedHRTFMode,
                         scope: kAudioUnitScope_Global, element: 0,
                         value: kPersonalizedHRTFOn,
                         label: "PersonalizedHRTFMode=On(1) [3113/Global]")
print()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Spatial parameters
// ─────────────────────────────────────────────────────────────────────────────

print("─── Spatial Parameters ────────────────────────────────────────────────")

// Helper: set a float parameter and print the result.
// Takes `audioUnit` explicitly rather than capturing the top-level `au`
// constant — top-level declarations in Swift 6 are @MainActor-isolated, but
// global helper functions are nonisolated, so a capture would be a compile error.
func setParam(_ audioUnit: AudioUnit,
              _ id: AudioUnitParameterID,
              value: Float32,
              label: String) {
    let s = AudioUnitSetParameter(audioUnit, id, kAudioUnitScope_Input, 0,
                                  AudioUnitParameterValue(value), 0)
    print("  param \(label) = \(value) -> \(fmtStatus(s))")
}

// Fix source at azimuth 0° (dead front) so head-tracking test is meaningful:
// the sound is anchored in front of you; rotating your head should keep it there.
setParam(au, kParamAzimuth,   value:  0.0, label: "Azimuth   [0, deg +-180]")
setParam(au, kParamElevation, value:  0.0, label: "Elevation [1, deg +-90]")
setParam(au, kParamDistance,  value:  1.0, label: "Distance  [2, metres]")
setParam(au, kParamGain,      value:  0.0, label: "Gain      [3, dB]")
print()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Prepare source buffer
// ─────────────────────────────────────────────────────────────────────────────

let sourceBuffer: AVAudioPCMBuffer
if CommandLine.arguments.count > 1 {
    let filePath = CommandLine.arguments[1]
    print("Loading audio file: \(filePath)")
    if let loaded = loadAudioFileMono48k(path: filePath) {
        sourceBuffer = loaded
    } else {
        print("WARNING: falling back to generated white noise")
        sourceBuffer = generateWhiteNoise()
    }
} else {
    print("No file arg — generating 2 s mono 48 kHz white noise (amplitude 0.15)")
    sourceBuffer = generateWhiteNoise()
}
print()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Start engine and playback
// ─────────────────────────────────────────────────────────────────────────────

do {
    try engine.start()
    print("AVAudioEngine started")
} catch {
    print("FATAL: engine.start() failed: \(error)")
    exit(1)
}

// Loop the buffer indefinitely so we have audio throughout the polling window.
player.scheduleBuffer(sourceBuffer, at: nil, options: .loops, completionHandler: nil)
player.play()
print("Playback started (looping)")
print()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SIGINT handler
// ─────────────────────────────────────────────────────────────────────────────

// Suppress the default SIGINT action; handle it ourselves via DispatchSource
// so we can perform clean teardown.
signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSrc.setEventHandler {
    // Runs on main queue — safe to write gShouldStop.
    print("\n[SIGINT received — stopping]")
    gShouldStop = true
}
sigSrc.resume()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Listener instructions
// ─────────────────────────────────────────────────────────────────────────────

print("═══════════════════════════════════════════════════════════════════════")
print("LISTENER INSTRUCTIONS")
print("  Keep still    — noise should sound in FRONT, OUTSIDE your head")
print("                  (externalized, not inside-the-skull).")
print("  Rotate head   — sound should STAY anchored in front (head tracking).")
print("  Control Center > Spatial Audio — toggle for A/B comparison.")
print("  Ctrl-C to stop early.")
print("═══════════════════════════════════════════════════════════════════════")
print()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Polling loop  (property 3116, 1 Hz)
// ─────────────────────────────────────────────────────────────────────────────

var everEngaged = false
let sweepStep = Float(180.0) / Float(max(1, runSeconds))
var sweepAz: Float = -90.0

for t in 1...max(1, runSeconds) {
    // Spin the RunLoop for ~1 s so DispatchSources and AVAudio callbacks can fire.
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
    guard !gShouldStop else { break }

    // Poll property 3116 — read-only UInt32, Global scope
    var hrtfVal: UInt32 = 0
    var hrtfSz  = UInt32(MemoryLayout<UInt32>.size)
    let pollSt  = AudioUnitGetProperty(
        au, kPropAnyInputUsingPersonalizedHRTF,
        kAudioUnitScope_Global, 0,
        &hrtfVal, &hrtfSz)

    let engaged: Bool
    let tag: String
    if pollSt == noErr {
        engaged = (hrtfVal != 0)
        tag     = engaged ? "YES" : "NO"
    } else {
        engaged = false
        tag     = "ERROR(\(fmtStatus(pollSt)))"
    }
    if engaged { everEngaged = true }

    print("t=\(String(format: "%2d", t))s  personalizedHRTF=\(tag)")

    // Optional azimuth sweep
    if doSweep {
        let az = min(max(sweepAz, -180.0), 180.0)
        AudioUnitSetParameter(au, kParamAzimuth, kAudioUnitScope_Input, 0,
                              AudioUnitParameterValue(az), 0)
        if t == 1 || t % 5 == 0 {
            print("          azimuth swept to \(String(format: "%.1f", az)) deg")
        }
        sweepAz += sweepStep
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Teardown
// ─────────────────────────────────────────────────────────────────────────────

player.stop()
engine.stop()
sigSrc.cancel()
print()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Final read-backs
// ─────────────────────────────────────────────────────────────────────────────

// Try Global scope first for OutputType, fall back to Input
let finalOutType = getPropU32(au: au, prop: kPropOutputType,
                              scope: kAudioUnitScope_Global, element: 0)
              ?? getPropU32(au: au, prop: kPropOutputType,
                            scope: kAudioUnitScope_Input, element: 0)
let finalHeadTrack = getPropU32(au: au, prop: kPropEnableHeadTracking,
                                scope: kAudioUnitScope_Global, element: 0)
let finalHRTFMode  = getPropU32(au: au, prop: kPropPersonalizedHRTFMode,
                                scope: kAudioUnitScope_Global, element: 0)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Summary
// ─────────────────────────────────────────────────────────────────────────────

print("═══════════════════════════════════════════════════════════════════════")
print("SUMMARY")
print()
print("─── Property Set results ───────────────────────────────────────────────")
print("  SpatializationAlgorithm=UseOutputType(7) [Input/0]  : \(ok_spatAlg   ? "OK" : "FAILED")")
print("  SourceMode=PointSource(2)       [3005/Input/0]      : \(ok_srcMode   ? "OK" : "FAILED")")
print("  OutputType=Headphones(1)        [3100]              : \(ok_outType   ? "OK" : "FAILED")")
print("  EnableHeadTracking=1            [3111/Global]       : \(ok_headTrack ? "OK" : "FAILED")")
print("  PersonalizedHRTFMode=On(1)      [3113/Global]       : \(ok_hrtfMode  ? "OK" : "FAILED")")
print()
print("─── Final property read-backs ──────────────────────────────────────────")
let outTypeStr      = finalOutType.map { "\($0) (1=Headphones)" }     ?? "<unreadable>"
let headTrackStr    = finalHeadTrack.map { "\($0)" }                  ?? "<unreadable>"
let hrtfModeStr     = finalHRTFMode.map { "\($0) (0=Off 1=On 2=Auto)" } ?? "<unreadable>"
print("  OutputType         (3100) : \(outTypeStr)")
print("  EnableHeadTracking (3111) : \(headTrackStr)")
print("  PersonalizedHRTFMode(3113): \(hrtfModeStr)")
print()
print("─── Key signal ─────────────────────────────────────────────────────────")
print("  AnyInputUsingPersonalizedHRTF (3116) ever YES: \(everEngaged ? "YES" : "NO")")
print()
if everEngaged {
    print("VERDICT: personalized HRTF ENGAGED")
} else {
    print("VERDICT: personalized HRTF DID NOT engage")
    print("         Possible reasons:")
    print("           - No personalized Spatial Audio profile scanned in Settings")
    print("           - Missing com.apple.developer.coremotion.head-pose entitlement")
    print("           - Missing spatial-audio.profile-access entitlement (private)")
    print("           - Output device is not AirPods / supported headphone")
    print("           - Generic HRTF fallback — binaural rendering still active,")
    print("             just not personalized")
}
print()
print("─── Listener reminder ──────────────────────────────────────────────────")
print("  Keep still — noise should sound in front and OUTSIDE your head.")
print("  Rotate your head — it should stay anchored in front (head tracking).")
print("  Toggle Control Center > Spatial Audio for A/B comparison.")
print("═══════════════════════════════════════════════════════════════════════")
