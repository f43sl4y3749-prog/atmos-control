// Ranges — the single source of truth for every editable parameter's range, default,
// and mono readout format. The panel radar/gauges and the settings sliders MUST share
// these so a value set on one surface never looks clipped or rescaled on the other (F5).

import SwiftUI
import SpatialEngine

/// Canonical parameter ranges + readouts. All `Double` for SwiftUI `Slider`.
enum Param {
    // Soundstage
    static let azimuth   = ParamSpec(range: -180...180, def:  0,   unit: "°",   fmt: "%+.0f")
    static let elevation = ParamSpec(range:  -90...90,  def:  0,   unit: "°",   fmt: "%+.0f")
    static let distance  = ParamSpec(range: 0.35...6,   def:  1.0, unit: " m",  fmt: "%.2f")
    static let gain      = ParamSpec(range:  -40...12,  def:  0,   unit: " dB", fmt: "%+.0f")
    static let width     = ParamSpec(range:    0...90,  def: 30,   unit: "°",   fmt: "%.0f")
    // Rendering (distance model)
    static let distanceRef   = ParamSpec(range: 0.1...4,   def: 0.3, unit: " m",  fmt: "%.2f")
    static let distanceMax   = ParamSpec(range: 1...20,    def: 6.0, unit: " m",  fmt: "%.1f")
    static let distanceAtten = ParamSpec(range: 0...60,    def: 40,  unit: " dB", fmt: "%.0f")
    // Reverb (E1)
    static let reverbBlend   = ParamSpec(range: 0...100,   def: 20,  unit: " %",  fmt: "%.0f")
    static let reverbGain    = ParamSpec(range: -40...12,  def: -3,  unit: " dB", fmt: "%+.0f")
}

struct ParamSpec {
    let range: ClosedRange<Double>
    let def: Double
    let unit: String
    let fmt: String
    func text(_ v: Double) -> String { String(format: fmt + "%@", v, unit) }
    func text(_ v: Float)  -> String { text(Double(v)) }
}

// MARK: - Capture choice (user-facing; maps onto CaptureMode + SourceRenderMode)

/// The three honest capture options the user chooses between (amendment D). Two of them
/// share the loopback engine path but differ in channel width; the engine still speaks in
/// `CaptureMode` (+ `SourceRenderMode`), which `EngineController` derives from this.
enum CaptureChoice: String, CaseIterable, Identifiable {
    case personalized    // process tap; AirPods stay default → personalized HRTF can engage
    case surround        // loopback, 7.1.4 — true multichannel, personalized profile unavailable
    case virtualStereo   // loopback, stereo — works with any output, generic binaural

    var id: String { rawValue }

    var label: String {
        switch self {
        case .personalized:  return "Personalized (headphones)"
        case .surround:      return "Surround 7.1.4"
        case .virtualStereo: return "Stereo (virtual device)"
        }
    }

    /// Always-visible honest trade-off shown under the selected option.
    var subtitle: String {
        switch self {
        case .personalized:
            return "Keeps your headphones as the system output so Apple personalized Spatial Audio can engage. No driver needed."
        case .surround:
            return "True multichannel from Apple Music (set Music ▸ Dolby Atmos to Automatic). Personalized spatial profile unavailable in this mode."
        case .virtualStereo:
            return "Routes all audio through the atmos-control virtual device. Works with any output, but rendering is generic (personalized HRTF can’t engage)."
        }
    }
}
