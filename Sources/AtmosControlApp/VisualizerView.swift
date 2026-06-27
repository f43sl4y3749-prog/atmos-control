// VisualizerView — the signature instrument. Top-down azimuth radar (draggable
// source) + a slim elevation gauge. Data-driven; no decorative motion.

import SwiftUI
import SpatialEngine

struct VisualizerView: View {
    @EnvironmentObject var controller: EngineController

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                RadarView()
                    .frame(width: 150, height: 150)
                ElevationGauge(elevation: controller.config.elevation)
                    .frame(width: 22, height: 150)
            }
            Text(readout)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var readout: String {
        let c = controller.config
        return String(format: "az %+.0f°  el %+.0f°  %.2f m  %+.0f dB",
                      c.azimuth, c.elevation, c.distance, c.gain)
    }
}

struct RadarView: View {
    @EnvironmentObject var controller: EngineController

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let R = min(rect.width, rect.height) / 2 * 0.92

            Canvas { ctx, size in
                let grid = Color.secondary
                // distance rings
                for f in [1.0, 0.66, 0.33] {
                    let rr = R * f
                    let ring = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                    ctx.stroke(ring, with: .color(grid.opacity(f == 1.0 ? 0.55 : 0.18)), lineWidth: 1)
                }
                // azimuth ticks at 0/±90/180
                for deg in stride(from: 0.0, to: 360.0, by: 90.0) {
                    let a = deg * .pi / 180
                    let p0 = CGPoint(x: c.x + (R - 6) * sin(a), y: c.y - (R - 6) * cos(a))
                    let p1 = CGPoint(x: c.x + R * sin(a), y: c.y - R * cos(a))
                    var tick = Path(); tick.move(to: p0); tick.addLine(to: p1)
                    ctx.stroke(tick, with: .color(grid.opacity(0.5)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
                // Head + forward indicators rotate with the live head pose (world stays
                // fixed); when no motion, yaw is 0 and they point straight up (front).
                let live = controller.headPoseLive
                let yaw = live ? controller.headYaw : 0
                ctx.drawLayer { layer in
                    layer.translateBy(x: c.x, y: c.y)
                    layer.rotate(by: .radians(yaw))
                    layer.translateBy(x: -c.x, y: -c.y)

                    // front chevron (accent) at the head's forward, just outside the ring
                    var chev = Path()
                    chev.move(to: CGPoint(x: c.x - 5, y: c.y - R - 1))
                    chev.addLine(to: CGPoint(x: c.x, y: c.y - R + 5))
                    chev.addLine(to: CGPoint(x: c.x + 5, y: c.y - R - 1))
                    layer.stroke(chev, with: .color(.instrument),
                                 style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                    // listener head + nose pointing forward
                    let headCol = live ? Color.instrument.opacity(0.9) : grid.opacity(0.85)
                    let head = Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6 + 1, width: 12, height: 12))
                    layer.fill(head, with: .color(headCol))
                    var nose = Path()
                    nose.move(to: CGPoint(x: c.x - 3.2, y: c.y - 4))
                    nose.addLine(to: CGPoint(x: c.x + 3.2, y: c.y - 4))
                    nose.addLine(to: CGPoint(x: c.x, y: c.y - 9.5))
                    layer.fill(nose.closedSubpath, with: .color(headCol))
                }

                // source dot (accent) + soft glow + ray
                let sp = sourcePoint(c: c, R: R, az: controller.config.azimuth, distance: controller.config.distance)
                var ray = Path(); ray.move(to: c); ray.addLine(to: sp)
                ctx.stroke(ray, with: .color(.instrument.opacity(0.25)), lineWidth: 1)
                let glow = Path(ellipseIn: CGRect(x: sp.x - 9, y: sp.y - 9, width: 18, height: 18))
                ctx.fill(glow, with: .color(.instrument.opacity(0.18)))
                let dot = Path(ellipseIn: CGRect(x: sp.x - 4, y: sp.y - 4, width: 8, height: 8))
                ctx.fill(dot, with: .color(.instrument))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let dx = v.location.x - c.x, dy = v.location.y - c.y
                        let az = atan2(dx, -dy) * 180 / .pi
                        let rho = min(hypot(dx, dy), R)
                        let dist = Float(rho / R) * 3
                        controller.setSource(azimuth: Float(az), distance: max(0.1, dist))
                    }
            )
            .accessibilityLabel("Spatial source position")
            .accessibilityValue(String(format: "azimuth %.0f degrees, distance %.1f meters",
                                        controller.config.azimuth, controller.config.distance))
        }
    }

    private func sourcePoint(c: CGPoint, R: CGFloat, az: Float, distance: Float) -> CGPoint {
        let rho = CGFloat(min(max(distance / 3, 0.06), 1)) * R
        let a = Double(az) * .pi / 180
        return CGPoint(x: c.x + rho * sin(a), y: c.y - rho * cos(a))
    }
}

struct ElevationGauge: View {
    let elevation: Float
    var body: some View {
        Canvas { ctx, size in
            let x = size.width / 2
            let top: CGFloat = 8, bot = size.height - 8, mid = (top + bot) / 2
            let grid = Color.secondary
            var track = Path(); track.move(to: CGPoint(x: x, y: top)); track.addLine(to: CGPoint(x: x, y: bot))
            ctx.stroke(track, with: .color(grid.opacity(0.5)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            for (y, w) in [(top, 5.0), (mid, 7.0), (bot, 5.0)] {
                var t = Path(); t.move(to: CGPoint(x: x - w, y: y)); t.addLine(to: CGPoint(x: x + w, y: y))
                ctx.stroke(t, with: .color(grid.opacity(0.5)), lineWidth: 1)
            }
            // source elevation marker
            let f = CGFloat((max(-90, min(90, elevation)) + 90) / 180)  // 0..1, +90 at top
            let y = bot - f * (bot - top)
            let dot = Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
            ctx.fill(dot, with: .color(.instrument))
        }
        .accessibilityLabel("Elevation")
        .accessibilityValue(String(format: "%.0f degrees", elevation))
    }
}

private extension Path {
    var closedSubpath: Path { var p = self; p.closeSubpath(); return p }
}
