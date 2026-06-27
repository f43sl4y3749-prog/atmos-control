// atmos-control — SwiftUI menu-bar control app (Phase 3 MVP).
// Apple-native restraint; instrument-grade-but-calm. One accent = instrument cyan.

import SwiftUI
import AppKit

extension Color {
    /// The single accent: engaged/active state, source dot, power-on glow.
    static let instrument = Color(red: 0.34, green: 0.82, blue: 0.86)
}

@main
struct AtmosControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = EngineController()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(controller)
                .frame(width: 332)
        } label: {
            MenuBarGlyph(on: controller.isOn)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindow: NSWindow?
    private let previewController = EngineController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = ProcessInfo.processInfo.environment["ATMOS_PREVIEW"] == "1"
        NSApp.setActivationPolicy(preview ? .regular : .accessory)   // accessory = menu-bar agent
        guard preview else { return }

        // Dev-only: ATMOS_PREVIEW=1 opens the panel in a window for screenshotting.
        let host = NSHostingController(rootView: PanelView().environmentObject(previewController).frame(width: 332))
        host.sizingOptions = [.preferredContentSize]
        let win = NSWindow(contentViewController: host)
        win.title = "atmos-control"
        win.styleMask = [.titled, .closable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = win
    }
}

// MARK: - Menu-bar glyph (binaural mark; state-colored)

struct MenuBarGlyph: View {
    let on: Bool
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 22.0
            let cx = 11 * s, cy = 11 * s
            let col: Color = on ? .instrument : .primary

            func arc(_ r0: CGFloat, _ a0: Double, _ a1: Double) -> Path {
                var p = Path()
                let steps = 30
                let r = r0 * s
                for i in 0...steps {
                    let t = (a0 + (a1 - a0) * Double(i) / Double(steps)) * .pi / 180
                    let pt = CGPoint(x: cx + r * cos(t), y: cy + r * sin(t))   // y-down
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            let lw = (on ? 1.8 : 1.6) * s
            let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
            // right pair (east-facing), left pair (west-facing)
            for (r, a0, a1) in [(7.2, -52.0, 52.0), (4.8, -52.0, 52.0),
                                (7.2, 128.0, 232.0), (4.8, 128.0, 232.0)] {
                ctx.stroke(arc(r, a0, a1), with: .color(col), style: style)
            }
            let hr = (on ? 2.7 : 2.3) * s
            let head = Path(ellipseIn: CGRect(x: cx - hr, y: cy - hr, width: hr * 2, height: hr * 2))
            if on { ctx.fill(head, with: .color(col)) }
            else { ctx.stroke(head, with: .color(col), style: StrokeStyle(lineWidth: lw)) }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(on ? "atmos-control engine on" : "atmos-control engine off")
    }
}
