import SwiftUI

struct PlanTransform {
    var scale: CGFloat          // points per metre
    var origin: CGPoint         // screen position of plan (0, 0)

    func view(_ p: Vec2) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(p.x) * scale, y: origin.y + CGFloat(p.y) * scale)
    }
    func plan(_ q: CGPoint) -> Vec2 {
        Vec2(x: Double((q.x - origin.x) / scale), y: Double((q.y - origin.y) / scale))
    }
    static func fit(bounds: CGRect, size: CGSize, zoom: CGFloat, pan: CGSize) -> PlanTransform {
        let s0 = min(size.width / max(bounds.width, 0.1), size.height / max(bounds.height, 0.1)) * 0.92
        let s = max(s0 * zoom, 1)
        let cx = size.width / 2 + pan.width, cy = size.height / 2 + pan.height
        return PlanTransform(scale: s, origin: CGPoint(x: cx - bounds.midX * s, y: cy - bounds.midY * s))
    }
}

/// Top-down floor plan with heat map, measurement points and the live position.
struct PlanCanvas: View {
    let survey: Survey
    let metric: Metric
    let thresholds: Thresholds
    var heat: HeatLayer?
    var live: Vec2?
    var heading: Double = 0
    var selected: UUID?
    var showLabels = true
    var interactive = true
    var onTap: ((Vec2, CGFloat) -> Void)?

    @State var zoom: CGFloat = 1
    @State var pan: CGSize = .zero
    @GestureState var pinch: CGFloat = 1
    @GestureState var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let tf = PlanTransform.fit(bounds: survey.bounds(including: live), size: geo.size,
                                       zoom: zoom * pinch,
                                       pan: CGSize(width: pan.width + drag.width, height: pan.height + drag.height))
            Canvas { ctx, size in
                draw(&ctx, tf, size)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in onTap?(tf.plan(v.location), tf.scale) },
                     including: interactive ? .all : .none)
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in zoom = min(15, max(0.4, zoom * v.magnification)) },
                including: interactive ? .all : .none)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height },
                including: interactive ? .all : .none)
            .overlay(alignment: .bottomTrailing) {
                if interactive && (zoom != 1 || pan != .zero) {
                    Button { withAnimation { zoom = 1; pan = .zero } } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .padding(10).background(.regularMaterial, in: Circle())
                    }
                    .padding(12)
                }
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ tf: PlanTransform, _ size: CGSize) {
        let paper = Color(.secondarySystemBackground)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper))

        // Metre grid when there is no scanned plan
        if (survey.plan?.walls.isEmpty ?? true) && tf.scale > 6 {
            let tl = tf.plan(.zero), br = tf.plan(CGPoint(x: size.width, y: size.height))
            var grid = Path()
            var x = floor(tl.x)
            while x <= br.x { grid.move(to: tf.view(Vec2(x: x, y: tl.y))); grid.addLine(to: tf.view(Vec2(x: x, y: br.y))); x += 1 }
            var y = floor(tl.y)
            while y <= br.y { grid.move(to: tf.view(Vec2(x: tl.x, y: y))); grid.addLine(to: tf.view(Vec2(x: br.x, y: y))); y += 1 }
            ctx.stroke(grid, with: .color(.gray.opacity(0.18)), lineWidth: 0.5)
        }

        // Heat map
        if let heat {
            var h = ctx
            h.opacity = 0.6
            let o = tf.view(Vec2(x: Double(heat.rect.minX), y: Double(heat.rect.minY)))
            let r = CGRect(x: o.x, y: o.y, width: heat.rect.width * tf.scale, height: heat.rect.height * tf.scale)
            h.draw(Image(decorative: heat.image, scale: 1).interpolation(.high), in: r)
        }

        // Walls, with gaps cut for doors and openings
        if let plan = survey.plan, !plan.walls.isEmpty {
            let lw = max(2.5, 0.12 * tf.scale)
            func line(_ a: Vec2, _ b: Vec2) -> Path {
                var p = Path(); p.move(to: tf.view(a)); p.addLine(to: tf.view(b)); return p
            }
            ctx.drawLayer { layer in
                var walls = Path()
                for w in plan.walls { walls.addPath(line(w.a, w.b)) }
                layer.stroke(walls, with: .color(.primary), style: StrokeStyle(lineWidth: lw, lineCap: .square))
                var cut = layer
                cut.blendMode = .clear
                for o in plan.openings where o.kind != .window {
                    cut.stroke(line(o.a, o.b), with: .color(.black), lineWidth: lw + 3)
                }
            }
            for o in plan.openings {
                switch o.kind {
                case .door:
                    ctx.stroke(line(o.a, o.b), with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                case .window:
                    ctx.stroke(line(o.a, o.b), with: .color(.cyan), lineWidth: max(2, lw * 0.6))
                case .opening:
                    break
                }
            }
        }

        // Walked path
        if survey.trail.count > 1 {
            var p = Path()
            p.move(to: tf.view(survey.trail[0]))
            for v in survey.trail.dropFirst() { p.addLine(to: tf.view(v)) }
            ctx.stroke(p, with: .color(.blue.opacity(0.25)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }

        // Start point
        if let s = survey.start {
            ctx.draw(Text("🚩").font(.system(size: 20)), at: tf.view(s), anchor: .bottomLeading)
        }

        // Sample points
        for m in survey.points {
            let pt = tf.view(m.pos)
            let v = metric.value(m)
            let r: CGFloat = 8
            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: rect), with: .color(Ramp.color(thresholds.norm(metric, v))))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2)
            if m.id == selected {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(.blue), lineWidth: 2.5)
            }
            if showLabels {
                let txt = ctx.resolve(Text(m.failed ? "✕" : fmt(v)).font(.system(size: 11, weight: .bold)).foregroundColor(.black))
                let sz = txt.measure(in: CGSize(width: 200, height: 40))
                let box = CGRect(x: pt.x + 10, y: pt.y - sz.height / 2 - 1, width: sz.width + 8, height: sz.height + 2)
                ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(.white.opacity(0.85)))
                ctx.draw(txt, at: CGPoint(x: box.minX + 4, y: pt.y), anchor: .leading)
            }
        }

        // You are here
        if let live {
            let c = tf.view(live)
            var cone = Path()
            cone.move(to: c)
            cone.addArc(center: c, radius: 34, startAngle: .radians(heading - 0.45), endAngle: .radians(heading + 0.45), clockwise: false)
            cone.closeSubpath()
            ctx.fill(cone, with: .color(.blue.opacity(0.22)))
            let dot = CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)
            ctx.fill(Path(ellipseIn: dot), with: .color(.blue))
            ctx.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 3)
        }

        // Scale bar
        let choices: [Double] = [0.5, 1, 2, 5, 10, 20, 50]
        let metres = choices.first { CGFloat($0) * tf.scale >= 50 } ?? 50
        let len = CGFloat(metres) * tf.scale
        let y = size.height - 18
        var bar = Path()
        bar.move(to: CGPoint(x: 14, y: y - 4)); bar.addLine(to: CGPoint(x: 14, y: y))
        bar.addLine(to: CGPoint(x: 14 + len, y: y)); bar.addLine(to: CGPoint(x: 14 + len, y: y - 4))
        ctx.stroke(bar, with: .color(.primary), lineWidth: 2)
        ctx.draw(Text(metres < 1 ? "50 cm" : "\(Int(metres)) m").font(.caption2.bold()),
                 at: CGPoint(x: 14 + len / 2, y: y - 4), anchor: .bottom)
    }
}

struct LegendView: View {
    let metric: Metric
    let thresholds: Thresholds

    var body: some View {
        let r = thresholds.range(metric)
        VStack(alignment: .leading, spacing: 3) {
            Text("\(metric.title) (\(metric.unit))").font(.caption2.bold())
            LinearGradient(gradient: Ramp.gradient, startPoint: .leading, endPoint: .trailing)
                .frame(height: 7).clipShape(Capsule())
            HStack {
                Text((metric == .ping ? "≥" : "≤") + fmt(r.bad))
                Spacer()
                Text((metric == .ping ? "≤" : "≥") + fmt(r.good))
            }
            .font(.caption2).foregroundColor(.secondary)
        }
        .padding(8)
        .frame(width: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
