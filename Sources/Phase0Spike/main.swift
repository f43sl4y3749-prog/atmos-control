// Sources/Phase0Spike/main.swift
//
// Phase 0 de-risk spike — AUSpatialMixer personalised + head-tracked binaural.
//
// Instantiates AUSpatialMixer, sets every relevant property (personalized HRTF,
// head tracking, output type), plays a test signal to the default output device,
// and polls property 3116 every second to report whether personalized HRTF
// actually engaged.
//
// Build:   swift build
// Run:     .build/debug/Phase0Spike [optional-audio-file.wav]
// Env:     SECONDS=N          override run duration (default 25 s)
//          SWEEP=1            sweep azimuth from -90° to +90° across the run
//          OUTPUT_TYPE=...    headphones (default) | builtin | external
//          HRTF_MODE=...      auto (default) | on | off
//          ALGO=...           useoutputtype (default) | hrtf | hrtfhq
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
let kSpatAlgHRTF:           UInt32 = 2   // kSpatializationAlgorithm_HRTF
let kSpatAlgHRTFHQ:         UInt32 = 6   // kSpatializationAlgorithm_HRTFHQ
let kSpatAlgUseOutputType:  UInt32 = 7   // kSpatializationAlgorithm_UseOutputType
let kSrcModePointSource:    UInt32 = 2   // kSpatialMixerSourceMode_PointSource
let kOutputTypeHeadphones:  UInt32 = 1   // kSpatialMixerOutputType_Headphones
let kOutputTypeBuiltIn:     UInt32 = 2   // kSpatialMixerOutputType_BuiltInSpeakers
let kOutputTypeExternal:    UInt32 = 3   // kSpatialMixerOutputType_ExternalSpeakers
let kPersonalizedHRTFOff:   UInt32 = 0   // kSpatialMixerPersonalizedHRTFMode_Off
let kPersonalizedHRTFOn:    UInt32 = 1   // kSpatialMixerPersonalizedHRTFMode_On
let kPersonalizedHRTFAuto:  UInt32 = 2   // kSpatialMixerPersonalizedHRTFMode_Auto

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

// OUTPUT_TYPE: which output device class the AU should render for.
let (cfgOutputType, cfgOutputTypeName): (UInt32, String) = {
    let raw = (ProcessInfo.processInfo.environment["OUTPUT_TYPE"] ?? "headphones")
        .lowercased().trimmingCharacters(in: .whitespaces)
    switch raw {
    case "headphones": return (kOutputTypeHeadphones, "Headphones")
    case "builtin":    return (kOutputTypeBuiltIn,    "BuiltInSpeakers")
    case "external":   return (kOutputTypeExternal,   "ExternalSpeakers")
    default:
        print("WARNING: Unrecognized OUTPUT_TYPE='\(raw)' — using 'headphones'")
        return (kOutputTypeHeadphones, "Headphones")
    }
}()

// HRTF_MODE: whether to request personalized, generic, or auto HRTF.
// Default is "auto" (graceful fallback: uses personal profile when available).
let (cfgHRTFMode, cfgHRTFModeName): (UInt32, String) = {
    let raw = (ProcessInfo.processInfo.environment["HRTF_MODE"] ?? "auto")
        .lowercased().trimmingCharacters(in: .whitespaces)
    switch raw {
    case "auto": return (kPersonalizedHRTFAuto, "Auto")
    case "on":   return (kPersonalizedHRTFOn,   "On")
    case "off":  return (kPersonalizedHRTFOff,  "Off")
    default:
        print("WARNING: Unrecognized HRTF_MODE='\(raw)' — using 'auto'")
        return (kPersonalizedHRTFAuto, "Auto")
    }
}()

// ALGO: spatialization algorithm override.
let (cfgAlgo, cfgAlgoName): (UInt32, String) = {
    let raw = (ProcessInfo.processInfo.environment["ALGO"] ?? "useoutputtype")
        .lowercased().trimmingCharacters(in: .whitespaces)
    switch raw {
    case "useoutputtype": return (kSpatAlgUseOutputType, "UseOutputType")
    case "hrtf":          return (kSpatAlgHRTF,          "HRTF")
    case "hrtfhq":        return (kSpatAlgHRTFHQ,        "HRTFHQ")
    default:
        print("WARNING: Unrecognized ALGO='\(raw)' — using 'useoutputtype'")
        return (kSpatAlgUseOutputType, "UseOutputType")
    }
}()

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
print("Config : OutputType=\(cfgOutputTypeName)(\(cfgOutputType))  HRTFMode=\(cfgHRTFModeName)(\(cfgHRTFMode))  Algo=\(cfgAlgoName)(\(cfgAlgo))")
print()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Raw AudioUnit render graph (no AVAudioEngine) — Approach D
//
// Mirrors the eventual daemon render path with raw AudioUnits, pulling audio via
// render callbacks instead of AVAudioEngine connections:
//
//   noise buffer --(input render CB)--> AUSpatialMixer --(output render CB /
//   AudioUnitRender)--> DefaultOutput unit --> default output device.
//
// AVAudioEngine.connect() null-derefs inside DidConnectToMixer when wiring into a
// freshly-instantiated AUSpatialMixer (the documented crash). The raw-AU graph
// avoids that AVFAudio code path entirely.
// ─────────────────────────────────────────────────────────────────────────────

/// Shared context handed to the C render callbacks via inRefCon.
/// Touched only on the single HAL render thread once rendering starts, so
/// @unchecked Sendable is safe here.
///
/// NOTE: samples are held as a RAW heap buffer, NOT a Swift `[Float]`. In Swift 6
/// main.swift top-level code is @MainActor by default, so an inner closure such
/// as the one `Array.withUnsafeBufferPointer` requires inherits @MainActor
/// isolation. Calling it from the real-time audio thread trips
/// `_swift_task_checkIsolatedSwift` / `dispatch_assert_queue` and aborts. Raw
/// pointer indexing inside the @convention(c) callback avoids any isolated
/// closure entirely.
final class RenderCtx: @unchecked Sendable {
    var samples: UnsafeMutablePointer<Float>? = nil  // looping mono source
    var count: Int = 0                               // sample count
    var pos: Int = 0                                 // read position (render thread)
    var spatialMixer: AudioUnit? = nil
}
let gRenderCtx = RenderCtx()

/// Input render callback: feeds the AUSpatialMixer's mono input bus 0 by copying
/// from the looping sample buffer. (kAudioUnitProperty_SetRenderCallback / Input)
let inputRenderProc: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    guard let ioData = ioData else { return noErr }
    let ctx = Unmanaged<RenderCtx>.fromOpaque(inRefCon).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    let n = Int(inNumberFrames)
    guard let samples = ctx.samples, ctx.count > 0 else {
        for b in 0..<abl.count {
            if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }
        }
        return noErr
    }
    let count = ctx.count
    for b in 0..<abl.count {
        guard let raw = abl[b].mData else { continue }
        let out = raw.assumingMemoryBound(to: Float.self)
        var p = ctx.pos
        for i in 0..<n {
            out[i] = samples[p]
            p += 1
            if p >= count { p = 0 }
        }
    }
    ctx.pos = (ctx.pos + n) % count
    return noErr
}

/// Output unit render callback: pulls a stereo buffer from the AUSpatialMixer.
let outputRenderProc: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, ioData in
    guard let ioData = ioData else { return noErr }
    let ctx = Unmanaged<RenderCtx>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let mixer = ctx.spatialMixer else {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for b in 0..<abl.count {
            if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }
        }
        return noErr
    }
    return AudioUnitRender(mixer, ioActionFlags, inTimeStamp, 0, inNumberFrames, ioData)
}

/// Builds a deinterleaved float32 ASBD.
func makeFloatASBD(channels: UInt32, sampleRate: Double = 48_000) -> AudioStreamBasicDescription {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate       = sampleRate
    asbd.mFormatID         = kAudioFormatLinearPCM
    asbd.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
    asbd.mFramesPerPacket  = 1
    asbd.mBytesPerFrame    = 4
    asbd.mBytesPerPacket   = 4
    asbd.mBitsPerChannel   = 32
    asbd.mChannelsPerFrame = channels
    return asbd
}

print("Instantiating AUSpatialMixer (raw AudioUnit)…")
var spatialDesc = AudioComponentDescription(
    componentType:         kAudioUnitType_Mixer,
    componentSubType:      kAudioUnitSubType_SpatialMixer,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags:        0,
    componentFlagsMask:    0)

guard let spatialComp = AudioComponentFindNext(nil, &spatialDesc) else {
    print("FATAL: AUSpatialMixer component not found. Exiting.")
    exit(1)
}
var spatialMixerOpt: AudioUnit? = nil
let sInst = AudioComponentInstanceNew(spatialComp, &spatialMixerOpt)
guard sInst == noErr, let spatialMixer = spatialMixerOpt else {
    print("FATAL: AudioComponentInstanceNew(spatial) -> \(fmtStatus(sInst)). Exiting.")
    exit(1)
}
print("  -> AUSpatialMixer instantiated OK")

print("Instantiating DefaultOutput unit (raw AudioUnit)…")
var outputDesc = AudioComponentDescription(
    componentType:         kAudioUnitType_Output,
    componentSubType:      kAudioUnitSubType_DefaultOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags:        0,
    componentFlagsMask:    0)
guard let outputComp = AudioComponentFindNext(nil, &outputDesc) else {
    print("FATAL: DefaultOutput component not found. Exiting.")
    exit(1)
}
var outputUnitOpt: AudioUnit? = nil
let oInst = AudioComponentInstanceNew(outputComp, &outputUnitOpt)
guard oInst == noErr, let outputUnit = outputUnitOpt else {
    print("FATAL: AudioComponentInstanceNew(output) -> \(fmtStatus(oInst)). Exiting.")
    exit(1)
}
print("  -> DefaultOutput unit instantiated OK")

gRenderCtx.spatialMixer = spatialMixer

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Stream formats + render callbacks (deinterleaved float32 @ 48 kHz)
//
//   spatial mixer  Input/0  : mono   (point-source input — required for
//                                      PointSource spatialization)
//   spatial mixer  Output/0 : stereo (binaural)
//   output unit    Input/0  : stereo (pulled via AudioUnitRender on the mixer)
//
// Audio is pulled by two render callbacks: the output unit's input callback
// renders the spatial mixer, and the spatial mixer's input callback copies from
// the looping source buffer. No AVAudioEngine connect() is involved, so the
// DidConnectToMixer null-deref cannot occur.
// ─────────────────────────────────────────────────────────────────────────────

var monoASBD   = makeFloatASBD(channels: 1)
var stereoASBD = makeFloatASBD(channels: 2)
let asbdSize   = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

let fIn = AudioUnitSetProperty(spatialMixer, kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Input, 0, &monoASBD, asbdSize)
print("Format: spatialMixer Input/0  = mono48k   -> \(fmtStatus(fIn))")

let fOut = AudioUnitSetProperty(spatialMixer, kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Output, 0, &stereoASBD, asbdSize)
print("Format: spatialMixer Output/0 = stereo48k -> \(fmtStatus(fOut))")

let fOutIn = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Input, 0, &stereoASBD, asbdSize)
print("Format: outputUnit  Input/0   = stereo48k -> \(fmtStatus(fOutIn))")

// Wire render callbacks. ctx.samples is empty until the source buffer is loaded
// (the callbacks emit silence until then), so it is safe to set them now.
let ctxPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(gRenderCtx).toOpaque())
let cbSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)

var inputCB = AURenderCallbackStruct(inputProc: inputRenderProc, inputProcRefCon: ctxPtr)
let scbIn = AudioUnitSetProperty(spatialMixer, kAudioUnitProperty_SetRenderCallback,
    kAudioUnitScope_Input, 0, &inputCB, cbSize)
print("RenderCB: spatialMixer Input/0 -> \(fmtStatus(scbIn))")

var outputCB = AURenderCallbackStruct(inputProc: outputRenderProc, inputProcRefCon: ctxPtr)
let scbOut = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback,
    kAudioUnitScope_Input, 0, &outputCB, cbSize)
print("RenderCB: outputUnit  Input/0 -> \(fmtStatus(scbOut))")
print("Graph: noise -> [renderCB] -> spatialMixer -> [renderCB] -> outputUnit -> device")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Configure AUSpatialMixer properties
// ─────────────────────────────────────────────────────────────────────────────

let au: AudioUnit = spatialMixer
print()
print("─── Spatial Mixer Property Configuration ──────────────────────────────")

// Property set success flags — collected for SUMMARY
var ok_spatAlg    = false
var ok_srcMode    = false
var ok_outType    = false
var ok_headTrack  = false
var ok_hrtfMode   = false

// 1. SpatializationAlgorithm  (Input/0)
//    Makes the AU pick the rendering algorithm based on kPropOutputType when
//    UseOutputType (7) is selected; can also be forced to HRTF (2) or HRTFHQ (6).
var spatAlgVal = cfgAlgo
let s_spatAlg = AudioUnitSetProperty(au,
    kAudioUnitProperty_SpatializationAlgorithm,
    kAudioUnitScope_Input, 0,
    &spatAlgVal, UInt32(MemoryLayout<UInt32>.size))
ok_spatAlg = (s_spatAlg == noErr)
print("  set SpatializationAlgorithm=\(cfgAlgoName)(\(cfgAlgo)) [Input/0] -> \(fmtStatus(s_spatAlg))")
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

// 3. OutputType  (Global scope preferred; some builds require Input)
print("  trying OutputType=\(cfgOutputTypeName)(\(cfgOutputType)) on Global scope…")
var outTypeVal = cfgOutputType
let s_outGlobal = AudioUnitSetProperty(au, kPropOutputType,
    kAudioUnitScope_Global, 0,
    &outTypeVal, UInt32(MemoryLayout<UInt32>.size))
print("    set OutputType/Global -> \(fmtStatus(s_outGlobal))")
if s_outGlobal != noErr {
    print("  Global failed — retrying OutputType=\(cfgOutputTypeName)(\(cfgOutputType)) on Input scope…")
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
    print("  get OutputType/Global -> \(v)  (1=Headphones 2=BuiltInSpeakers 3=ExternalSpeakers)")
} else if let v = getPropU32(au: au, prop: kPropOutputType,
                              scope: kAudioUnitScope_Input, element: 0) {
    print("  get OutputType/Input  -> \(v)  (1=Headphones 2=BuiltInSpeakers 3=ExternalSpeakers)")
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

// 5. PersonalizedHRTFMode  (macOS 13+, Global scope)
//    Off(0): always generic HRTF; On(1): require personal profile; Auto(2): use
//    profile when available, otherwise fall back to generic (product default).
ok_hrtfMode = setPropU32(au: au, prop: kPropPersonalizedHRTFMode,
                         scope: kAudioUnitScope_Global, element: 0,
                         value: cfgHRTFMode,
                         label: "PersonalizedHRTFMode=\(cfgHRTFModeName)(\(cfgHRTFMode)) [3113/Global]")
print()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Initialize both AudioUnits
//
// Formats, render callbacks and all spatial properties are now set, so the units
// can allocate their render resources. Parameters are set afterwards.
// ─────────────────────────────────────────────────────────────────────────────

let initSp = AudioUnitInitialize(spatialMixer)
print("AudioUnitInitialize(spatialMixer) -> \(fmtStatus(initSp))")
let initOut = AudioUnitInitialize(outputUnit)
print("AudioUnitInitialize(outputUnit)   -> \(fmtStatus(initOut))")
if initSp != noErr || initOut != noErr {
    print("FATAL: AudioUnit initialization failed. Exiting.")
    exit(1)
}
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

// Copy the mono float samples into a raw heap buffer the input callback loops
// over. (floatChannelData is deinterleaved float32 — exactly our mono ASBD.)
// Raw buffer (not Array) so the real-time callback touches no isolated closures.
let sourceFrames = Int(sourceBuffer.frameLength)
if sourceFrames > 0, let ch = sourceBuffer.floatChannelData?[0] {
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: sourceFrames)
    buf.update(from: ch, count: sourceFrames)
    gRenderCtx.samples = buf
    gRenderCtx.count   = sourceFrames
}
print("Source loaded into render context: \(gRenderCtx.count) frames (looping)")
print()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Start rendering
// ─────────────────────────────────────────────────────────────────────────────

let startSt = AudioOutputUnitStart(outputUnit)
if startSt == noErr {
    print("AudioOutputUnitStart(outputUnit) -> OK (HAL render thread running)")
} else {
    print("FATAL: AudioOutputUnitStart -> \(fmtStatus(startSt))")
    exit(1)
}
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

AudioOutputUnitStop(outputUnit)
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
print("  SpatializationAlgorithm=\(cfgAlgoName)(\(cfgAlgo)) [Input/0]  : \(ok_spatAlg   ? "OK" : "FAILED")")
print("  SourceMode=PointSource(2)       [3005/Input/0]      : \(ok_srcMode   ? "OK" : "FAILED")")
print("  OutputType=\(cfgOutputTypeName)(\(cfgOutputType))        [3100]              : \(ok_outType   ? "OK" : "FAILED")")
print("  EnableHeadTracking=1            [3111/Global]       : \(ok_headTrack ? "OK" : "FAILED")")
print("  PersonalizedHRTFMode=\(cfgHRTFModeName)(\(cfgHRTFMode))      [3113/Global]       : \(ok_hrtfMode  ? "OK" : "FAILED")")
print()
print("─── Final property read-backs ──────────────────────────────────────────")
let outTypeStr   = finalOutType.map { "\($0) (1=Headphones 2=BuiltInSpeakers 3=ExternalSpeakers)" } ?? "<unreadable>"
let headTrackStr = finalHeadTrack.map { "\($0)" }                              ?? "<unreadable>"
let hrtfModeStr  = finalHRTFMode.map { "\($0) (0=Off 1=On 2=Auto)" }          ?? "<unreadable>"
print("  OutputType         (3100) : \(outTypeStr)")
print("  EnableHeadTracking (3111) : \(headTrackStr)")
print("  PersonalizedHRTFMode(3113): \(hrtfModeStr)")
print()
print("─── Key signal ─────────────────────────────────────────────────────────")
print("  AnyInputUsingPersonalizedHRTF (3116) ever YES: \(everEngaged ? "YES" : "NO")")
print()
if cfgOutputType != kOutputTypeHeadphones {
    // Speaker-virtualization path: 3116 is always NO — that is correct behaviour.
    print("VERDICT: speaker-virtualization path (OutputType=\(cfgOutputTypeName)).")
    print("         Personalized HRTF (3116) is headphones-only; reading NO here is expected.")
} else {
    // Headphones path — interpret 3116 relative to the requested HRTF mode.
    if cfgHRTFMode == kPersonalizedHRTFOff {
        print("VERDICT: GENERIC HRTF (personalization forced OFF) — binaural rendering active")
        print("         by design. 3116=NO is correct.")
    } else if everEngaged {
        print("VERDICT: PERSONALIZED HRTF ENGAGED (premium tier).")
    } else {
        print("VERDICT: GENERIC HRTF FALLBACK — personalization requested (\(cfgHRTFModeName))")
        print("         but not engaged. Binaural still active (core tier works).")
        print("         Likely cause: not AirPods, OR no scanned profile, OR missing")
        print("         spatial-audio.profile-access entitlement.")
    }
}
print()
print("─── Listener reminder ──────────────────────────────────────────────────")
print("  Keep still — noise should sound in front and OUTSIDE your head.")
print("  Rotate your head — it should stay anchored in front (head tracking).")
print("  Toggle Control Center > Spatial Audio for A/B comparison.")
print("═══════════════════════════════════════════════════════════════════════")

// Dispose AudioUnits (after the final property read-backs above).
AudioUnitUninitialize(outputUnit)
AudioUnitUninitialize(spatialMixer)
AudioComponentInstanceDispose(outputUnit)
AudioComponentInstanceDispose(spatialMixer)
