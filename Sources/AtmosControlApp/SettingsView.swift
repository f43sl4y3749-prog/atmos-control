// SettingsView — the full AUSpatialMixer control surface. Native grouped Form
// (System-Settings idiom): routing, the complete spatialization flag set, live
// source params, and truthful telemetry (the real signals the OS hides).

import SwiftUI
import CoreAudio
import SpatialEngine

struct SettingsView: View {
    @EnvironmentObject var controller: EngineController

    var body: some View {
        Form {
            routing
            spatialization
            position
            telemetry
        }
        .formStyle(.grouped)
        .tint(.instrument)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 420, idealHeight: 620)
        .onAppear { controller.refreshDevices() }
    }

    // MARK: Routing

    private var routing: some View {
        Section {
            Picker("Output device", selection: outputBinding) {
                Text("Follow system default").tag(AudioDeviceID?.none)
                ForEach(controller.outputs) { d in
                    Text(d.name).tag(AudioDeviceID?.some(d.id))
                }
            }
            Picker("Output type", selection: rebuild(\.outputType)) {
                ForEach(OutputType.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Signal path") {
                Text(controller.isOn ? "system → atmos-control → \(controller.outputName)" : "idle")
                    .foregroundStyle(.secondary).font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
        } header: {
            Text("Routing")
        } footer: {
            Text("All system audio is captured by the virtual device, spatialized, then sent to the chosen sink.")
        }
    }

    // MARK: Spatialization

    private var spatialization: some View {
        Section("Spatialization") {
            Toggle("Spatialize", isOn: rebuild(\.spatialize))
            Group {
                Picker("Source mode", selection: rebuild(\.sourceMode)) {
                    ForEach(SourceRenderMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Algorithm", selection: rebuild(\.algorithm)) {
                    ForEach(SpatAlgorithm.allCases) { Text($0.label).tag($0) }
                }
                Picker("Personalized HRTF", selection: rebuild(\.hrtfMode)) {
                    ForEach(HRTFMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Head tracking", isOn: rebuild(\.headTracking))
            }
            .disabled(!controller.config.spatialize)
        }
    }

    // MARK: Source position (live params — no graph rebuild)

    private var position: some View {
        Section("Source position") {
            slider("Azimuth",   \.azimuth,   -180...180, "°",   live: { controller.setSource(azimuth: $0) })
            slider("Elevation", \.elevation,  -90...90,  "°",   live: { controller.setSource(elevation: $0) })
            slider("Distance",  \.distance,   0.1...4,   " m",  live: { controller.setSource(distance: $0) }, fmt: "%.2f")
            slider("Gain",      \.gain,       -40...12,  " dB", live: { controller.setSource(gain: $0) })
            Button("Reset to front") {
                controller.setSource(azimuth: 0, elevation: 0, distance: 1.0, gain: 0)
            }
            .disabled(!controller.config.spatialize)
        }
    }

    // MARK: Telemetry (truthful instruments)

    private var telemetry: some View {
        Section("Telemetry") {
            telemetryRow("Engine", controller.isOn ? "Running" : "Stopped", on: controller.isOn)
            telemetryRow("Personalized HRTF · 3116",
                         controller.state.personalizedHRTFEngaged ? "Engaged" : "Inactive",
                         on: controller.state.personalizedHRTFEngaged)
            telemetryRow("Peak L / R", peakText, on: controller.isOn)
            telemetryRow("Ring fill", "\(controller.state.ringFill) frames", on: controller.isOn)
            telemetryRow("Captured / Played",
                         "\(controller.state.totalCaptured) / \(controller.state.totalPlayed)",
                         on: controller.isOn)
        }
    }

    private func telemetryRow(_ label: String, _ value: String, on: Bool) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.callout, design: .monospaced)).monospacedDigit()
                .foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    private var peakText: String {
        guard controller.isOn else { return "—" }
        func db(_ x: Float) -> String { x > 0.0001 ? String(format: "%+.0f", linearToDb(x)) : "−∞" }
        return "\(db(controller.meterL)) / \(db(controller.meterR)) dB"
    }

    // MARK: Bindings

    /// Rebuild-class config change (output type, HRTF, algorithm, source mode, head tracking, spatialize).
    private func rebuild<T>(_ kp: WritableKeyPath<SpatialConfig, T>) -> Binding<T> {
        Binding(get: { controller.config[keyPath: kp] },
                set: { controller.config[keyPath: kp] = $0; controller.applyConfig() })
    }

    private var outputBinding: Binding<AudioDeviceID?> {
        Binding(get: { controller.selectedOutputID },
                set: { id in controller.selectOutput(controller.outputs.first(where: { $0.id == id })) })
    }

    @ViewBuilder
    private func slider(_ label: String, _ kp: WritableKeyPath<SpatialConfig, Float>,
                        _ range: ClosedRange<Double>, _ unit: String,
                        live: @escaping (Float) -> Void, fmt: String = "%+.0f") -> some View {
        let value = Binding<Double>(get: { Double(controller.config[keyPath: kp]) },
                                    set: { live(Float($0)) })
        LabeledContent(label) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                Text(String(format: fmt + "%@", value.wrappedValue, unit))
                    .font(.system(.callout, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
            }
        }
        .disabled(!controller.config.spatialize)
    }
}
