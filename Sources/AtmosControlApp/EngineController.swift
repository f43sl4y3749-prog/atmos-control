// EngineController — @MainActor view-model bridging SwiftUI ↔ SpatialEngine.
// Owns the power on/off orchestration (default-output routing) and a poll timer
// that publishes live engine telemetry (peaks, 3116, ring fill) to the UI.
//
// Uses the Observation framework (@Observable) rather than ObservableObject so SwiftUI
// tracks per-property reads: a meter-rate write no longer invalidates the whole tree,
// only the views that actually read the changed property.

import SwiftUI
import AppKit
import CoreAudio
import Observation
import SpatialEngine

/// How the engine captures system audio.
enum CaptureMode: String, CaseIterable, Identifiable {
    case processTap      // muting process tap; AirPods stay default → personalized HRTF + no black-hole
    case loopbackDriver  // hijack the default to the atmos-control loopback; generic HRTF only
    var id: String { rawValue }
    var label: String { self == .processTap ? "Personalized (tap)" : "Loopback driver" }
}

@MainActor
@Observable
final class EngineController {
    var isOn = false
    var config = SpatialConfig()
    var lastError: String?
    var atmosPresent = false
    var outputName = "—"

    // Live engine telemetry — individual tracked properties (was one EngineState struct)
    // so per-property observation pays off: PanelView reads only personalizedHRTFEngaged,
    // while ringFill/totals (SettingsView-only) no longer invalidate the panel each tick.
    var personalizedHRTFEngaged = false   // AUSpatialMixer property 3116
    var ringFill: UInt64 = 0
    var totalCaptured: UInt64 = 0
    var totalPlayed: UInt64 = 0

    // Output routing (settings window): the discovered real sinks + the user's choice.
    var outputs: [AudioOutputDevice] = []
    var selectedOutputID: AudioDeviceID?   // nil = follow current system default
    var captureMode: CaptureMode = .processTap   // default: personalized, no black-hole

    // Smoothed peak-hold for the meters (linear 0…1).
    var meterL: Float = 0
    var meterR: Float = 0
    var peakHoldL: Float = 0
    var peakHoldR: Float = 0

    // Live head pose (radians yaw) for the radar; mirrors AirPods head tracking.
    var headYaw: Double = 0
    var headPoseLive = false

    @ObservationIgnored private let engine = SpatialEngine()
    @ObservationIgnored private let deviceMonitor = DeviceMonitor()
    @ObservationIgnored private let motion = HeadphoneMotion()
    @ObservationIgnored private let tap = ProcessTap()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var savedDefault: AudioDeviceID?
    @ObservationIgnored private var activeSinkID: AudioDeviceID?   // real device the graph renders to
    @ObservationIgnored private var activeCaptureID: AudioDeviceID?  // tap aggregate (tap mode) or nil
    @ObservationIgnored private var handlingChange = false

    // Surface visibility. The MenuBarExtra(.window) popover's visibility is taken from its
    // NSWindow (bindPanelWindow) because SwiftUI .onDisappear is not reliably delivered when
    // that popover dismisses; the Settings Window's onAppear/onDisappear ARE reliable.
    @ObservationIgnored private var panelOnScreen = false
    @ObservationIgnored private var settingsOnScreen = false
    @ObservationIgnored private weak var panelWindow: NSWindow?   // weak: don't pin the hidden popover window
    @ObservationIgnored private var panelOcclusionObserver: NSObjectProtocol?

    /// The engine can run if either capture path is available. The process tap needs no
    /// driver, so the only hard requirement for loopback mode is the HAL device.
    var canRun: Bool { captureMode == .processTap || atmosPresent }

    /// The live controller. Production creates exactly one (the App's @State model); the
    /// app delegate uses this to run cleanup on quit / logout / shutdown without building a
    /// second engine. (Preview mode's throwaway controller may overwrite it — harmless,
    /// since preview never powers on.)
    static weak var shared: EngineController?

    init() {
        EngineController.shared = self
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
    /// Panel (MenuBarExtra popover) visibility — the authoritative signal is the popover
    /// NSWindow (see bindPanelWindow). onAppear/onDisappear are kept only as a fallback.
    func panelAppeared()    { panelOnScreen = true;  updateActivity() }
    func panelDisappeared() { panelOnScreen = false; updateActivity() }
    /// Settings is a normal Window scene whose onAppear/onDisappear are reliable.
    func settingsAppeared()    { settingsOnScreen = true;  updateActivity() }
    func settingsDisappeared() { settingsOnScreen = false; updateActivity() }

    private var anySurfaceVisible: Bool { panelOnScreen || settingsOnScreen }

    /// Bind the panel popover's hosting NSWindow (handed over by WindowAccessor when the
    /// view moves in/out of a window). Drives visibility from the window leaving the
    /// hierarchy AND from occlusion — so polling/motion stop the instant the popover is
    /// dismissed, even though SwiftUI does not reliably deliver .onDisappear for it.
    func bindPanelWindow(_ window: NSWindow?) {
        guard window !== panelWindow else { return }
        if let obs = panelOcclusionObserver {
            NotificationCenter.default.removeObserver(obs)
            panelOcclusionObserver = nil
        }
        panelWindow = window
        guard let window else { panelOnScreen = false; updateActivity(); return }
        // OR so a transient not-yet-on-screen occlusion read at bind time can't clobber a
        // `true` just set by onAppear; the observer below corrects it within a frame anyway.
        panelOnScreen = panelOnScreen || window.occlusionState.contains(.visible)
        panelOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Registered for this window only; read it back on the main actor (avoids
                // sending the non-Sendable Notification across the isolation boundary).
                let visible = self.panelWindow?.occlusionState.contains(.visible) ?? false
                if self.panelOnScreen != visible { self.panelOnScreen = visible; self.updateActivity() }
            }
        }
        updateActivity()
    }

    private func updateActivity() {
        if isOn && anySurfaceVisible { startPolling() } else { stopPolling() }
        syncMotion()
    }

    // MARK: Head-pose motion

    /// Run head-pose updates only while on, head-tracking enabled, AND a surface visible.
    /// (Real audio head-tracking is AUSpatialMixer property 3111 — independent of this.)
    private func syncMotion() {
        if isOn && config.headTracking && anySurfaceVisible && motion.isAvailable {
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
        // Restore the system default ONLY if loopback mode actually hijacked it (savedDefault
        // set). Idle/tap quit (no hijack) must NOT touch routing — otherwise the terminate hook
        // would yank the user's output to speakers on every quit even if we never powered on.
        if activeCaptureID == nil && savedDefault != nil { restoreSafeDefault() } else { savedDefault = nil }
        isOn = false
        activeSinkID = nil
        activeCaptureID = nil
        personalizedHRTFEngaged = false
        ringFill = 0; totalCaptured = 0; totalPlayed = 0
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
        // Fan the poll struct out into individual tracked properties, each guarded against
        // no-op writes. ringFill/totalCaptured/totalPlayed change every tick during playback
        // but are read ONLY by SettingsView, so they invalidate the panel only when it's open.
        if personalizedHRTFEngaged != s.personalizedHRTFEngaged { personalizedHRTFEngaged = s.personalizedHRTFEngaged }
        if ringFill != s.ringFill { ringFill = s.ringFill }
        if totalCaptured != s.totalCaptured { totalCaptured = s.totalCaptured }
        if totalPlayed != s.totalPlayed { totalPlayed = s.totalPlayed }
        let nm = s.outputDeviceName
        if !nm.isEmpty && nm != outputName { outputName = nm }   // guard: avoid no-op publishes
        // Meter: fast attack to the new peak, gentle release; hold the peak marker.
        // Snap sub-perceptual levels to exactly 0 and skip unchanged writes so the UI
        // QUIESCES in silence. Otherwise *0.82 / *0.985 only underflow to 0 after tens of
        // seconds, and every @Published write in between redraws the whole observing tree.
        let nL = settle(max(s.peakL, meterL * 0.82))
        let nR = settle(max(s.peakR, meterR * 0.82))
        let hL = settle(max(peakHoldL * 0.985, s.peakL))
        let hR = settle(max(peakHoldR * 0.985, s.peakR))
        if nL != meterL { meterL = nL }
        if nR != meterR { meterR = nR }
        if hL != peakHoldL { peakHoldL = hL }
        if hR != peakHoldR { peakHoldR = hR }
    }

    /// Snap a meter level below the −60 dBFS visual floor to exactly 0 so the decay
    /// reaches a fixed point in one tick instead of asymptotically republishing forever.
    @inline(__always) private func settle(_ x: Float) -> Float { x < 1e-3 ? 0 : x }

    // MARK: Derived UI state

    /// Truthful personalization status given the config + live 3116.
    var hrtfStatus: (text: String, engaged: Bool) {
        if !isOn { return ("Inactive", false) }
        if personalizedHRTFEngaged { return ("Personalized", true) }
        if config.outputType != .headphones { return ("Speaker virtual.", false) }
        return ("Generic HRTF", false)
    }
}

// dBFS helpers shared by the meters/readouts.
func linearToDb(_ x: Float) -> Float { x > 0 ? 20 * log10(x) : -120 }
