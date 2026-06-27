// SpatialEngine/Audio.swift — internal CoreAudio machinery for the spatializer.
// Moved out of the Phase-1/2 AtmosDaemon CLI so both the daemon and the SwiftUI
// app can drive the same proven engine. CoreAudio HAL only (no AVAudioEngine).
//
// CRITICAL: @convention(c) callbacks must touch ONLY raw pointers and the Ctx
// object passed via inRefCon. No Swift Array closures, no main-actor globals.

import CoreAudio
import AudioToolbox
import Darwin          // fabsf, memset, free
import Synchronization // Atomic<UInt64> — release/acquire ordering on the SPSC indices

// ---------------------------------------------------------------------------
// MARK: - Optional setup logger (RT callbacks never log)
// ---------------------------------------------------------------------------
// Set once by SpatialEngine.start() on the main thread before any audio runs.
// The daemon CLI routes this to print(); the app leaves it nil (silent).
nonisolated(unsafe) var seLog: ((String) -> Void)? = nil

@inline(__always) func selog(_ s: String) { seLog?(s) }

@discardableResult
func check(_ status: OSStatus, _ label: String) -> Bool {
    if status == noErr {
        selog("  OK  \(label)")
        return true
    } else {
        selog("  ERR \(label): \(status) (0x\(String(status, radix: 16)))")
        return false
    }
}

// ---------------------------------------------------------------------------
// MARK: - AUSpatialMixer property IDs + enum values (numeric; CLT-safe)
// ---------------------------------------------------------------------------

let kPropSourceMode:                    AudioUnitPropertyID = 3005
let kPropOutputType:                    AudioUnitPropertyID = 3100
let kPropEnableHeadTracking:            AudioUnitPropertyID = 3111
let kPropPersonalizedHRTFMode:          AudioUnitPropertyID = 3113
let kPropAnyInputUsingPersonalizedHRTF: AudioUnitPropertyID = 3116

let kSrcModePointSource: UInt32 = 2
let kSrcModeAmbienceBed: UInt32 = 3

let kParamAzimuth:   AudioUnitParameterID = 0   // ±180°
let kParamElevation: AudioUnitParameterID = 1   // ±90°
let kParamDistance:  AudioUnitParameterID = 2   // metres
let kParamGain:      AudioUnitParameterID = 3   // dB

// ---------------------------------------------------------------------------
// MARK: - Lock-free SPSC ring buffer (atomic release/acquire indices)
// ---------------------------------------------------------------------------

let kRingFrames: UInt64 = 32768       // power-of-two
let kRingMask:   UInt64 = kRingFrames - 1
let kRingChannels = 2

final class RingBuffer {
    let buf0: UnsafeMutablePointer<Float>
    let buf1: UnsafeMutablePointer<Float>
    // arm64 is weakly ordered: producer release-stores writeIdx after the buffer
    // writes; consumer acquire-loads it, so a bumped index implies visible samples.
    let writeIdx = Atomic<UInt64>(0)
    let readIdx  = Atomic<UInt64>(0)

    init() {
        buf0 = .allocate(capacity: Int(kRingFrames))
        buf1 = .allocate(capacity: Int(kRingFrames))
        buf0.initialize(repeating: 0, count: Int(kRingFrames))
        buf1.initialize(repeating: 0, count: Int(kRingFrames))
    }
    deinit { buf0.deallocate(); buf1.deallocate() }

    @inline(__always)
    func fill() -> UInt64 {
        writeIdx.load(ordering: .acquiring) &- readIdx.load(ordering: .acquiring)
    }

    /// Reset indices to empty. Call only when no RT thread is touching the ring.
    func reset() {
        writeIdx.store(0, ordering: .relaxed)
        readIdx.store(0, ordering: .relaxed)
    }

    @inline(__always) @discardableResult
    func write(ch0 src0: UnsafePointer<Float>, ch1 src1: UnsafePointer<Float>,
               frameCount: UInt32) -> UInt32 {
        let wi = writeIdx.load(ordering: .relaxed)
        let ri = readIdx.load(ordering: .acquiring)
        let available = kRingFrames &- (wi &- ri)
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
        writeIdx.store(wi &+ toWrite, ordering: .releasing)
        return UInt32(toWrite)
    }

    @inline(__always) @discardableResult
    func read(ch0 dst0: UnsafeMutablePointer<Float>, ch1 dst1: UnsafeMutablePointer<Float>,
              frameCount: UInt32) -> UInt32 {
        let ri = readIdx.load(ordering: .relaxed)
        let wi = writeIdx.load(ordering: .acquiring)
        let available = wi &- ri
        let want = UInt64(frameCount)
        let toRead = want < available ? want : available
        if toRead == 0 {
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
// MARK: - Shared RT context (passed as inRefCon to the callbacks)
// ---------------------------------------------------------------------------

final class Ctx: @unchecked Sendable {
    let ring = RingBuffer()
    var captureUnit:  AudioUnit? = nil
    var playbackUnit: AudioUnit? = nil
    var totalCaptured: UInt64 = 0
    var totalPlayed:   UInt64 = 0
    var captureABL: UnsafeMutableAudioBufferListPointer? = nil
    var captureBufSize: UInt32 = 0
    // Per-channel peak (max |sample|) since last poll. Written on the capture RT
    // thread, read+reset on the main thread — aligned Float access is atomic on arm64.
    var capturePeakL: Float = 0
    var capturePeakR: Float = 0

    var spatialMixer:    AudioUnit? = nil
    var spatialize:      Bool = false
    var spatialBed:      Bool = false
    var dmL:             UnsafeMutablePointer<Float>? = nil
    var dmR:             UnsafeMutablePointer<Float>? = nil
    var spatialMaxFrames: UInt32 = 0
}

// ---------------------------------------------------------------------------
// MARK: - Format helpers
// ---------------------------------------------------------------------------

func stereoFloat32Format(sampleRate: Float64 = 48000) -> AudioStreamBasicDescription {
    var fmt = AudioStreamBasicDescription()
    fmt.mSampleRate       = sampleRate
    fmt.mFormatID         = kAudioFormatLinearPCM
    fmt.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
    fmt.mBitsPerChannel   = 32
    fmt.mChannelsPerFrame = 2
    fmt.mFramesPerPacket  = 1
    fmt.mBytesPerFrame    = 4
    fmt.mBytesPerPacket   = 4
    return fmt
}

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

func makeCaptureABL(maxFrames: UInt32) -> UnsafeMutableAudioBufferListPointer {
    let abl = AudioBufferList.allocate(maximumBuffers: kRingChannels)
    for ch in 0..<kRingChannels {
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: Int(maxFrames) * MemoryLayout<Float>.size,
            alignment: MemoryLayout<Float>.alignment)
        data.initializeMemory(as: Float.self, repeating: 0, count: Int(maxFrames))
        abl[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maxFrames * 4, mData: data)
    }
    return abl
}

// ---------------------------------------------------------------------------
// MARK: - RT callbacks (raw pointers only; env-free — read ctx fields)
// ---------------------------------------------------------------------------

nonisolated(unsafe) let captureInputCallback: AURenderCallback = { (
    inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _
) -> OSStatus in
    let ctx = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = ctx.captureUnit, let abl = ctx.captureABL else { return noErr }
    let n = inNumberFrames
    abl[0].mDataByteSize = n * 4
    abl[1].mDataByteSize = n * 4
    let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, n, abl.unsafeMutablePointer)
    if status != noErr { return status }
    let src0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
    let src1 = abl[1].mData!.assumingMemoryBound(to: Float.self)
    let written = ctx.ring.write(ch0: src0, ch1: src1, frameCount: n)
    ctx.totalCaptured &+= UInt64(written)
    // Per-channel peak (raw loop + fabsf — no Swift runtime calls on the RT thread).
    var pkL: Float = 0, pkR: Float = 0
    var i = 0; let cnt = Int(n)
    while i < cnt {
        let a0 = fabsf(src0[i]); if a0 > pkL { pkL = a0 }
        let a1 = fabsf(src1[i]); if a1 > pkR { pkR = a1 }
        i &+= 1
    }
    if pkL > ctx.capturePeakL { ctx.capturePeakL = pkL }
    if pkR > ctx.capturePeakR { ctx.capturePeakR = pkR }
    return noErr
}

// Sole ring consumer in spatialize mode (runs inside AudioUnitRender on the
// playback HAL thread). bed = stereo copy; point = mono downmix.
nonisolated(unsafe) let spatialInputCallback: AURenderCallback = { (
    inRefCon, _, _, _, inNumberFrames, ioData
) -> OSStatus in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    let n = inNumberFrames
    let nbuf = abl.count
    guard n <= ctx.spatialMaxFrames else {
        var b = 0; while b < nbuf { if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }; b &+= 1 }
        return noErr
    }
    if ctx.spatialBed {
        if nbuf >= 2, let p0 = abl[0].mData, let p1 = abl[1].mData {
            ctx.ring.read(ch0: p0.assumingMemoryBound(to: Float.self),
                          ch1: p1.assumingMemoryBound(to: Float.self), frameCount: n)
            abl[0].mDataByteSize = n * 4
            abl[1].mDataByteSize = n * 4
        }
        return noErr
    }
    guard let dmL = ctx.dmL, let dmR = ctx.dmR else {
        var b = 0; while b < nbuf { if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }; b &+= 1 }
        return noErr
    }
    ctx.ring.read(ch0: dmL, ch1: dmR, frameCount: n)
    let cnt = Int(n)
    var b = 0
    while b < nbuf {
        if let raw = abl[b].mData {
            let out = raw.assumingMemoryBound(to: Float.self)
            var i = 0
            while i < cnt { out[i] = 0.5 * (dmL[i] + dmR[i]); i &+= 1 }
            abl[b].mDataByteSize = n * 4
        }
        b &+= 1
    }
    return noErr
}

nonisolated(unsafe) let playbackRenderCallback: AURenderCallback = { (
    inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, ioData
) -> OSStatus in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    let n = inNumberFrames
    if ctx.spatialize, let mixer = ctx.spatialMixer {
        let st = AudioUnitRender(mixer, ioActionFlags, inTimeStamp, 0, n, ioData)
        ctx.totalPlayed &+= UInt64(n)
        return st
    }
    let ablp = UnsafeMutableAudioBufferListPointer(ioData)
    if ablp.count >= 2 {
        let dst0 = ablp[0].mData!.assumingMemoryBound(to: Float.self)
        let dst1 = ablp[1].mData!.assumingMemoryBound(to: Float.self)
        ctx.ring.read(ch0: dst0, ch1: dst1, frameCount: n)
        ablp[0].mDataByteSize = n * 4
        ablp[1].mDataByteSize = n * 4
    } else if ablp.count == 1, let p = ablp[0].mData {
        memset(p, 0, Int(ablp[0].mDataByteSize))   // dead path (format is always stereo)
    }
    ctx.totalPlayed &+= UInt64(n)
    return noErr
}

// ---------------------------------------------------------------------------
// MARK: - HAL unit + spatial mixer factories
// ---------------------------------------------------------------------------

func makeHALOutputUnit() -> AudioUnit? {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { selog("  ERR AudioComponentFindNext nil"); return nil }
    var unit: AudioUnit? = nil
    check(AudioComponentInstanceNew(comp, &unit), "AudioComponentInstanceNew")
    return unit
}

func setEnableIO(_ unit: AudioUnit, enable: UInt32, scope: AudioUnitScope, element: AudioUnitElement, label: String) {
    var val = enable
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, scope, element,
                               &val, UInt32(MemoryLayout<UInt32>.size)),
          "\(label) EnableIO scope=\(scope) elem=\(element) val=\(enable)")
}

func setCurrentDevice(_ unit: AudioUnit, deviceID: AudioDeviceID, label: String) {
    var id = deviceID
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                               &id, UInt32(MemoryLayout<AudioDeviceID>.size)),
          "\(label) SetCurrentDevice \(deviceID)")
}

func setStreamFormat(_ unit: AudioUnit, fmt: inout AudioStreamBasicDescription,
                     scope: AudioUnitScope, element: AudioUnitElement, label: String) {
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element,
                               &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
          "\(label) StreamFormat scope=\(scope) elem=\(element)")
}

@discardableResult
func setU32(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, scope: AudioUnitScope,
            element: AudioUnitElement, value: UInt32, label: String) -> Bool {
    var v = value
    let ok = check(AudioUnitSetProperty(unit, prop, scope, element, &v, UInt32(MemoryLayout<UInt32>.size)), label)
    var rv: UInt32 = 0xDEAD_BEEF; var rsz = UInt32(MemoryLayout<UInt32>.size)
    if AudioUnitGetProperty(unit, prop, scope, element, &rv, &rsz) == noErr { selog("    readback \(label) -> \(rv)") }
    return ok
}

/// Instantiate + fully configure an AUSpatialMixer per the supplied config values.
/// Returns an INITIALIZED unit. Output/0 = stereo48k binaural.
func makeSpatialMixer(ctxPtr: UnsafeMutableRawPointer, maxFrames: UInt32, bed: Bool,
                      algo: UInt32, algoName: String, outputType: UInt32, outputTypeName: String,
                      hrtfMode: UInt32, hrtfModeName: String, headTrack: UInt32) -> AudioUnit? {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Mixer, componentSubType: kAudioUnitSubType_SpatialMixer,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { selog("  ERR AUSpatialMixer not found"); return nil }
    var unitOpt: AudioUnit? = nil
    guard check(AudioComponentInstanceNew(comp, &unitOpt), "spatial AudioComponentInstanceNew"),
          let unit = unitOpt else { return nil }

    var inFmt     = makeFloatASBD(channels: bed ? 2 : 1)
    var stereoFmt = makeFloatASBD(channels: 2)
    let asbdSize  = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &inFmt, asbdSize),
          "spatial StreamFormat Input/0 = \(bed ? "stereo48k" : "mono48k")")
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &stereoFmt, asbdSize),
          "spatial StreamFormat Output/0 = stereo48k")

    if bed {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        layout.mNumberChannelDescriptions = 0
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0,
                                   &layout, UInt32(MemoryLayout<AudioChannelLayout>.size)),
              "spatial AudioChannelLayout Input/0 = Stereo")
    }

    var maxF = maxFrames
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                               &maxF, UInt32(MemoryLayout<UInt32>.size)), "spatial MaximumFramesPerSlice=\(maxFrames)")

    var inputCB = AURenderCallbackStruct(inputProc: spatialInputCallback, inputProcRefCon: ctxPtr)
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                               &inputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
          "spatial SetRenderCallback Input/0")

    setU32(unit, kAudioUnitProperty_SpatializationAlgorithm, scope: kAudioUnitScope_Input, element: 0,
           value: algo, label: "SpatializationAlgorithm=\(algoName)(\(algo)) [Input/0]")
    let srcMode: UInt32 = bed ? kSrcModeAmbienceBed : kSrcModePointSource
    setU32(unit, kPropSourceMode, scope: kAudioUnitScope_Input, element: 0,
           value: srcMode, label: "SourceMode=\(bed ? "AmbienceBed" : "PointSource")(\(srcMode)) [3005/Input/0]")

    var outType = outputType
    let sGlobal = AudioUnitSetProperty(unit, kPropOutputType, kAudioUnitScope_Global, 0,
                                       &outType, UInt32(MemoryLayout<UInt32>.size))
    if sGlobal == noErr {
        check(sGlobal, "OutputType=\(outputTypeName)(\(outputType)) [3100/Global]")
    } else {
        check(AudioUnitSetProperty(unit, kPropOutputType, kAudioUnitScope_Input, 0,
                                   &outType, UInt32(MemoryLayout<UInt32>.size)),
              "OutputType=\(outputTypeName)(\(outputType)) [3100/Input/0]")
    }

    setU32(unit, kPropEnableHeadTracking, scope: kAudioUnitScope_Global, element: 0,
           value: headTrack, label: "EnableHeadTracking=\(headTrack) [3111/Global]")
    setU32(unit, kPropPersonalizedHRTFMode, scope: kAudioUnitScope_Global, element: 0,
           value: hrtfMode, label: "PersonalizedHRTFMode=\(hrtfModeName)(\(hrtfMode)) [3113/Global]")

    guard check(AudioUnitInitialize(unit), "spatial AudioUnitInitialize") else {
        AudioComponentInstanceDispose(unit); return nil
    }
    return unit
}
