// AtmosDaemon — CAPlayThrough passthrough: atmos-control loopback → real output
// Swift 6, macOS 15+, CoreAudio HAL only (no AVAudioEngine).
//
// Two HAL AudioUnits bridged by a lock-free SPSC ring buffer:
//   Capture unit  (input enabled,  output disabled) ← atmos-control device
//   Playback unit (output enabled, input  disabled) → real output device
//
// CRITICAL: @convention(c) callbacks must touch ONLY raw pointers and the Ctx
// object passed via inRefCon. No Swift Array closures, no main-actor globals.

import CoreAudio
import AudioToolbox
import Darwin          // for signal(), usleep, fabsf
import Synchronization // Atomic<UInt64> — release/acquire ordering on the SPSC indices

// ---------------------------------------------------------------------------
// MARK: - OSStatus helpers
// ---------------------------------------------------------------------------

@discardableResult
func check(_ status: OSStatus, _ label: String) -> Bool {
    if status == noErr {
        print("  OK  \(label)")
        return true
    } else {
        print("  ERR \(label): \(status) (0x\(String(status, radix: 16)))")
        return false
    }
}

// ---------------------------------------------------------------------------
// MARK: - Phase 2 spatializer — AUSpatialMixer property IDs, enums, env config
// ---------------------------------------------------------------------------
// Numeric property IDs (not all exported as Swift symbols on CLT-only installs).
// Values from <AudioToolbox/AudioUnitProperties.h>, macOS 26.5 SDK. These mirror
// Phase 0's PROVEN config so the daemon-context gate isolates only the process /
// virtual-default-output variable.

let kPropSourceMode:                    AudioUnitPropertyID = 3005  // SpatialMixerSourceMode
let kPropOutputType:                    AudioUnitPropertyID = 3100  // SpatialMixerOutputType
let kPropEnableHeadTracking:            AudioUnitPropertyID = 3111  // SpatialMixerEnableHeadTracking
let kPropPersonalizedHRTFMode:          AudioUnitPropertyID = 3113  // SpatialMixerPersonalizedHRTFMode
let kPropAnyInputUsingPersonalizedHRTF: AudioUnitPropertyID = 3116  // read-only UInt32 0/1 (primary signal)

let kSpatAlgHRTF:          UInt32 = 2
let kSpatAlgHRTFHQ:        UInt32 = 6
let kSpatAlgUseOutputType: UInt32 = 7
let kSrcModePointSource:   UInt32 = 2
let kSrcModeAmbienceBed:   UInt32 = 3
let kOutputTypeHeadphones: UInt32 = 1
let kOutputTypeBuiltIn:    UInt32 = 2
let kOutputTypeExternal:   UInt32 = 3
let kPersonalizedHRTFOff:  UInt32 = 0
let kPersonalizedHRTFOn:   UInt32 = 1
let kPersonalizedHRTFAuto: UInt32 = 2

let kParamAzimuth:   AudioUnitParameterID = 0   // ±180°
let kParamElevation: AudioUnitParameterID = 1   // ±90°
let kParamDistance:  AudioUnitParameterID = 2   // metres
let kParamGain:      AudioUnitParameterID = 3   // dB

// --- Env config (parsed once at load) ---
// SPATIALIZE: gate. Default OFF keeps the proven Phase 1 passthrough working.
let cfgSpatialize: Bool = {
    let raw = (ProcessInfo.processInfo.environment["SPATIALIZE"] ?? "").lowercased()
    return raw == "1" || raw == "yes" || raw == "true" || raw == "on"
}()
let (cfgOutputType, cfgOutputTypeName): (UInt32, String) = {
    switch (ProcessInfo.processInfo.environment["OUTPUT_TYPE"] ?? "headphones").lowercased() {
    case "builtin":  return (kOutputTypeBuiltIn,  "BuiltInSpeakers")
    case "external": return (kOutputTypeExternal, "ExternalSpeakers")
    default:         return (kOutputTypeHeadphones, "Headphones")
    }
}()
// HRTF_MODE default Auto (product default). Run the strict gate test with HRTF_MODE=on.
let (cfgHRTFMode, cfgHRTFModeName): (UInt32, String) = {
    switch (ProcessInfo.processInfo.environment["HRTF_MODE"] ?? "auto").lowercased() {
    case "on":  return (kPersonalizedHRTFOn,  "On")
    case "off": return (kPersonalizedHRTFOff, "Off")
    default:    return (kPersonalizedHRTFAuto, "Auto")
    }
}()
let (cfgAlgo, cfgAlgoName): (UInt32, String) = {
    switch (ProcessInfo.processInfo.environment["ALGO"] ?? "useoutputtype").lowercased() {
    case "hrtf":   return (kSpatAlgHRTF,   "HRTF")
    case "hrtfhq": return (kSpatAlgHRTFHQ, "HRTFHQ")
    default:       return (kSpatAlgUseOutputType, "UseOutputType")
    }
}()
// SRC_MODE: how to feed captured stereo into the mixer.
//   bed   (default) = stereo AmbienceBed → L/R rendered as externalized far-field
//                     virtual speakers (best for stereo system audio).
//   point           = downmix to mono PointSource @ az 0 (Phase-0 gate config;
//                     dead-front mono externalizes poorly — A/B only).
let cfgBed: Bool = {
    (ProcessInfo.processInfo.environment["SRC_MODE"] ?? "bed").lowercased() != "point"
}()
let cfgSrcModeName = cfgBed ? "AmbienceBed(stereo)" : "PointSource(mono)"
// HEAD_TRACK default 1. Set 0 to A/B whether head tracking is OURS (mixer) vs the OS's.
let cfgHeadTrack: UInt32 = {
    let raw = (ProcessInfo.processInfo.environment["HEAD_TRACK"] ?? "1").lowercased()
    return (raw == "0" || raw == "off" || raw == "no") ? 0 : 1
}()

// ---------------------------------------------------------------------------
// MARK: - Lock-free SPSC ring buffer
// ---------------------------------------------------------------------------

/// 32 768-frame stereo (2-channel) ring.  Producer writes ch0 then ch1 data
/// for N frames; consumer reads them in the same layout.
/// Indices are plain UInt64; wrap-around arithmetic keeps them monotonically
/// increasing so fill = writeIdx − readIdx is always correct.
let kRingFrames: UInt64 = 32768       // must be power-of-two
let kRingMask:   UInt64 = kRingFrames - 1
let kRingChannels = 2

final class RingBuffer {
    let buf0: UnsafeMutablePointer<Float>   // channel 0 samples
    let buf1: UnsafeMutablePointer<Float>   // channel 1 samples
    // SPSC indices with EXPLICIT acquire/release ordering. arm64 is weakly
    // ordered: a plain store of the index can become visible to the consumer
    // core before the buffer writes that precede it, yielding torn/stale frames.
    // The producer release-stores writeIdx after the data writes; the consumer
    // acquire-loads it, so observing a bumped writeIdx guarantees the samples are
    // visible. (Monotonic UInt64 — wrap arithmetic keeps fill = write − read valid.)
    let writeIdx = Atomic<UInt64>(0)
    let readIdx  = Atomic<UInt64>(0)

    init() {
        buf0 = .allocate(capacity: Int(kRingFrames))
        buf1 = .allocate(capacity: Int(kRingFrames))
        buf0.initialize(repeating: 0, count: Int(kRingFrames))
        buf1.initialize(repeating: 0, count: Int(kRingFrames))
    }

    deinit {
        buf0.deallocate()
        buf1.deallocate()
    }

    /// Frames available to read. (Called on the main/diag thread.)
    @inline(__always)
    func fill() -> UInt64 {
        return writeIdx.load(ordering: .acquiring) &- readIdx.load(ordering: .acquiring)
    }

    /// Write up to `frameCount` frames from two planar float pointers.
    /// Returns frames actually written (may be less if ring is full).
    /// RT-safe: raw-pointer while-loops, no Swift runtime calls, no allocation.
    @inline(__always) @discardableResult
    func write(ch0 src0: UnsafePointer<Float>,
               ch1 src1: UnsafePointer<Float>,
               frameCount: UInt32) -> UInt32 {
        let wi = writeIdx.load(ordering: .relaxed)      // producer owns writeIdx
        let ri = readIdx.load(ordering: .acquiring)     // observe consumer progress
        let available = kRingFrames &- (wi &- ri)       // free slots
        let want = UInt64(frameCount)
        let toWrite = want < available ? want : available
        if toWrite == 0 { return 0 }
        var i: UInt64 = 0
        while i < toWrite {
            let slot = Int((wi &+ i) & kRingMask)
            let si = Int(i)
            buf0[slot] = src0[si]
            buf1[slot] = src1[si]
            i &+= 1
        }
        // Release-store: publish the data writes above before the index bump.
        writeIdx.store(wi &+ toWrite, ordering: .releasing)
        return UInt32(toWrite)
    }

    /// Read up to `frameCount` frames into two planar float pointers.
    /// Fills with zeros and returns 0 frames on underrun.
    /// RT-safe: raw-pointer while-loops, no Swift runtime calls, no allocation.
    @inline(__always) @discardableResult
    func read(ch0 dst0: UnsafeMutablePointer<Float>,
              ch1 dst1: UnsafeMutablePointer<Float>,
              frameCount: UInt32) -> UInt32 {
        let ri = readIdx.load(ordering: .relaxed)       // consumer owns readIdx
        let wi = writeIdx.load(ordering: .acquiring)    // observe producer's data
        let available = wi &- ri
        let want = UInt64(frameCount)
        let toRead = want < available ? want : available
        if toRead == 0 {
            // Underrun — silence
            dst0.initialize(repeating: 0, count: Int(frameCount))
            dst1.initialize(repeating: 0, count: Int(frameCount))
            return 0
        }
        var i: UInt64 = 0
        while i < toRead {
            let slot = Int((ri &+ i) & kRingMask)
            let di = Int(i)
            dst0[di] = buf0[slot]
            dst1[di] = buf1[slot]
            i &+= 1
        }
        // Zero any remainder
        if toRead < want {
            let rem = Int(frameCount) - Int(toRead)
            (dst0 + Int(toRead)).initialize(repeating: 0, count: rem)
            (dst1 + Int(toRead)).initialize(repeating: 0, count: rem)
        }
        readIdx.store(ri &+ toRead, ordering: .releasing)
        return UInt32(toRead)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Shared context (passed as inRefCon to both callbacks)
// ---------------------------------------------------------------------------

final class Ctx: @unchecked Sendable {
    let ring = RingBuffer()
    var captureUnit:  AudioUnit? = nil
    var playbackUnit: AudioUnit? = nil
    // Diagnostics counters — SPSC: capture thread writes captured, playback writes played
    var totalCaptured: UInt64 = 0
    var totalPlayed:   UInt64 = 0
    // Scratch AudioBufferList for capture render — allocated once, reused
    var captureABL: UnsafeMutableAudioBufferListPointer? = nil
    var captureBufSize: UInt32 = 0   // frames allocated in captureABL
    // Peak meter: max |sample| seen by the capture callback since last read.
    // Written on the RT capture thread, read+reset on the main thread (approximate
    // is fine — aligned 32-bit float access is atomic on arm64).
    var capturePeak: Float = 0

    // Phase 2 spatializer — only populated/used when cfgSpatialize is true.
    // spatialize is set ONCE before the units start, then only read on RT threads.
    var spatialMixer:    AudioUnit? = nil
    var spatialize:      Bool = false
    var spatialBed:      Bool = false   // true = stereo AmbienceBed; false = mono PointSource
    var dmL:             UnsafeMutablePointer<Float>? = nil   // stereo→mono downmix scratch (L)
    var dmR:             UnsafeMutablePointer<Float>? = nil   //                            (R)
    var spatialMaxFrames: UInt32 = 0
}

// ---------------------------------------------------------------------------
// MARK: - Audio format helper
// ---------------------------------------------------------------------------

func stereoFloat32Format(sampleRate: Float64 = 48000) -> AudioStreamBasicDescription {
    var fmt = AudioStreamBasicDescription()
    fmt.mSampleRate       = sampleRate
    fmt.mFormatID         = kAudioFormatLinearPCM
    fmt.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
    fmt.mBitsPerChannel   = 32
    fmt.mChannelsPerFrame = 2
    fmt.mFramesPerPacket  = 1
    fmt.mBytesPerFrame    = 4        // sizeof(Float32)
    fmt.mBytesPerPacket   = 4
    return fmt
}

// ---------------------------------------------------------------------------
// MARK: - Device enumeration
// ---------------------------------------------------------------------------

func allDeviceIDs() -> [AudioDeviceID] {
    var propAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize)
    guard status == noErr, dataSize > 0 else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &propAddr,
        0, nil, &dataSize, &ids)
    guard status == noErr else { return [] }
    return ids
}

func deviceUID(_ id: AudioDeviceID) -> String {
    var propAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain)
    var cfStr: Unmanaged<CFString>? = nil
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    let status = AudioObjectGetPropertyData(id, &propAddr, 0, nil, &dataSize,
                                            &cfStr)
    guard status == noErr, let s = cfStr else { return "" }
    return s.takeRetainedValue() as String
}

func deviceName(_ id: AudioDeviceID) -> String {
    var propAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain)
    var cfStr: Unmanaged<CFString>? = nil
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    let status = AudioObjectGetPropertyData(id, &propAddr, 0, nil, &dataSize,
                                            &cfStr)
    guard status == noErr, let s = cfStr else { return "" }
    return s.takeRetainedValue() as String
}

/// True if the device has at least one channel in the given scope.
func deviceHasChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    var propAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope:    scope,
        mElement:  kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(id, &propAddr, 0, nil, &dataSize)
    guard status == noErr, dataSize > 0 else { return false }
    let bufSize = Int(dataSize)
    let rawBuf = UnsafeMutableRawPointer.allocate(byteCount: bufSize,
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { rawBuf.deallocate() }
    var sz = dataSize
    let s2 = AudioObjectGetPropertyData(id, &propAddr, 0, nil, &sz, rawBuf)
    guard s2 == noErr else { return false }
    let abl = rawBuf.bindMemory(to: AudioBufferList.self, capacity: 1)
    return abl.pointee.mNumberBuffers > 0
}

func findAtmosControlDevice() -> AudioDeviceID? {
    for id in allDeviceIDs() {
        let uid = deviceUID(id)
        if uid == "atmos-control:loopback:0" { return id }
    }
    // Fallback: name substring
    for id in allDeviceIDs() {
        if deviceName(id).lowercased().contains("atmos-control") { return id }
    }
    return nil
}

func findRealOutputDevice(atmosID: AudioDeviceID) -> AudioDeviceID? {
    let envName = ProcessInfo.processInfo.environment["OUTPUT_DEVICE"]?.lowercased()
    for id in allDeviceIDs() {
        guard id != atmosID else { continue }
        // Must have output channels
        guard deviceHasChannels(id, scope: kAudioObjectPropertyScopeOutput) else { continue }
        let name = deviceName(id)
        if let env = envName {
            if name.lowercased().contains(env) { return id }
        } else {
            if name.lowercased().contains("macbook air speakers") { return id }
        }
    }
    // Last resort: system default output
    var propAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain)
    var defaultID: AudioDeviceID = kAudioDeviceUnknown
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &propAddr, 0, nil, &sz, &defaultID)
    if defaultID != kAudioDeviceUnknown && defaultID != atmosID { return defaultID }
    return nil
}

// ---------------------------------------------------------------------------
// MARK: - Allocate capture ABL
// ---------------------------------------------------------------------------

func makeCaptureABL(maxFrames: UInt32) -> UnsafeMutableAudioBufferListPointer {
    // 2 non-interleaved buffers of Float32
    let abl = AudioBufferList.allocate(maximumBuffers: kRingChannels)
    for ch in 0..<kRingChannels {
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: Int(maxFrames) * MemoryLayout<Float>.size,
            alignment: MemoryLayout<Float>.alignment)
        data.initializeMemory(as: Float.self, repeating: 0,
                              count: Int(maxFrames))
        abl[ch] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: maxFrames * 4,
            mData: data)
    }
    return abl
}

// ---------------------------------------------------------------------------
// MARK: - Input callback (capture → ring)
// ---------------------------------------------------------------------------

let captureInputCallback: AURenderCallback = { (
    inRefCon,
    ioActionFlags,
    inTimeStamp,
    inBusNumber,
    inNumberFrames,
    _             // ioData — nil for input callbacks
) -> OSStatus in
    let ctx = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = ctx.captureUnit,
          let abl  = ctx.captureABL else { return noErr }

    // Reset byte sizes (HAL may shrink the frame count)
    let n = inNumberFrames
    abl[0].mDataByteSize = n * 4
    abl[1].mDataByteSize = n * 4

    // Pull audio from capture unit
    let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp,
                                 inBusNumber, n, abl.unsafeMutablePointer)
    if status != noErr { return status }

    // Write into ring; count only frames actually accepted (ring-full drops the rest).
    let src0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
    let src1 = abl[1].mData!.assumingMemoryBound(to: Float.self)
    let written = ctx.ring.write(ch0: src0, ch1: src1, frameCount: n)
    ctx.totalCaptured &+= UInt64(written)

    // Peak meter over this block (raw-pointer loop + fabsf — no Swift runtime calls on RT thread)
    var pk: Float = 0
    var i = 0
    let cnt = Int(n)
    while i < cnt {
        let a0 = fabsf(src0[i]); if a0 > pk { pk = a0 }
        let a1 = fabsf(src1[i]); if a1 > pk { pk = a1 }
        i &+= 1
    }
    if pk > ctx.capturePeak { ctx.capturePeak = pk }

    return noErr
}

// ---------------------------------------------------------------------------
// MARK: - Spatial mixer input callback (ring → downmix mono → AUSpatialMixer in)
// ---------------------------------------------------------------------------
// Runs synchronously on the playback HAL thread inside AudioUnitRender(spatialMixer)
// (driven by playbackRenderCallback). It is the SOLE ring consumer in spatialize
// mode, so the SPSC invariant holds. Raw pointers only — no Array closures / no
// main-actor globals on the RT thread.

// nonisolated(unsafe): referenced from the nonisolated makeSpatialMixer() factory.
// The C function pointer is invoked only on the playback HAL thread.
nonisolated(unsafe) let spatialInputCallback: AURenderCallback = { (
    inRefCon,
    _,           // ioActionFlags
    _,           // inTimeStamp
    _,           // inBusNumber
    inNumberFrames,
    ioData
) -> OSStatus in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    let n   = inNumberFrames

    let nbuf = abl.count   // read once (count.getter is a call): bed → 2, point → 1

    // Safety: oversized slice (must never happen — mixer MaxFramesPerSlice == spatialMaxFrames).
    guard n <= ctx.spatialMaxFrames else {
        var b = 0
        while b < nbuf {
            if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }
            b &+= 1
        }
        return noErr
    }

    if ctx.spatialBed {
        // STEREO AmbienceBed: copy ring L/R straight into the two input buffers
        // (no downmix — preserves the stereo image so L/R render as externalized
        // far-field virtual speakers). zero-fills on underrun.
        if nbuf >= 2, let p0 = abl[0].mData, let p1 = abl[1].mData {
            ctx.ring.read(ch0: p0.assumingMemoryBound(to: Float.self),
                          ch1: p1.assumingMemoryBound(to: Float.self),
                          frameCount: n)
            abl[0].mDataByteSize = n * 4
            abl[1].mDataByteSize = n * 4
        }
        return noErr
    }

    // MONO PointSource: downmix L+R → mono into the single input buffer.
    guard let dmL = ctx.dmL, let dmR = ctx.dmR else {
        var b = 0
        while b < nbuf {
            if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }
            b &+= 1
        }
        return noErr
    }
    ctx.ring.read(ch0: dmL, ch1: dmR, frameCount: n)
    // Raw-pointer while-loops only (no for-in / IndexingIterator on the RT thread).
    let cnt = Int(n)
    var b = 0
    while b < nbuf {
        if let raw = abl[b].mData {
            let out = raw.assumingMemoryBound(to: Float.self)
            var i = 0
            while i < cnt {
                out[i] = 0.5 * (dmL[i] + dmR[i])
                i &+= 1
            }
            abl[b].mDataByteSize = n * 4
        }
        b &+= 1
    }
    return noErr
}

// ---------------------------------------------------------------------------
// MARK: - Render callback (ring → playback, or ring → spatial mixer → playback)
// ---------------------------------------------------------------------------

let playbackRenderCallback: AURenderCallback = { (
    inRefCon,
    ioActionFlags,
    inTimeStamp,
    _,           // inBusNumber
    inNumberFrames,
    ioData
) -> OSStatus in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    let n = inNumberFrames

    // Spatialize path: render the AUSpatialMixer directly into the playback unit's
    // stereo input buffers. Mixer Output/0 == playback Input/0 == stereo48k, so we
    // render straight into ioData (exactly Phase 0's proven output render shape).
    // The mixer's input callback (spatialInputCallback) reads the ring + downmixes.
    if ctx.spatialize, let mixer = ctx.spatialMixer {
        let st = AudioUnitRender(mixer, ioActionFlags, inTimeStamp, 0, n, ioData)
        ctx.totalPlayed &+= UInt64(n)
        return st
    }

    // Passthrough path (SPATIALIZE off): read the ring directly.
    let ablp = UnsafeMutableAudioBufferListPointer(ioData)

    // We might have 1 or 2 buffers depending on how the unit was configured.
    if ablp.count >= 2 {
        let dst0 = ablp[0].mData!.assumingMemoryBound(to: Float.self)
        let dst1 = ablp[1].mData!.assumingMemoryBound(to: Float.self)
        ctx.ring.read(ch0: dst0, ch1: dst1, frameCount: n)
        ablp[0].mDataByteSize = n * 4
        ablp[1].mDataByteSize = n * 4
    } else if ablp.count == 1, let p = ablp[0].mData {
        // DEAD PATH: our playback Input/0 is hard-set to non-interleaved stereo, so
        // the HAL always delivers 2 buffers (ablp.count == 2). Kept only as a
        // defensive, ALLOCATION-FREE guard — emit silence rather than ever doing a
        // heap alloc on the RT thread. (The old interleave-via-malloc branch is gone.)
        memset(p, 0, Int(ablp[0].mDataByteSize))
    }

    ctx.totalPlayed &+= UInt64(n)
    return noErr
}

// ---------------------------------------------------------------------------
// MARK: - HAL unit factory
// ---------------------------------------------------------------------------

func makeHALOutputUnit() -> AudioUnit? {
    var desc = AudioComponentDescription(
        componentType:         kAudioUnitType_Output,
        componentSubType:      kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags:        0,
        componentFlagsMask:    0)
    guard let comp = AudioComponentFindNext(nil, &desc) else {
        print("  ERR AudioComponentFindNext returned nil")
        return nil
    }
    var unit: AudioUnit? = nil
    let s = AudioComponentInstanceNew(comp, &unit)
    check(s, "AudioComponentInstanceNew")
    return unit
}

func setEnableIO(_ unit: AudioUnit, enable: UInt32,
                 scope: AudioUnitScope, element: AudioUnitElement,
                 label: String) {
    var val = enable
    check(AudioUnitSetProperty(unit,
                               kAudioOutputUnitProperty_EnableIO,
                               scope, element,
                               &val, UInt32(MemoryLayout<UInt32>.size)),
          "\(label) EnableIO scope=\(scope) elem=\(element) val=\(enable)")
}

func setCurrentDevice(_ unit: AudioUnit, deviceID: AudioDeviceID, label: String) {
    var id = deviceID
    check(AudioUnitSetProperty(unit,
                               kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global, 0,
                               &id, UInt32(MemoryLayout<AudioDeviceID>.size)),
          "\(label) SetCurrentDevice \(deviceID)")
}

func setStreamFormat(_ unit: AudioUnit, fmt: inout AudioStreamBasicDescription,
                     scope: AudioUnitScope, element: AudioUnitElement, label: String) {
    check(AudioUnitSetProperty(unit,
                               kAudioUnitProperty_StreamFormat,
                               scope, element,
                               &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
          "\(label) StreamFormat scope=\(scope) elem=\(element)")
}

// ---------------------------------------------------------------------------
// MARK: - Spatial mixer factory (Phase 2)
// ---------------------------------------------------------------------------

/// Deinterleaved (planar) float32 ASBD with N channels @ 48 kHz.
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

@discardableResult
func setU32(_ unit: AudioUnit, _ prop: AudioUnitPropertyID,
            scope: AudioUnitScope, element: AudioUnitElement,
            value: UInt32, label: String) -> Bool {
    var v = value
    let ok = check(AudioUnitSetProperty(unit, prop, scope, element,
                                        &v, UInt32(MemoryLayout<UInt32>.size)), label)
    var rv: UInt32 = 0xDEAD_BEEF
    var rsz = UInt32(MemoryLayout<UInt32>.size)
    if AudioUnitGetProperty(unit, prop, scope, element, &rv, &rsz) == noErr {
        print("    readback \(label) -> \(rv)")
    }
    return ok
}

/// Instantiate + fully configure an AUSpatialMixer. Returns an INITIALIZED unit
/// ready to be pulled by playbackRenderCallback. Output/0 = stereo48k binaural.
///   bed == true : Input/0 = stereo48k, AmbienceBed (L/R → externalized far-field
///                 virtual speakers via the stereo channel layout). Product path.
///   bed == false: Input/0 = mono48k, PointSource @ az 0 (Phase-0 gate config).
func makeSpatialMixer(ctxPtr: UnsafeMutableRawPointer, maxFrames: UInt32, bed: Bool) -> AudioUnit? {
    var desc = AudioComponentDescription(
        componentType:         kAudioUnitType_Mixer,
        componentSubType:      kAudioUnitSubType_SpatialMixer,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags:        0,
        componentFlagsMask:    0)
    guard let comp = AudioComponentFindNext(nil, &desc) else {
        print("  ERR AUSpatialMixer component not found"); return nil
    }
    var unitOpt: AudioUnit? = nil
    guard check(AudioComponentInstanceNew(comp, &unitOpt), "spatial AudioComponentInstanceNew"),
          let unit = unitOpt else { return nil }

    // Stream formats: input bus = stereo (bed) or mono (point); output = stereo binaural.
    var inFmt     = makeFloatASBD(channels: bed ? 2 : 1)
    var stereoFmt = makeFloatASBD(channels: 2)
    let asbdSize  = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &inFmt, asbdSize),
          "spatial StreamFormat Input/0 = \(bed ? "stereo48k" : "mono48k")")
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Output, 0, &stereoFmt, asbdSize),
          "spatial StreamFormat Output/0 = stereo48k")

    // AmbienceBed needs the bus's AudioChannelLayout to know the L/R directions.
    if bed {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        layout.mNumberChannelDescriptions = 0
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_AudioChannelLayout,
                                   kAudioUnitScope_Input, 0,
                                   &layout, UInt32(MemoryLayout<AudioChannelLayout>.size)),
              "spatial AudioChannelLayout Input/0 = Stereo")
    }

    // MaximumFramesPerSlice must be >= the playback unit's slice, else
    // AudioUnitRender returns kAudioUnitErr_TooManyFramesToProcess (-10874).
    var maxF = maxFrames
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                               kAudioUnitScope_Global, 0,
                               &maxF, UInt32(MemoryLayout<UInt32>.size)),
          "spatial MaximumFramesPerSlice=\(maxFrames)")

    // Input render callback: ring → (stereo copy | mono downmix) → mixer input bus 0.
    var inputCB = AURenderCallbackStruct(inputProc: spatialInputCallback,
                                         inputProcRefCon: ctxPtr)
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0,
                               &inputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
          "spatial SetRenderCallback Input/0")

    // Spatial properties.
    setU32(unit, kAudioUnitProperty_SpatializationAlgorithm,
           scope: kAudioUnitScope_Input, element: 0,
           value: cfgAlgo, label: "SpatializationAlgorithm=\(cfgAlgoName)(\(cfgAlgo)) [Input/0]")
    let srcMode: UInt32 = bed ? kSrcModeAmbienceBed : kSrcModePointSource
    setU32(unit, kPropSourceMode,
           scope: kAudioUnitScope_Input, element: 0,
           value: srcMode, label: "SourceMode=\(cfgSrcModeName)(\(srcMode)) [3005/Input/0]")

    // OutputType: try Global, fall back to Input scope (build-dependent).
    var outType = cfgOutputType
    let sGlobal = AudioUnitSetProperty(unit, kPropOutputType,
                                       kAudioUnitScope_Global, 0,
                                       &outType, UInt32(MemoryLayout<UInt32>.size))
    if sGlobal == noErr {
        check(sGlobal, "OutputType=\(cfgOutputTypeName)(\(cfgOutputType)) [3100/Global]")
    } else {
        check(AudioUnitSetProperty(unit, kPropOutputType,
                                   kAudioUnitScope_Input, 0,
                                   &outType, UInt32(MemoryLayout<UInt32>.size)),
              "OutputType=\(cfgOutputTypeName)(\(cfgOutputType)) [3100/Input/0]")
    }

    setU32(unit, kPropEnableHeadTracking,
           scope: kAudioUnitScope_Global, element: 0,
           value: cfgHeadTrack, label: "EnableHeadTracking=\(cfgHeadTrack) [3111/Global]")
    setU32(unit, kPropPersonalizedHRTFMode,
           scope: kAudioUnitScope_Global, element: 0,
           value: cfgHRTFMode, label: "PersonalizedHRTFMode=\(cfgHRTFModeName)(\(cfgHRTFMode)) [3113/Global]")

    // Initialize (allocate render resources) BEFORE setting parameters / starting.
    guard check(AudioUnitInitialize(unit), "spatial AudioUnitInitialize") else {
        AudioComponentInstanceDispose(unit); return nil
    }

    // Anchor the source/bed dead-front (az/el 0) so head-tracking is world-locked.
    AudioUnitSetParameter(unit, kParamAzimuth,   kAudioUnitScope_Input, 0, 0.0, 0)
    AudioUnitSetParameter(unit, kParamElevation, kAudioUnitScope_Input, 0, 0.0, 0)
    AudioUnitSetParameter(unit, kParamDistance,  kAudioUnitScope_Input, 0, 1.0, 0)
    AudioUnitSetParameter(unit, kParamGain,      kAudioUnitScope_Input, 0, 0.0, 0)

    return unit
}

// ---------------------------------------------------------------------------
// MARK: - Main
// ---------------------------------------------------------------------------

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered stdout so live output reaches logs/pipes
print("=== AtmosDaemon starting ===")

// 1. Resolve devices
guard let atmosID = findAtmosControlDevice() else {
    print("FATAL: atmos-control loopback device not found (UID: atmos-control:loopback:0).")
    print("       Is the virtual audio driver installed and running?")
    exit(1)
}
guard let outputID = findRealOutputDevice(atmosID: atmosID) else {
    print("FATAL: no real output device found.")
    print("       Set OUTPUT_DEVICE env var to a substring of the desired device name.")
    exit(1)
}

print("Capture device : [\(atmosID)] \(deviceName(atmosID))")
print("Playback device: [\(outputID)] \(deviceName(outputID))")
if cfgSpatialize {
    print("Mode           : SPATIALIZE (AUSpatialMixer inserted)")
    print("  Source       : \(cfgSrcModeName)   HeadTrack=\(cfgHeadTrack)")
    print("  Config       : OutputType=\(cfgOutputTypeName)(\(cfgOutputType))  HRTFMode=\(cfgHRTFModeName)(\(cfgHRTFMode))  Algo=\(cfgAlgoName)(\(cfgAlgo))")
    if !deviceName(outputID).localizedCaseInsensitiveContains("airpods") {
        print("  WARNING      : playback device is not AirPods — 3116 (personalized HRTF) likely NO; head tracking unavailable")
    }
} else {
    print("Mode           : PASSTHROUGH (set SPATIALIZE=1 to insert the spatial mixer)")
}
print()

// 2. Build shared context
let ctx = Ctx()

// 3. Build capture unit
print("--- Setting up capture unit (atmos-control → ring) ---")
guard let captureUnit = makeHALOutputUnit() else { exit(1) }
ctx.captureUnit = captureUnit

// Disable output on element 0, enable input on element 1
setEnableIO(captureUnit, enable: 0,
            scope: kAudioUnitScope_Output, element: 0, label: "capture")
setEnableIO(captureUnit, enable: 1,
            scope: kAudioUnitScope_Input,  element: 1, label: "capture")
setCurrentDevice(captureUnit, deviceID: atmosID, label: "capture")

// Set format: the OUTPUT scope of element 1 is what AudioUnitRender delivers.
var capFmt = stereoFloat32Format()
setStreamFormat(captureUnit, fmt: &capFmt,
                scope: kAudioUnitScope_Output, element: 1, label: "capture")

// Query max frames so we can size the ABL
var maxFrames: UInt32 = 4096
var maxFramesSize = UInt32(MemoryLayout<UInt32>.size)
AudioUnitGetProperty(captureUnit,
                     kAudioUnitProperty_MaximumFramesPerSlice,
                     kAudioUnitScope_Global, 0,
                     &maxFrames, &maxFramesSize)
print("  Capture maxFramesPerSlice = \(maxFrames)")
ctx.captureABL     = makeCaptureABL(maxFrames: maxFrames)
ctx.captureBufSize = maxFrames

// Install input callback
let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
var inputCB = AURenderCallbackStruct(
    inputProc:       captureInputCallback,
    inputProcRefCon: ctxPtr)
check(AudioUnitSetProperty(captureUnit,
                           kAudioOutputUnitProperty_SetInputCallback,
                           kAudioUnitScope_Global, 0,
                           &inputCB,
                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
      "capture SetInputCallback")

check(AudioUnitInitialize(captureUnit),  "capture AudioUnitInitialize")

// 4. Build playback unit
print()
print("--- Setting up playback unit (ring → real output) ---")
guard let playbackUnit = makeHALOutputUnit() else { exit(1) }
ctx.playbackUnit = playbackUnit

// Default: output enabled (element 0); disable input (element 1)
setEnableIO(playbackUnit, enable: 1,
            scope: kAudioUnitScope_Output, element: 0, label: "playback")
setEnableIO(playbackUnit, enable: 0,
            scope: kAudioUnitScope_Input,  element: 1, label: "playback")
setCurrentDevice(playbackUnit, deviceID: outputID, label: "playback")

// Set format on INPUT scope of element 0 (what our render callback provides)
var playFmt = stereoFloat32Format()
setStreamFormat(playbackUnit, fmt: &playFmt,
                scope: kAudioUnitScope_Input, element: 0, label: "playback")

// Query playback max frames so we can size the spatial mixer slice + scratch.
var playMaxFrames: UInt32 = 4096
var playMaxFramesSize = UInt32(MemoryLayout<UInt32>.size)
AudioUnitGetProperty(playbackUnit,
                     kAudioUnitProperty_MaximumFramesPerSlice,
                     kAudioUnitScope_Global, 0,
                     &playMaxFrames, &playMaxFramesSize)
print("  Playback maxFramesPerSlice = \(playMaxFrames)")

// 4b. Optionally build + insert the AUSpatialMixer (Phase 2 gate).
//     Must be fully initialized BEFORE the playback unit starts pulling it.
if cfgSpatialize {
    print()
    print("--- Inserting AUSpatialMixer (ring → \(cfgBed ? "stereo bed" : "mono point") → binaural → playback) ---")
    let spatialMax = max(playMaxFrames, ctx.captureBufSize, 4096)
    ctx.spatialBed = cfgBed   // set BEFORE the mixer can be pulled (units not started yet)
    guard let mixer = makeSpatialMixer(ctxPtr: ctxPtr, maxFrames: spatialMax, bed: cfgBed) else {
        print("FATAL: could not build AUSpatialMixer.")
        exit(1)
    }
    // Mono-downmix scratch (only used in point mode; harmless to allocate for bed).
    let dmL = UnsafeMutablePointer<Float>.allocate(capacity: Int(spatialMax))
    let dmR = UnsafeMutablePointer<Float>.allocate(capacity: Int(spatialMax))
    dmL.initialize(repeating: 0, count: Int(spatialMax))
    dmR.initialize(repeating: 0, count: Int(spatialMax))
    ctx.dmL = dmL
    ctx.dmR = dmR
    ctx.spatialMaxFrames = spatialMax
    ctx.spatialMixer = mixer
    // Publish the gate flag LAST, after the mixer + scratch are fully ready, so the
    // RT playback callback never sees spatialize=true with a half-built mixer.
    ctx.spatialize = true
    print("  Spatial mixer ready (slice<=\(spatialMax)).")
}

// Install render callback
var renderCB = AURenderCallbackStruct(
    inputProc:       playbackRenderCallback,
    inputProcRefCon: ctxPtr)
check(AudioUnitSetProperty(playbackUnit,
                           kAudioUnitProperty_SetRenderCallback,
                           kAudioUnitScope_Input, 0,
                           &renderCB,
                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
      "playback SetRenderCallback")

check(AudioUnitInitialize(playbackUnit),  "playback AudioUnitInitialize")

// 5. Start both units
print()
print("--- Starting ---")
check(AudioOutputUnitStart(captureUnit),  "captureUnit  Start")
check(AudioOutputUnitStart(playbackUnit), "playbackUnit Start")

print()
print("Passthrough running. Press Ctrl-C to stop.")
print()

// 6. SIGINT shutdown
var shouldQuit = false
signal(SIGINT) { _ in shouldQuit = true }

// 7. Diagnostics loop — ~1-second cadence.
//    RUN_SECONDS=N auto-stops after N ticks (0/unset = run until Ctrl-C).
let cfgRunSeconds = UInt64(ProcessInfo.processInfo.environment["RUN_SECONDS"] ?? "") ?? 0
var lastCaptured: UInt64 = 0
var lastPlayed:   UInt64 = 0
var tick: UInt64 = 0
var everEngaged3116 = false

while !shouldQuit {
    if cfgRunSeconds > 0 && tick >= cfgRunSeconds { break }
    usleep(1_000_000)   // 1 second
    tick += 1
    let cap  = ctx.totalCaptured
    let play = ctx.totalPlayed
    let fill = ctx.ring.fill()
    let dcap  = cap  - lastCaptured
    let dplay = play - lastPlayed
    let pk = ctx.capturePeak; ctx.capturePeak = 0   // read + reset meter
    let pkDb = pk > 0 ? 20 * log10(Double(pk)) : -120.0

    // Phase 2 gate signal: poll 3116 (AnyInputUsingPersonalizedHRTF) on the mixer.
    var hrtfTag = ""
    if ctx.spatialize, let mixer = ctx.spatialMixer {
        var hrtfVal: UInt32 = 0
        var hrtfSz  = UInt32(MemoryLayout<UInt32>.size)
        let st = AudioUnitGetProperty(mixer, kPropAnyInputUsingPersonalizedHRTF,
                                      kAudioUnitScope_Global, 0, &hrtfVal, &hrtfSz)
        if st == noErr {
            let yes = (hrtfVal != 0)
            if yes { everEngaged3116 = true }
            hrtfTag = "  personalizedHRTF(3116)=\(yes ? "YES" : "NO")"
        } else {
            hrtfTag = "  personalizedHRTF(3116)=ERR(\(st))"
        }
    }

    print(String(format: "t=%2lus  captured=%llu (+%llu)  played=%llu (+%llu)  ringFill=%llu  peak=%.4f (%.1f dBFS)%@",
                 tick, cap, dcap, play, dplay, fill, Double(pk), pkDb, hrtfTag))
    if tick >= 3 && cap == 0 {
        print("WARNING: captured==0 after \(tick)s — virtual device IO may not be running.")
        print("         Check: device has an active client writing audio to atmos-control.")
    }
    lastCaptured = cap
    lastPlayed   = play
}

// 8. Clean shutdown
print("\nStopping...")
AudioOutputUnitStop(captureUnit)
AudioOutputUnitStop(playbackUnit)
// Stop the playback unit FIRST (above) so no RT pull touches the mixer, then
// tear the mixer down.
if let mixer = ctx.spatialMixer {
    AudioUnitUninitialize(mixer)
    AudioComponentInstanceDispose(mixer)
    ctx.spatialMixer = nil
}
AudioUnitUninitialize(captureUnit)
AudioUnitUninitialize(playbackUnit)
AudioComponentInstanceDispose(captureUnit)
AudioComponentInstanceDispose(playbackUnit)
// Free the spatial downmix scratch and the capture ABL (+ its planar buffers).
ctx.dmL?.deallocate(); ctx.dmL = nil
ctx.dmR?.deallocate(); ctx.dmR = nil
if let abl = ctx.captureABL {
    for ch in 0..<abl.count { abl[ch].mData?.deallocate() }
    free(abl.unsafeMutablePointer)
    ctx.captureABL = nil
}

if cfgSpatialize {
    print()
    print("─── Phase 2 gate result ───────────────────────────────────────────────")
    if cfgOutputType != kOutputTypeHeadphones {
        print("  Speaker-virtualization path (OutputType=\(cfgOutputTypeName)) — 3116 is headphones-only; NO is expected.")
    } else if cfgHRTFMode == kPersonalizedHRTFOff {
        print("  Generic HRTF (PersonalizedHRTFMode=Off) — 3116=NO by design; binaural still active.")
    } else if everEngaged3116 {
        print("  PERSONALIZED HRTF ENGAGED IN THE DAEMON (3116=YES). Daemon-context gate PASSED.")
    } else {
        print("  Personalization NOT engaged in the daemon (3116 never YES).")
        print("  Likely: not AirPods, no scanned profile, OR the virtual-default-output")
        print("  context suppressed the OS personalized/head-tracked path (the Phase 2 unknown).")
    }
    print("  (Subjective check still required: externalized + head-tracked while wearing AirPods.)")
}
print("Done.")
