// EngineController — @MainActor view-model bridging SwiftUI ↔ SpatialEngine.
// Owns the power on/off orchestration (default-output routing) and a poll timer
// that publishes live EngineState (peaks, 3116, ring fill) to the UI.

import SwiftUI
import CoreAudio
import SpatialEngine

@MainActor
final class EngineController: ObservableObject {
    @Published var isOn = false
    @Published var state = EngineState()
    @Published var config = SpatialConfig()
    @Published var lastError: String?
    @Published var atmosPresent = false
    @Published var outputName = "—"

    // Smoothed peak-hold for the meters (linear 0…1).
    @Published var meterL: Float = 0
    @Published var meterR: Float = 0
    @Published var peakHoldL: Float = 0
    @Published var peakHoldR: Float = 0

    private let engine = SpatialEngine()
    private var timer: Timer?
    private var savedDefault: AudioDeviceID?

    init() {
        atmosPresent = engine.atmosControlPresent()
        let cur = SpatialEngine.currentDefaultOutput()
        outputName = cur.name
    }

    // MARK: Power

    func toggle() { isOn ? powerOff() : powerOn() }

    func powerOn() {
        atmosPresent = engine.atmosControlPresent()
        guard let atmos = SpatialEngine.atmosControlDeviceID() else {
            lastError = "atmos-control device not found — is the HAL driver installed?"
            return
        }
        // The current default output is the real sink we route through (e.g. AirPods).
        let current = SpatialEngine.currentDefaultOutput()
        savedDefault = current.id
        let devices = engine.outputDevices()
        let real: AudioOutputDevice? = current.id == atmos
            ? devices.first(where: { $0.isAirPods }) ?? devices.first
            : devices.first(where: { $0.id == current.id })

        // Auto-match output type to the sink.
        if let r = real {
            config.outputType = r.isAirPods ? .headphones
                : (r.name.localizedCaseInsensitiveContains("headphone") ? .headphones : .builtInSpeakers)
            outputName = r.name
        }
        engine.config = config

        // Route system audio into atmos-control, then start the engine → real sink.
        SpatialEngine.setDefaultOutput(atmos)
        do {
            try engine.start(outputDeviceID: real?.id)
            isOn = true
            lastError = nil
            startPolling()
        } catch {
            lastError = "\(error)"
            if let s = savedDefault { SpatialEngine.setDefaultOutput(s) }   // restore on failure
            savedDefault = nil
        }
    }

    func powerOff() {
        stopPolling()
        engine.stop()
        if let s = savedDefault { SpatialEngine.setDefaultOutput(s); savedDefault = nil }
        isOn = false
        state = EngineState()
        meterL = 0; meterR = 0; peakHoldL = 0; peakHoldR = 0
    }

    // MARK: Config changes

    /// Apply a rebuild-class config change (output type, HRTF, algorithm, source mode,
    /// head tracking). Brief audio gap while running.
    func applyConfig() {
        guard isOn else { engine.config = config; return }
        do { try engine.reconfigure(config) }
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
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPolling() { timer?.invalidate(); timer = nil }

    private func tick() {
        let s = engine.pollState()
        state = s
        outputName = s.outputDeviceName.isEmpty ? outputName : s.outputDeviceName
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
