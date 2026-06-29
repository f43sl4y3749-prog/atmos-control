// PanelView — the compact menu-bar panel. Power + truthful status + the spatial
// visualizer + meters + quick controls. Apple-native restraint.

import SwiftUI
import AppKit
import SpatialEngine

struct PanelView: View {
    @Environment(EngineController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    /// Never let the panel run past the screen edge: cap at the visible frame
    /// (already excludes menu bar + Dock), leaving a little breathing room.
    private var maxPanelHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 24 }

    /// Deterministic per-state height — no measure⇄resize loop and (crucially) no second
    /// render pass. Clamped to the screen; the ScrollView absorbs any residual overflow.
    /// MUST key off the SAME predicate the content branch uses (`canRun`, see `content`):
    /// keying on `atmosPresent` pinned the full ~545pt surface into a 180pt frame in the
    /// default process-tap / no-driver state (atmosPresent == false but canRun == true),
    /// so the popover opened clipped at 332×180 — and forced AppKit to reconcile a
    /// 180-vs-545 frame/content mismatch every layout pass.
    private var panelHeight: CGFloat {
        guard controller.canRun else { return min(180, maxPanelHeight) }   // compact "driver missing" surface
        return min(545 + (controller.lastError != nil ? 30 : 0), maxPanelHeight)
    }

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)   // static when it fits, scrolls only when clamped
        .frame(width: 332, height: panelHeight)
        .tint(.instrument)   // unify on the single accent (segmented controls, switch, sliders)
        // Authoritative popover visibility for stopping the poll/motion (see bindPanelWindow);
        // onAppear/onDisappear remain a fallback in case the window signal is unavailable.
        .background(WindowAccessor { controller.bindPanelWindow($0) })
        .onAppear { controller.panelAppeared() }
        .onDisappear { controller.panelDisappeared() }
    }

    // The panel body — rendered once, live, inside the ScrollView.
    private var content: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            Divider()

            if !controller.canRun {
                driverMissing
            } else {
                statusStrip
                visualizerRow
                Divider()
                controls
            }

            if let err = controller.lastError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(14)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            MenuBarGlyph(on: controller.isOn).frame(width: 16, height: 16)
            Text("atmos-control").font(.system(size: 15, weight: .semibold))
            Spacer()
            Toggle("", isOn: Binding(get: { controller.isOn }, set: { _ in controller.toggle() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!controller.canRun)
                .help(controller.isOn ? "Stop routing system audio through the spatializer"
                                       : "Route all system audio through the spatializer")
        }
    }

    // MARK: Status

    private var statusStrip: some View {
        let hrtf = controller.hrtfStatus
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                StatusChip(icon: controller.isOn ? "waveform" : "pause", label: "Engine",
                           value: controller.isOn ? "On" : "Off", active: controller.isOn)
                StatusChip(icon: "headphones", label: "Output",
                           value: shortName(controller.outputName), active: controller.isOn)
            }
            HStack(spacing: 14) {
                StatusChip(icon: hrtf.engaged ? "person.fill.viewfinder" : "person.crop.circle",
                           label: "HRTF", value: hrtf.text, active: hrtf.engaged)
                StatusChip(icon: "gyroscope", label: "Head track",
                           value: controller.config.headTracking ? (controller.isOn ? "Active" : "On") : "Off",
                           active: controller.config.headTracking && controller.isOn)
            }
        }
    }

    private var visualizerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VisualizerView()
            // MeterView reads the controller directly so meter-rate writes invalidate ONLY
            // the meter, not PanelView's body (which would re-walk panelHeight/NSScreen).
            MeterView()
                .frame(width: 62, height: 150)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Output type", selection: rebuildBinding(\.outputType)) {
                ForEach(OutputType.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)

            Picker("Personalized HRTF", selection: rebuildBinding(\.hrtfMode)) {
                ForEach(HRTFMode.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)

            Toggle("Head tracking", isOn: rebuildBinding(\.headTracking))

            sliderRow("Elevation", value: liveBinding(\.elevation, apply: { controller.setSource(elevation: $0) }),
                      range: -90...90, unit: "°")
            sliderRow("Gain", value: liveBinding(\.gain, apply: { controller.setSource(gain: $0) }),
                      range: -20...6, unit: "dB")
        }
        .font(.system(size: 12))
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%+.0f%@", value.wrappedValue, unit))
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Spatial Audio · personalized binaural")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Button { openSettings() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("Settings — full control surface")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private var driverMissing: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Virtual audio driver not found", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            Text("Install the atmos-control HAL driver, then reopen.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Bindings

    /// Binding that mutates config and triggers a graph rebuild when running.
    private func rebuildBinding<T>(_ kp: WritableKeyPath<SpatialConfig, T>) -> Binding<T> {
        Binding(get: { controller.config[keyPath: kp] },
                set: { controller.config[keyPath: kp] = $0; controller.applyConfig() })
    }

    /// Binding for a live Float param (no rebuild), exposed as Double for Slider.
    private func liveBinding(_ kp: WritableKeyPath<SpatialConfig, Float>, apply: @escaping (Float) -> Void) -> Binding<Double> {
        Binding(get: { Double(controller.config[keyPath: kp]) }, set: { apply(Float($0)) })
    }

    private func shortName(_ s: String) -> String {
        s.replacingOccurrences(of: "Мария’s ", with: "").replacingOccurrences(of: "MacBook Air ", with: "")
    }
}

// MARK: - Status chip (icon + label + value; accent only when active, never color-alone)

struct StatusChip: View {
    let icon: String
    let label: String
    let value: String
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(active ? Color.instrument : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(value).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Window accessor (hands the popover's hosting NSWindow to the controller)

/// Reports its hosting NSWindow whenever the view enters/leaves a window. Used to drive
/// authoritative visibility for the MenuBarExtra(.window) popover: viewDidMoveToWindow(nil)
/// fires on dismissal even when SwiftUI never delivers .onDisappear. All callbacks happen on
/// the main thread (AppKit), so no cross-actor sending is involved.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let v = WindowReportingView()
        v.onWindow = onWindow
        return v
    }
    func updateNSView(_ nsView: WindowReportingView, context: Context) {
        nsView.onWindow = onWindow
    }
}

final class WindowReportingView: NSView {
    var onWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }
}
