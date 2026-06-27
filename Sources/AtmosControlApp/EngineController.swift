// EngineController — @MainActor view-model bridging SwiftUI ↔ SpatialEngine.
// Owns the power on/off orchestration (default-output routing) and a poll timer
// that publishes live EngineState (peaks, 3116, ring fill) to the UI.

import SwiftUI
import CoreAudio
import SpatialEngine

/// How the engine captures system audio.
enum CaptureMode: String, CaseIterable, Identifiable {
    case processTap      // muting process tap; AirPods stay default → personalized HRTF + no black-hole
    case loopbackDriver  // hijack the default to the atmos-control loopback; generic HRTF only
    var id: String { rawValue }
    var label: String { self == .processTap ? "Personalized (tap)" : "Loopback driver" }
}

@MainActor
final class EngineController: ObservableObject {
    @Published var isOn = false
    @Published var state = EngineState()
    @Published var config = SpatialConfig()
    @Published var lastError: String?
    @Published var atmosPresent = false
    @Published var outputName = "—"

    // Output routing (settings window): the discovered real sinks + the user's choice.
    @Published var outputs: [AudioOutputDevice] = []
    @Published var selectedOutputID: AudioDeviceID?   // nil = follow current system default
    @Published var captureMode: CaptureMode = .processTap   // default: personalized, no black-hole

    // Smoothed peak-hold for the meters (linear 0…1).
    @Published var meterL: Float = 0
    @Published var meterR: Float = 0
    @Published var peakHoldL: Float = 0
    @Published var peakHoldR: Float = 0

    // Live head pose (radians yaw) for the radar; mirrors AirPods head tracking.
    @Published var headYaw: Double = 0
    @Published var headPoseLive = false

    private let engine = SpatialEngine()
    private let deviceMonitor = DeviceMonitor()
    private let motion = HeadphoneMotion()
    private let tap = ProcessTap()
    private var timer: Timer?
    private var savedDefault: AudioDeviceID?
    private var activeSinkID: AudioDeviceID?   // the real device the graph is rendering to
    private var activeCaptureID: AudioDeviceID?  // tap aggregate (tap mode) or nil (loopback)
    private var handlingChange = false
    private var visibleSurfaces = 0            // open windows observing live state

    /// The engine can run if either capture path is available. The process tap needs no
    /// driver, so the only hard requirement for loopback mode is the HAL device.
    var canRun: Bool { captureMode == .processTap || atmosPresent }

    init() {
        atmosPresent = engine.atmosControlPresent()
        let cur = SpatialEngine.currentDefaultOutput()
        outputName = cur.name
        outputs = engine.outputDevices()

        motion.onYaw = { [weak self] y in
            guard let self else { return }
            if abs(y - self.headYaw) > 0.008 { self.headYaw = y }   // ~0.5°: limit redraw churn
            if !self.headPoseLive { self.headPoseLive = true }
        }
        deviceMonitor.onChange = { [weak self] in self?.handleDeviceChange() }
        deviceMonitor.start()
    }

    // MARK: Output devices

    /// Re-enumerate the available real sinks; drop a selection that has vanished.
    func refreshDevices() {
        atmosPresent = engine.atmosControlPresent()
        outputs = engine.outputDevices()
        if let sel = selectedOutputID, !outputs.contains(where: { $0.id == sel }) {
            selectedOutputID = nil
        }
    }

    /// Sensible output-type default for a sink (used on power-on and device switch).
    private func outputType(for dev: AudioOutputDevice) -> OutputType {
        if dev.isAirPods { return .headphones }
        return dev.name.localizedCaseInsensitiveContains("headphone") ? .headphones : .builtInSpeakers
    }

    /// Pick which real sink to route through. nil = follow the system default.
    /// Swaps the playback graph live when running (atmos-control stays the default).
    func selectOutput(_ dev: AudioOutputDevice?) {
        selectedOutputID = dev?.id
        if let d = dev { outputName = d.name; config.outputType = outputType(for: d) }
        guard isOn else { engine.config = config; return }
        engine.stop()
        engine.config = config
        do { try engine.start(outputDeviceID: dev?.id, captureDeviceID: activeCaptureID); activeSinkID = dev?.id; lastError = nil }
        catch { lastError = "\(error)"; powerOff() }
    }

    // MARK: Device hot-swap

    /// CoreAudio device list or default-output changed. Keep the picker fresh and,
    /// if running, fail over when our real sink has vanished (e.g. AirPods unplugged).
    private func handleDeviceChange() {
        guard !handlingChange else { return }
        handlingChange = true
        defer { handlingChange = false }

        atmosPresent = engine.atmosControlPresent()
        let devices = engine.outputDevices()
        outputs = devices
        if let sel = selectedOutputID, !devices.contains(where: { $0.id == sel }) { selectedOutputID = nil }

        guard isOn else {
            let cur = SpatialEngine.currentDefaultOutput()
            if cur.id != SpatialEngine.atmosControlDeviceID() { outputName = cur.name }
            return
        }
        if let sink = activeSinkID, !devices.contains(where: { $0.id == sink }) {
            recoverFromLostSink(devices)
        }
    }

    /// Our render sink disappeared mid-session — fail over to another real device if one
    /// exists (atmos-control stays the capture default), else power down safely.
    private func recoverFromLostSink(_ devices: [AudioOutputDevice]) {
        selectedOutputID = nil
        guard let fallback = devices.first(where: { $0.isAirPods }) ?? devices.first(where: { !$0.isAirPods }) ?? devices.first else {
            lastError = "Output device disconnected — engine stopped."
            powerOff()
            return
        }
        engine.stop()
        config.outputType = outputType(for: fallback)
        engine.config = config
        do {
            try engine.start(outputDeviceID: fallback.id, captureDeviceID: activeCaptureID)
            activeSinkID = fallback.id
            outputName = fallback.name
            lastError = "Output changed — now routing to \(fallback.name)."
            updateActivity()
        } catch {
            lastError = "Output device lost — \(error)"
            powerOff()
        }
    }

    // MARK: Surface visibility

    /// Poll meters + run head-motion only while a window is actually on screen — the
    /// engine keeps spatializing when closed, but nobody's looking at the live readouts.
    /// (Counted because the panel and settings window can be open independently.)
    func surfaceAppeared()   { visibleSurfaces += 1; updateActivity() }
    func surfaceDisappeared() { visibleSurfaces = max(0, visibleSurfaces - 1); updateActivity() }
    private var panelVisible: Bool { visibleSurfaces > 0 }

    private func updateActivity() {
        if isOn && panelVisible { startPolling() } else { stopPolling() }
        syncMotion()
    }

    // MARK: Head-pose motion

    /// Run head-pose updates only while on, head-tracking enabled, AND a surface visible.
    /// (Real audio head-tracking is AUSpatialMixer property 3111 — independent of this.)
    private func syncMotion() {
        if isOn && config.headTracking && panelVisible && motion.isAvailable {
            motion.start()
        } else {
            motion.stop()
            headPoseLive = false
            headYaw = 0
        }
    }

    // MARK: Power

    func toggle() { isOn ? powerOff() : powerOn() }

    func powerOn() {
        atmosPresent = engine.atmosControlPresent()
        if captureMode == .processTap, startTapMode() { return }
        startLoopbackMode()   // explicit loopback, or process-tap fell back
    }

    /// Personalized capture via a muting process tap. AirPods stay the default output so
    /// property 3116 engages; we never hijack the default → no black-hole, nothing to restore.
    private func startTapMode() -> Bool {
        let devices = engine.outputDevices()
        outputs = devices
        let current = SpatialEngine.currentDefaultOutput()
        // Render to the current default (where 3116 keys) unless the user picked a sink.
        let real: AudioOutputDevice?
        if let sel = selectedOutputID, let d = devices.first(where: { $0.id == sel }) { real = d }
        else { real = devices.first(where: { $0.id == current.id }) ?? devices.first(where: { $0.isAirPods }) }

        do {
            let aggID = try tap.start(muted: true)
            if let r = real { config.outputType = outputType(for: r); outputName = r.name }
            engine.config = config
            try engine.start(outputDeviceID: real?.id, captureDeviceID: aggID)
            activeCaptureID = aggID
            activeSinkID = real?.id
            savedDefault = nil
            isOn = true
            lastError = nil
            updateActivity()
            return true
        } catch {
            tap.stop()
            lastError = "Personalized capture unavailable (\(error)) — using loopback."
            return false
        }
    }

    /// Loopback capture: hijack the system default to the atmos-control HAL device.
    /// Generic HRTF only (personalization blocked by the virtual default); restores on off.
    private func startLoopbackMode() {
        guard let atmos = SpatialEngine.atmosControlDeviceID() else {
            lastError = "atmos-control device not found — install the HAL driver, or use Personalized (tap) mode."
            return
        }
        let current = SpatialEngine.currentDefaultOutput()
        savedDefault = current.id
        let devices = engine.outputDevices()
        outputs = devices
        let real: AudioOutputDevice?
        if let sel = selectedOutputID, let d = devices.first(where: { $0.id == sel }) {
            real = d
        } else if current.id == atmos {
            real = devices.first(where: { $0.isAirPods }) ?? devices.first
        } else {
            real = devices.first(where: { $0.id == current.id })
        }
        if let r = real { config.outputType = outputType(for: r); outputName = r.name }
        engine.config = config

        SpatialEngine.setDefaultOutput(atmos)
        do {
            try engine.start(outputDeviceID: real?.id, captureDeviceID: nil)
            activeCaptureID = nil
            activeSinkID = real?.id ?? (current.id != atmos ? current.id : nil)
            isOn = true
            lastError = nil
            updateActivity()
        } catch {
            lastError = "\(error)"
            restoreSafeDefault()   // never leave the system default on the virtual sink
        }
    }

    func powerOff() {
        engine.stop()
        if tap.isActive { tap.stop() }
        if activeCaptureID == nil { restoreSafeDefault() } else { savedDefault = nil }  // only loopback hijacked the default
        isOn = false
        activeSinkID = nil
        activeCaptureID = nil
        state = EngineState()
        meterL = 0; meterR = 0; peakHoldL = 0; peakHoldR = 0
        updateActivity()
    }

    /// Switch the capture path (restarts the engine if running).
    func setCaptureMode(_ m: CaptureMode) {
        guard captureMode != m else { return }
        captureMode = m
        if isOn { powerOff(); powerOn() }
    }

    /// Restore the system default to a present, real (non-virtual) device. Prefers the
    /// saved pre-power-on default; falls back to built-in speakers / any real sink so we
    /// never strand the default on the atmos-control loopback (which black-holes audio).
    private func restoreSafeDefault() {
        let atmos = SpatialEngine.atmosControlDeviceID()
        let present = engine.outputDevices()
        if let s = savedDefault, s != atmos, present.contains(where: { $0.id == s }) {
            SpatialEngine.setDefaultOutput(s)
        } else if let speakers = present.first(where: { $0.name.localizedCaseInsensitiveContains("speaker") })
                    ?? present.first(where: { !$0.isAirPods }) ?? present.first {
            SpatialEngine.setDefaultOutput(speakers.id)
        }
        savedDefault = nil
    }

    // MARK: Config changes

    /// Apply a rebuild-class config change (output type, HRTF, algorithm, source mode,
    /// head tracking). Brief audio gap while running.
    func applyConfig() {
        guard isOn else { engine.config = config; return }
        do { try engine.reconfigure(config); updateActivity() }
        catch { lastError = "\(error)"; powerOff() }
    }

    /// Live source position/gain (no rebuild).
    func setSource(azimuth: Float? = nil, elevation: Float? = nil, distance: Float? = nil, gain: Float? = nil) {
        if let a = azimuth { config.azimuth = a }
        if let e = elevation { config.elevation = e }
        if let d = distance { config.distance = d }
        if let g = gain { config.gain = g }
        engine.updateSource(azimuth: azimuth, elevation: elevation, distance: distance, gain: gain)
    }

    // MARK: Polling

    private func startPolling() {
        guard timer == nil else { return }   // idempotent: don't restart on every activity change
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 1.0 / 30.0   // let the OS coalesce wake-ups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPolling() { timer?.invalidate(); timer = nil }

    private func tick() {
        let s = engine.pollState()
        state = s
        let nm = s.outputDeviceName
        if !nm.isEmpty && nm != outputName { outputName = nm }   // guard: avoid no-op publishes
        // Meter: fast attack to the new peak, gentle release; hold the peak marker.
        let releaseL = meterL * 0.82, releaseR = meterR * 0.82
        meterL = max(s.peakL, releaseL)
        meterR = max(s.peakR, releaseR)
        peakHoldL = max(peakHoldL * 0.985, s.peakL)
        peakHoldR = max(peakHoldR * 0.985, s.peakR)
    }

    // MARK: Derived UI state

    /// Truthful personalization status given the config + live 3116.
    var hrtfStatus: (text: String, engaged: Bool) {
        if !isOn { return ("Inactive", false) }
        if state.personalizedHRTFEngaged { return ("Personalized", true) }
        if config.outputType != .headphones { return ("Speaker virtual.", false) }
        return ("Generic HRTF", false)
    }
}

// dBFS helpers shared by the meters/readouts.
func linearToDb(_ x: Float) -> Float { x > 0 ? 20 * log10(x) : -120 }
