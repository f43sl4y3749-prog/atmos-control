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
import Darwin   // for signal(), usleep, atomic operations

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
    // Atomic indices — use _Atomic via Swift's interop with C atomics via
    // plain UnsafeMutablePointer + OSAtomicCompareAndSwap… is not ideal;
    // instead we keep two separate UnsafeMutablePointer<UInt64> and use
    // Swift's withUnsafeMutablePointer + os_unfair_lock-free trick:
    // Because this is SPSC (one producer thread, one consumer thread) we can
    // use relaxed plain stores/loads if we ensure memory ordering via a fence.
    // We use a simple approach: store volatile-equivalent via Swift's
    // UnsafeMutablePointer<UInt64> directly (Swift doesn't reorder these on arm64).
    let writeIdxPtr: UnsafeMutablePointer<UInt64>
    let readIdxPtr:  UnsafeMutablePointer<UInt64>

    init() {
        buf0 = .allocate(capacity: Int(kRingFrames))
        buf1 = .allocate(capacity: Int(kRingFrames))
        buf0.initialize(repeating: 0, count: Int(kRingFrames))
        buf1.initialize(repeating: 0, count: Int(kRingFrames))
        writeIdxPtr = .allocate(capacity: 1)
        readIdxPtr  = .allocate(capacity: 1)
        writeIdxPtr.initialize(to: 0)
        readIdxPtr.initialize(to: 0)
    }

    deinit {
        buf0.deallocate()
        buf1.deallocate()
        writeIdxPtr.deallocate()
        readIdxPtr.deallocate()
    }

    /// Frames available to read.
    @inline(__always)
    func fill() -> UInt64 {
        // On arm64 loads of aligned 64-bit values are atomic by hardware guarantee.
        return writeIdxPtr.pointee &- readIdxPtr.pointee
    }

    /// Write up to `frameCount` frames from two planar float pointers.
    /// Returns frames actually written (may be less if ring is full).
    @inline(__always) @discardableResult
    func write(ch0 src0: UnsafePointer<Float>,
               ch1 src1: UnsafePointer<Float>,
               frameCount: UInt32) -> UInt32 {
        let wi = writeIdxPtr.pointee
        let ri = readIdxPtr.pointee
        let available = kRingFrames &- (wi &- ri)   // free slots
        let toWrite = min(UInt64(frameCount), available)
        if toWrite == 0 { return 0 }
        for i in 0..<toWrite {
            let slot = Int((wi &+ i) & kRingMask)
            buf0[slot] = src0[Int(i)]
            buf1[slot] = src1[Int(i)]
        }
        // Store-release equivalent: on arm64 a plain store to an aligned 64-bit
        // word is visible to other cores after a DMB; Swift doesn't reorder
        // stores across separate pointer writes in practice, but to be safe we
        // increment writeIdx AFTER the data writes above.
        writeIdxPtr.pointee = wi &+ toWrite
        return UInt32(toWrite)
    }

    /// Read up to `frameCount` frames into two planar float pointers.
    /// Fills with zeros and returns 0 frames on underrun.
    @inline(__always) @discardableResult
    func read(ch0 dst0: UnsafeMutablePointer<Float>,
              ch1 dst1: UnsafeMutablePointer<Float>,
              frameCount: UInt32) -> UInt32 {
        let ri = readIdxPtr.pointee
        let wi = writeIdxPtr.pointee
        let available = wi &- ri
        let toRead = min(UInt64(frameCount), available)
        if toRead == 0 {
            // Underrun — silence
            dst0.initialize(repeating: 0, count: Int(frameCount))
            dst1.initialize(repeating: 0, count: Int(frameCount))
            return 0
        }
        for i in 0..<toRead {
            let slot = Int((ri &+ i) & kRingMask)
            dst0[Int(i)] = buf0[slot]
            dst1[Int(i)] = buf1[slot]
        }
        // Zero any remainder
        if toRead < UInt64(frameCount) {
            let rem = Int(frameCount) - Int(toRead)
            (dst0 + Int(toRead)).initialize(repeating: 0, count: rem)
            (dst1 + Int(toRead)).initialize(repeating: 0, count: rem)
        }
        readIdxPtr.pointee = ri &+ toRead
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

    // Write into ring
    let src0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
    let src1 = abl[1].mData!.assumingMemoryBound(to: Float.self)
    ctx.ring.write(ch0: src0, ch1: src1, frameCount: n)
    ctx.totalCaptured &+= UInt64(n)

    // Peak meter over this block (raw-pointer loop only — no Array closures on RT thread)
    var pk: Float = 0
    var i = 0
    let cnt = Int(n)
    while i < cnt {
        let a0 = abs(src0[i]); if a0 > pk { pk = a0 }
        let a1 = abs(src1[i]); if a1 > pk { pk = a1 }
        i += 1
    }
    if pk > ctx.capturePeak { ctx.capturePeak = pk }

    return noErr
}

// ---------------------------------------------------------------------------
// MARK: - Render callback (ring → playback)
// ---------------------------------------------------------------------------

let playbackRenderCallback: AURenderCallback = { (
    inRefCon,
    _,           // ioActionFlags
    _,           // inTimeStamp
    _,           // inBusNumber
    inNumberFrames,
    ioData
) -> OSStatus in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    let ablp = UnsafeMutableAudioBufferListPointer(ioData)

    // We might have 1 or 2 buffers depending on how the unit was configured.
    let n = inNumberFrames
    if ablp.count >= 2 {
        let dst0 = ablp[0].mData!.assumingMemoryBound(to: Float.self)
        let dst1 = ablp[1].mData!.assumingMemoryBound(to: Float.self)
        ctx.ring.read(ch0: dst0, ch1: dst1, frameCount: n)
        ablp[0].mDataByteSize = n * 4
        ablp[1].mDataByteSize = n * 4
    } else if ablp.count == 1 {
        // Interleaved fallback (shouldn't happen with our format, but be safe)
        let dst = ablp[0].mData!.assumingMemoryBound(to: Float.self)
        // read ch0 into first half, ch1 into second half, then interleave manually
        // Allocate tiny stack buffers (max 4096 frames × 4 bytes = 16 kB, safe on RT stack)
        let tmp0 = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
        let tmp1 = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
        defer { tmp0.deallocate(); tmp1.deallocate() }
        ctx.ring.read(ch0: tmp0, ch1: tmp1, frameCount: n)
        for i in 0..<Int(n) {
            dst[i * 2]     = tmp0[i]
            dst[i * 2 + 1] = tmp1[i]
        }
        ablp[0].mDataByteSize = n * 8
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

// 7. Diagnostics loop — ~1-second cadence
var lastCaptured: UInt64 = 0
var lastPlayed:   UInt64 = 0
var tick: UInt64 = 0

while !shouldQuit {
    usleep(1_000_000)   // 1 second
    tick += 1
    let cap  = ctx.totalCaptured
    let play = ctx.totalPlayed
    let fill = ctx.ring.fill()
    let dcap  = cap  - lastCaptured
    let dplay = play - lastPlayed
    let pk = ctx.capturePeak; ctx.capturePeak = 0   // read + reset meter
    let pkDb = pk > 0 ? 20 * log10(Double(pk)) : -120.0
    print(String(format: "t=%2lus  captured=%llu (+%llu)  played=%llu (+%llu)  ringFill=%llu  peak=%.4f (%.1f dBFS)",
                 tick, cap, dcap, play, dplay, fill, Double(pk), pkDb))
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
AudioUnitUninitialize(captureUnit)
AudioUnitUninitialize(playbackUnit)
AudioComponentInstanceDispose(captureUnit)
AudioComponentInstanceDispose(playbackUnit)
print("Done.")
