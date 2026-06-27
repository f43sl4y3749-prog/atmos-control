// SpatialEngine — public API. Drives the proven capture → AUSpatialMixer →
// output graph; consumed by both the AtmosDaemon CLI and the SwiftUI app.
//
// Threading: all SpatialEngine methods are intended to be called from the main
// thread (UI / CLI loop). The real-time HAL threads touch only the internal Ctx.

import CoreAudio
import AudioToolbox

// MARK: - Public config types

public enum OutputType: UInt32, CaseIterable, Sendable, Identifiable {
    case headphones = 1, builtInSpeakers = 2, externalSpeakers = 3
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self {
        case .headphones: return "Headphones"
        case .builtInSpeakers: return "Built-in Speakers"
        case .externalSpeakers: return "External Speakers"
        }
    }
}

public enum HRTFMode: UInt32, CaseIterable, Sendable, Identifiable {
    case off = 0, on = 1, auto = 2
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self { case .off: return "Off"; case .on: return "On"; case .auto: return "Auto" }
    }
}

public enum SpatAlgorithm: UInt32, CaseIterable, Sendable, Identifiable {
    case hrtf = 2, hrtfHQ = 6, useOutputType = 7
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self { case .hrtf: return "HRTF"; case .hrtfHQ: return "HRTF HQ"; case .useOutputType: return "Use Output Type" }
    }
}

public enum SourceRenderMode: String, CaseIterable, Sendable, Identifiable {
    case ambienceBedStereo, pointSourceMono
    public var id: String { rawValue }
    public var label: String { self == .ambienceBedStereo ? "Stereo Bed" : "Mono Point" }
    var isBed: Bool { self == .ambienceBedStereo }
}

public struct SpatialConfig: Sendable, Equatable {
    public var spatialize: Bool = true                 // false = direct passthrough (debug)
    public var sourceMode: SourceRenderMode = .ambienceBedStereo
    public var outputType: OutputType = .headphones
    public var hrtfMode: HRTFMode = .auto
    public var algorithm: SpatAlgorithm = .useOutputType
    public var headTracking: Bool = true
    public var azimuth: Float = 0      // ±180°
    public var elevation: Float = 0    // ±90°
    public var distance: Float = 1.0   // metres
    public var gain: Float = 0         // dB
    public init() {}
}

public struct AudioOutputDevice: Identifiable, Sendable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public let isAirPods: Bool
}

public struct EngineState: Sendable, Equatable {
    public var running = false
    public var outputDeviceName = ""
    public var personalizedHRTFEngaged = false   // property 3116
    public var peakL: Float = 0                   // linear 0…1, peak since last poll
    public var peakR: Float = 0
    public var ringFill: UInt64 = 0
    public var totalCaptured: UInt64 = 0          // rising ⇒ audio is flowing in
    public var totalPlayed: UInt64 = 0
    public init() {}
}

public enum SpatialEngineError: Error, CustomStringConvertible {
    case atmosDeviceNotFound, noOutputDevice, setupFailed(String)
    public var description: String {
        switch self {
        case .atmosDeviceNotFound: return "atmos-control loopback device not found (is the HAL driver installed?)"
        case .noOutputDevice: return "no real output device available"
        case .setupFailed(let s): return "audio setup failed: \(s)"
        }
    }
}

// MARK: - Engine

public final class SpatialEngine: @unchecked Sendable {
    public private(set) var isRunning = false
    public var config = SpatialConfig()
    /// Optional setup logger (verbose property-set trace). nil = silent.
    public var logger: ((String) -> Void)? = nil

    private var ctx: Ctx?
    private var outputDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)

    public init() {}

    // MARK: Device discovery

    /// True when the atmos-control virtual HAL device is present.
    public func atmosControlPresent() -> Bool { findAtmosControlDevice() != nil }

    /// Output-capable devices, excluding the atmos-control loopback itself.
    public func outputDevices() -> [AudioOutputDevice] {
        guard let atmos = findAtmosControlDevice() else { return [] }
        var out: [AudioOutputDevice] = []
        for id in allDeviceIDs() where id != atmos && deviceHasChannels(id, scope: kAudioObjectPropertyScopeOutput) {
            let name = deviceName(id)
            out.append(AudioOutputDevice(id: id, name: name, isAirPods: name.localizedCaseInsensitiveContains("airpods")))
        }
        return out
    }

    // MARK: Default-output routing (no entitlement)

    public static func currentDefaultOutput() -> (id: AudioDeviceID, name: String) {
        let id = defaultOutputDeviceID()
        return (id, deviceName(id))
    }

    @discardableResult
    public static func setDefaultOutput(_ id: AudioDeviceID, includeSystem: Bool = true) -> Bool {
        let a = setDefaultOutputDeviceID(id, system: false)
        let b = includeSystem ? setDefaultOutputDeviceID(id, system: true) : noErr
        return a == noErr && b == noErr
    }

    public static func atmosControlDeviceID() -> AudioDeviceID? { findAtmosControlDevice() }

    // MARK: Lifecycle

    /// Build + start the graph. `outputDeviceID` is the *real* sink (e.g. AirPods);
    /// nil resolves the current default output (when it isn't atmos-control).
    public func start(outputDeviceID requested: AudioDeviceID? = nil) throws {
        guard !isRunning else { return }
        seLog = logger

        guard let atmosID = findAtmosControlDevice() else { throw SpatialEngineError.atmosDeviceNotFound }
        let outID = try resolveOutput(requested: requested, atmosID: atmosID)
        outputDeviceID = outID
        selog("Capture device : [\(atmosID)] \(deviceName(atmosID))")
        selog("Playback device: [\(outID)] \(deviceName(outID))")

        let ctx = Ctx()
        self.ctx = ctx
        let ctxPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(ctx).toOpaque())

        // --- Capture unit (atmos-control → ring) ---
        guard let captureUnit = makeHALOutputUnit() else { throw SpatialEngineError.setupFailed("capture unit") }
        ctx.captureUnit = captureUnit
        setEnableIO(captureUnit, enable: 0, scope: kAudioUnitScope_Output, element: 0, label: "capture")
        setEnableIO(captureUnit, enable: 1, scope: kAudioUnitScope_Input, element: 1, label: "capture")
        setCurrentDevice(captureUnit, deviceID: atmosID, label: "capture")
        var capFmt = stereoFloat32Format()
        setStreamFormat(captureUnit, fmt: &capFmt, scope: kAudioUnitScope_Output, element: 1, label: "capture")
        var maxFrames: UInt32 = 4096; var mfSize = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(captureUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &mfSize)
        ctx.captureABL = makeCaptureABL(maxFrames: maxFrames)
        ctx.captureBufSize = maxFrames
        var inputCB = AURenderCallbackStruct(inputProc: captureInputCallback, inputProcRefCon: ctxPtr)
        check(AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                   &inputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "capture SetInputCallback")
        guard check(AudioUnitInitialize(captureUnit), "capture AudioUnitInitialize") else {
            teardown(); throw SpatialEngineError.setupFailed("capture init")
        }

        // --- Playback unit (ring/mixer → real output) ---
        guard let playbackUnit = makeHALOutputUnit() else { teardown(); throw SpatialEngineError.setupFailed("playback unit") }
        ctx.playbackUnit = playbackUnit
        setEnableIO(playbackUnit, enable: 1, scope: kAudioUnitScope_Output, element: 0, label: "playback")
        setEnableIO(playbackUnit, enable: 0, scope: kAudioUnitScope_Input, element: 1, label: "playback")
        setCurrentDevice(playbackUnit, deviceID: outID, label: "playback")
        var playFmt = stereoFloat32Format()
        setStreamFormat(playbackUnit, fmt: &playFmt, scope: kAudioUnitScope_Input, element: 0, label: "playback")
        var playMax: UInt32 = 4096; var pmSize = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(playbackUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &playMax, &pmSize)

        // --- Spatial mixer ---
        if config.spatialize {
            let bed = config.sourceMode.isBed
            let spatialMax = max(playMax, ctx.captureBufSize, 4096)
            ctx.spatialBed = bed
            guard let mixer = makeSpatialMixer(
                ctxPtr: ctxPtr, maxFrames: spatialMax, bed: bed,
                algo: config.algorithm.rawValue, algoName: config.algorithm.label,
                outputType: config.outputType.rawValue, outputTypeName: config.outputType.label,
                hrtfMode: config.hrtfMode.rawValue, hrtfModeName: config.hrtfMode.label,
                headTrack: config.headTracking ? 1 : 0) else {
                teardown(); throw SpatialEngineError.setupFailed("spatial mixer")
            }
            let dmL = UnsafeMutablePointer<Float>.allocate(capacity: Int(spatialMax))
            let dmR = UnsafeMutablePointer<Float>.allocate(capacity: Int(spatialMax))
            dmL.initialize(repeating: 0, count: Int(spatialMax))
            dmR.initialize(repeating: 0, count: Int(spatialMax))
            ctx.dmL = dmL; ctx.dmR = dmR
            ctx.spatialMaxFrames = spatialMax
            ctx.spatialMixer = mixer
            applySourceParams(mixer: mixer)
            ctx.spatialize = true   // publish last
        }

        var renderCB = AURenderCallbackStruct(inputProc: playbackRenderCallback, inputProcRefCon: ctxPtr)
        check(AudioUnitSetProperty(playbackUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                   &renderCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "playback SetRenderCallback")
        guard check(AudioUnitInitialize(playbackUnit), "playback AudioUnitInitialize") else {
            teardown(); throw SpatialEngineError.setupFailed("playback init")
        }

        guard check(AudioOutputUnitStart(captureUnit), "captureUnit Start"),
              check(AudioOutputUnitStart(playbackUnit), "playbackUnit Start") else {
            teardown(); throw SpatialEngineError.setupFailed("unit start")
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        teardown()
        isRunning = false
    }

    private func resolveOutput(requested: AudioDeviceID?, atmosID: AudioDeviceID) throws -> AudioDeviceID {
        if let r = requested, r != atmosID, deviceHasChannels(r, scope: kAudioObjectPropertyScopeOutput) { return r }
        let def = defaultOutputDeviceID()
        if def != AudioDeviceID(kAudioObjectUnknown), def != atmosID,
           deviceHasChannels(def, scope: kAudioObjectPropertyScopeOutput) { return def }
        if let first = outputDevices().first { return first.id }
        throw SpatialEngineError.noOutputDevice
    }

    private func teardown() {
        guard let ctx else { return }
        if let c = ctx.captureUnit { AudioOutputUnitStop(c) }
        if let p = ctx.playbackUnit { AudioOutputUnitStop(p) }
        if let m = ctx.spatialMixer { AudioUnitUninitialize(m); AudioComponentInstanceDispose(m); ctx.spatialMixer = nil }
        if let c = ctx.captureUnit { AudioUnitUninitialize(c); AudioComponentInstanceDispose(c); ctx.captureUnit = nil }
        if let p = ctx.playbackUnit { AudioUnitUninitialize(p); AudioComponentInstanceDispose(p); ctx.playbackUnit = nil }
        ctx.dmL?.deallocate(); ctx.dmL = nil
        ctx.dmR?.deallocate(); ctx.dmR = nil
        if let abl = ctx.captureABL {
            for ch in 0..<abl.count { abl[ch].mData?.deallocate() }
            free(abl.unsafeMutablePointer)
            ctx.captureABL = nil
        }
        self.ctx = nil
    }

    // MARK: Live state + params

    /// Read+reset the peak meters and poll the live engine state. Call ~30 Hz.
    public func pollState() -> EngineState {
        var s = EngineState()
        s.running = isRunning
        guard isRunning, let ctx else { return s }
        s.outputDeviceName = deviceName(outputDeviceID)
        s.peakL = ctx.capturePeakL; ctx.capturePeakL = 0
        s.peakR = ctx.capturePeakR; ctx.capturePeakR = 0
        s.ringFill = ctx.ring.fill()
        s.totalCaptured = ctx.totalCaptured
        s.totalPlayed = ctx.totalPlayed
        if let mixer = ctx.spatialMixer {
            var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
            if AudioUnitGetProperty(mixer, kPropAnyInputUsingPersonalizedHRTF, kAudioUnitScope_Global, 0, &v, &sz) == noErr {
                s.personalizedHRTFEngaged = (v != 0)
            }
        }
        return s
    }

    /// Live-update the source position/gain (safe while running; AudioUnitSetParameter).
    public func updateSource(azimuth: Float? = nil, elevation: Float? = nil, distance: Float? = nil, gain: Float? = nil) {
        if let a = azimuth { config.azimuth = a }
        if let e = elevation { config.elevation = e }
        if let d = distance { config.distance = d }
        if let g = gain { config.gain = g }
        if let mixer = ctx?.spatialMixer { applySourceParams(mixer: mixer) }
    }

    private func applySourceParams(mixer: AudioUnit) {
        AudioUnitSetParameter(mixer, kParamAzimuth,   kAudioUnitScope_Input, 0, AudioUnitParameterValue(config.azimuth), 0)
        AudioUnitSetParameter(mixer, kParamElevation, kAudioUnitScope_Input, 0, AudioUnitParameterValue(config.elevation), 0)
        AudioUnitSetParameter(mixer, kParamDistance,  kAudioUnitScope_Input, 0, AudioUnitParameterValue(config.distance), 0)
        AudioUnitSetParameter(mixer, kParamGain,      kAudioUnitScope_Input, 0, AudioUnitParameterValue(config.gain), 0)
    }

    /// Apply a new config. Properties that require a graph rebuild (output type,
    /// HRTF mode, algorithm, source mode, head tracking) trigger a stop/start when
    /// running; live params (az/el/distance/gain) apply immediately.
    public func reconfigure(_ newConfig: SpatialConfig) throws {
        let needsRebuild = isRunning && (
            newConfig.spatialize != config.spatialize ||
            newConfig.sourceMode != config.sourceMode ||
            newConfig.outputType != config.outputType ||
            newConfig.hrtfMode != config.hrtfMode ||
            newConfig.algorithm != config.algorithm ||
            newConfig.headTracking != config.headTracking)
        if needsRebuild {
            let out = outputDeviceID
            stop()
            config = newConfig
            try start(outputDeviceID: out)
        } else {
            config = newConfig
            if let mixer = ctx?.spatialMixer { applySourceParams(mixer: mixer) }
        }
    }
}
