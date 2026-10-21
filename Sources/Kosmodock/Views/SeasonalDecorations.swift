import AppKit
import SwiftUI

// Seasonal styles draw their decorations (`DockSurface.decorations`) in one
// Canvas above the bar's surface and below its content, so icons stay on
// top. Everything is a function of time: no state, nothing to keep in sync.
// The Canvas reaches into the panel's transparent inset around the bar
// (`DockMetrics.shadowInset`) and never into the layout: the bar measures
// exactly as it would without it.

// MARK: - On the bar

extension View {
    /// The bar's seasonal decorations and the pets walking on top of it.
    func barLooks(surface: DockSurface) -> some View {
        modifier(BarLooks(surface: surface))
    }
}

private struct BarLooks: ViewModifier {
    @Environment(AppModel.self) private var model
    let surface: DockSurface

    func body(content: Content) -> some View {
        content
            // Behind the content, in front of the surface the bar adds after this.
            .background {
                SeasonalDecorationLayer(surface: surface, cornerRadius: CGFloat(surface.cornerRadius), isPaused: model.isDockHidden)
            }
            .overlay(alignment: .top) { RoamingPetsLayer() }
    }
}

/// Draws a surface's decorations around a bar of the view's size.
struct SeasonalDecorationLayer: View {
    var surface: DockSurface
    var cornerRadius: CGFloat
    /// Below 1 for the small bars of the style picker.
    var scale: CGFloat = 1
    /// `false` draws a still frame, as Reduce Motion does.
    var animates = true
    /// The dock is off-screen: nothing to animate.
    var isPaused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let decorations = surface.decorations
        if !decorations.isEmpty {
            let still = !animates || reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                || !decorations.contains(where: \.isAnimated)
            let reach = SeasonalPainter.reach * scale
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || isPaused)) { timeline in
                Canvas { context, size in
                    let painter = SeasonalPainter(
                        size: size,
                        bar: CGRect(x: reach, y: reach, width: max(0, size.width - reach * 2), height: max(0, size.height - reach * 2)),
                        radius: cornerRadius, s: scale,
                        t: still ? SeasonalPainter.stillTime : timeline.date.timeIntervalSinceReferenceDate
                    )
                    painter.draw(decorations, in: &context)
                }
            }
            .padding(-reach)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Settings › Appearance: a switch for each of the style's decorations.
struct SeasonalDecorationToggles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let theme = model.theme
        let own = theme.style.decorationOptions
        // Decorations added to config.json by hand get a switch too.
        let options = own + theme.surface.decorations.filter { !own.contains($0) }
        ForEach(options) { decoration in
            Toggle(decoration.title, isOn: binding(decoration))
        }
        if !options.isEmpty {
            Text("Decorations stand still with Reduce Motion on, and pause while the Dock is hidden.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(_ decoration: SeasonalDecoration) -> Binding<Bool> {
        Binding(
            get: { model.theme.surface.decorations.contains(decoration) },
            set: { isOn in
                model.configService.update { config in
                    var decorations = config.theme.surface.decorations.filter { $0 != decoration }
                    if isOn { decorations.append(decoration) }
                    config.theme.surface.decorations = SeasonalDecoration.normalized(decorations)
                }
            }
        )
    }
}

// MARK: - Painter

/// Draws decorations into a Canvas whose center holds the bar (`bar`).
/// `s` scales every length; `t` is the time in seconds.
struct SeasonalPainter {
    /// How far decorations reach past the bar, inside the panel's inset.
    static let reach: CGFloat = DockMetrics.shadowInset - 2
    /// The moment a still frame shows: snow and leaves mid-fall.
    static let stillTime: TimeInterval = 7.3
    /// Back to front.
    static let order: [SeasonalDecoration] = [
        .fog, .snow, .leaves, .cobwebs, .bats, .candyStripes, .icicles, .snowCap, .slime,
        .leafPile, .twinkleLights, .warmLights, .candyLights, .pumpkins, .ghosts, .candies,
    ]

    let size: CGSize
    let bar: CGRect
    let radius: CGFloat
    let s: CGFloat
    let t: TimeInterval

    func draw(_ decorations: [SeasonalDecoration], in context: inout GraphicsContext) {
        guard bar.width > 0, bar.height > 0 else { return }
        for decoration in Self.order where decorations.contains(decoration) {
            switch decoration {
            case .pumpkins: drawPumpkins(in: &context)
            case .bats: drawBats(in: &context)
            case .cobwebs: drawCobwebs(in: &context)
            case .fog: drawFog(in: &context)
            case .slime: drawSlime(in: &context)
            case .ghosts: drawGhosts(in: &context)
            case .leaves: drawFallingLeaves(in: &context)
            case .leafPile: drawLeafPile(in: &context)
            case .candies: drawCandies(in: &context)
            case .snow: drawSnow(in: &context)
            case .snowCap: drawSnowCap(in: &context)
            case .icicles: drawIcicles(in: &context)
            case .twinkleLights:
                drawLights(colors: Palette.twinkle, wire: Palette.pineWire, spacing: 16, in: &context) { i in
                    0.62 + 0.38 * sin(t * (1.4 + 1.6 * Self.noise(i, 31)) + Self.noise(i, 32) * 6.28)
                }
            case .warmLights:
                drawLights(colors: Palette.warm, wire: Palette.brownWire, spacing: 17, in: &context) { i in
                    0.78 + 0.22 * sin(t * 0.9 + Self.noise(i, 33) * 6.28)
                }
            case .candyLights:
                drawLights(colors: Palette.candy, wire: Palette.grayWire, spacing: 16, in: &context) { i in
                    // The two colors take turns.
                    0.62 + 0.38 * sin(t * 3 + Double(i) * .pi)
                }
            case .candyStripes: drawCandyStripes(in: &context)
            }
        }
    }

    // MARK: Helpers

    /// Pseudo-random 0..<1, always the same for the same arguments.
    static func noise(_ i: Int, _ salt: Double) -> Double {
        let value = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }

    private func rand(_ i: Int, _ salt: Double) -> CGFloat { CGFloat(Self.noise(i, salt)) }

    /// `value` wrapped into 0..<length.
    private func wrap(_ value: Double, _ length: Double) -> Double {
        guard length > 0 else { return 0 }
        let r = value.truncatingRemainder(dividingBy: length)
        return r < 0 ? r + length : r
    }

    private var cornerRadius: CGFloat { min(radius, bar.height / 2, bar.width / 2) }

    /// The bar's top edge at `x`, following its rounded corners.
    private func top(_ x: CGFloat) -> CGFloat {
        let r = cornerRadius
        let dx: CGFloat
        if x < bar.minX + r {
            dx = bar.minX + r - x
        } else if x > bar.maxX - r {
            dx = x - (bar.maxX - r)
        } else {
            return bar.minY
        }
        let clamped = min(dx, r)
        return bar.minY + r - sqrt(max(0, r * r - clamped * clamped))
    }

    private func circle(_ center: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    private func glow(_ color: Color, at center: CGPoint, radius r: CGFloat, opacity: Double, in context: inout GraphicsContext) {
        context.fill(circle(center, r), with: .radialGradient(
            Gradient(colors: [color.opacity(opacity), color.opacity(0)]), center: center, startRadius: 0, endRadius: r
        ))
    }

    private func point(on a: CGPoint, _ control: CGPoint, _ b: CGPoint, at f: CGFloat) -> CGPoint {
        let g = 1 - f
        return CGPoint(
            x: g * g * a.x + 2 * g * f * control.x + f * f * b.x,
            y: g * g * a.y + 2 * g * f * control.y + f * f * b.y
        )
    }

    /// A wire draped in swags along the top edge, and the points bulbs hang from.
    private func lightString(spacing: CGFloat) -> (wire: Path, bulbs: [CGPoint]) {
        let inset = max(cornerRadius * 0.55, 6 * s)
        let x0 = bar.minX + inset
        let x1 = bar.maxX - inset
        guard x1 > x0 else { return (Path(), []) }
        let swags = max(1, Int(((x1 - x0) / (spacing * s * 2)).rounded()))
        let width = (x1 - x0) / CGFloat(swags)
        var wire = Path()
        var bulbs: [CGPoint] = []
        for k in 0..<swags {
            let ax = x0 + CGFloat(k) * width
            let a = CGPoint(x: ax, y: top(ax) - 2.5 * s)
            let b = CGPoint(x: ax + width, y: top(ax + width) - 2.5 * s)
            let control = CGPoint(x: (a.x + b.x) / 2, y: max(a.y, b.y) + 6 * s)
            if k == 0 { wire.move(to: a) }
            wire.addQuadCurve(to: b, control: control)
            bulbs.append(point(on: a, control, b, at: 0.28))
            bulbs.append(point(on: a, control, b, at: 0.72))
        }
        return (wire, bulbs)
    }

    // MARK: Lights

    private func drawLights(colors: [Color], wire wireColor: Color, spacing: CGFloat, in context: inout GraphicsContext, brightness: (Int) -> Double) {
        let string = lightString(spacing: spacing)
        context.stroke(string.wire, with: .color(wireColor), lineWidth: max(0.5, 0.9 * s))
        for (i, p) in string.bulbs.enumerated() {
            let color = colors[i % colors.count]
            let lit = min(1, max(0, brightness(i)))
            let bulb = CGRect(x: p.x - 1.9 * s, y: p.y + 1.1 * s, width: 3.8 * s, height: 5.4 * s)
            let center = CGPoint(x: bulb.midX, y: bulb.midY)
            glow(color, at: center, radius: 7.5 * s, opacity: 0.6 * lit, in: &context)
            context.fill(Path(ellipseIn: bulb), with: .color(color.opacity(0.4 + 0.6 * lit)))
            context.fill(
                Path(ellipseIn: CGRect(x: bulb.minX + 0.7 * s, y: bulb.minY + 1.1 * s, width: 1.1 * s, height: 1.7 * s)),
                with: .color(.white.opacity(0.55 * lit))
            )
            context.fill(
                Path(roundedRect: CGRect(x: p.x - 1.2 * s, y: p.y - 0.3 * s, width: 2.4 * s, height: 1.9 * s), cornerRadius: 0.5 * s),
                with: .color(wireColor)
            )
        }
    }

    private func drawPumpkins(in context: inout GraphicsContext) {
        let string = lightString(spacing: 13)
        context.stroke(string.wire, with: .color(Palette.vineWire), lineWidth: max(0.5, 0.9 * s))
        for (i, p) in string.bulbs.enumerated() where i % 2 == 0 || string.bulbs.count < 6 {
            let flicker = 0.72 + 0.28 * sin(t * 7 + Double(i) * 1.7) * sin(t * 3.1 + Double(i))
            let w = 10 * s
            let h = 8 * s
            let body = CGRect(x: p.x - w / 2, y: p.y + 1.6 * s, width: w, height: h)
            let center = CGPoint(x: body.midX, y: body.midY)
            glow(Palette.pumpkinGlow, at: center, radius: 10 * s, opacity: 0.5 * flicker, in: &context)
            let lobe = CGRect(x: body.minX, y: body.minY, width: w * 0.6, height: h)
            context.fill(Path(ellipseIn: lobe), with: .color(Palette.pumpkinDark))
            context.fill(Path(ellipseIn: lobe.offsetBy(dx: w * 0.4, dy: 0)), with: .color(Palette.pumpkinDark))
            context.fill(Path(ellipseIn: body.insetBy(dx: w * 0.2, dy: 0)), with: .color(Palette.pumpkin))
            context.fill(
                Path(roundedRect: CGRect(x: center.x - 0.7 * s, y: body.minY - 1.7 * s, width: 1.4 * s, height: 2.3 * s), cornerRadius: 0.5 * s),
                with: .color(Palette.stem)
            )
            // The carved face, lit from inside.
            var face = Path()
            for side in [-1.0, 1.0] as [CGFloat] {
                let eye = CGPoint(x: center.x + side * 1.8 * s, y: center.y - 0.9 * s)
                face.move(to: CGPoint(x: eye.x - 0.85 * s, y: eye.y + 0.6 * s))
                face.addLine(to: CGPoint(x: eye.x + 0.85 * s, y: eye.y + 0.6 * s))
                face.addLine(to: CGPoint(x: eye.x, y: eye.y - 0.8 * s))
                face.closeSubpath()
            }
            let mouthY = center.y + 1.3 * s
            face.move(to: CGPoint(x: center.x - 2.6 * s, y: mouthY - 0.4 * s))
            for k in 1...4 {
                let x = center.x - 2.6 * s + CGFloat(k) * 1.3 * s
                face.addLine(to: CGPoint(x: x, y: mouthY + (k % 2 == 1 ? 0.5 : -0.4) * s))
            }
            face.addQuadCurve(to: CGPoint(x: center.x - 2.6 * s, y: mouthY - 0.4 * s), control: CGPoint(x: center.x, y: mouthY + 2.4 * s))
            face.closeSubpath()
            context.fill(face, with: .color(Palette.candleLight.opacity(0.5 + 0.5 * flicker)))
        }
    }

    private func drawGhosts(in context: inout GraphicsContext) {
        let inset = max(cornerRadius * 0.6, 8 * s)
        let span = bar.width - inset * 2
        guard span > 0 else { return }
        let count = max(2, Int(span / (36 * s)))
        let step = span / CGFloat(count)
        for i in 0..<count {
            let phase = Self.noise(i, 3) * 6.28
            let x = bar.minX + inset + step * (CGFloat(i) + 0.5) + 1.5 * s * CGFloat(sin(t * 0.9 + phase))
            let bob = 1.7 * s * CGFloat(sin(t * 1.7 + phase))
            let w = 7.4 * s
            let h = 9 * s
            let rect = CGRect(x: x - w / 2, y: top(x) + 1.5 * s + bob - h, width: w, height: h)
            glow(Palette.ghostGlow, at: CGPoint(x: rect.midX, y: rect.midY), radius: 9 * s, opacity: 0.4, in: &context)
            var ghost = Path()
            ghost.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            ghost.addLine(to: CGPoint(x: rect.minX, y: rect.minY + w / 2))
            ghost.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            ghost.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + w / 2), control: CGPoint(x: rect.maxX, y: rect.minY))
            ghost.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            // A wavy hem that ripples.
            let ripple = CGFloat(sin(t * 4 + phase)) * 0.8 * s
            for k in 0..<3 {
                let x0 = rect.maxX - CGFloat(k) * w / 3
                let x1 = x0 - w / 3
                ghost.addQuadCurve(to: CGPoint(x: x1, y: rect.maxY), control: CGPoint(x: (x0 + x1) / 2, y: rect.maxY - 2.2 * s + (k % 2 == 0 ? ripple : -ripple)))
            }
            ghost.closeSubpath()
            context.fill(ghost, with: .color(Palette.ghost.opacity(0.9)))
            for side in [-1.0, 1.0] as [CGFloat] {
                context.fill(
                    Path(ellipseIn: CGRect(x: rect.midX + side * 1.5 * s - 0.65 * s, y: rect.minY + 2.6 * s, width: 1.3 * s, height: 1.8 * s)),
                    with: .color(Palette.ink)
                )
            }
            context.fill(circle(CGPoint(x: rect.midX, y: rect.minY + 5.6 * s), 0.7 * s), with: .color(Palette.ink.opacity(0.8)))
        }
    }

    // MARK: Halloween

    private func drawBats(in context: inout GraphicsContext) {
        let count = min(5, max(2, Int(bar.width / (230 * s))))
        for i in 0..<count {
            let phase = Self.noise(i, 11) * 6.28
            let speed = 0.09 + 0.07 * Self.noise(i, 12)
            let x = bar.minX + bar.width * (0.5 + 0.46 * CGFloat(sin(t * speed + phase)))
            let y = bar.minY - (11 + 5 * rand(i, 13)) * s + 2.5 * s * CGFloat(sin(t * 0.8 + phase * 2))
            let flap = CGFloat(sin(t * 13 + phase * 3))
            drawBat(at: CGPoint(x: x, y: y), span: (5.5 + 1.5 * rand(i, 14)) * s, flap: flap, in: &context)
        }
    }

    private func drawBat(at c: CGPoint, span w: CGFloat, flap f: CGFloat, in context: inout GraphicsContext) {
        let u = s
        var bat = Path()
        for side in [-1.0, 1.0] as [CGFloat] {
            bat.move(to: CGPoint(x: c.x + side * 0.8 * u, y: c.y - 0.7 * u))
            bat.addLine(to: CGPoint(x: c.x + side * w * 0.55, y: c.y - (1.1 + 2 * f) * u))
            bat.addLine(to: CGPoint(x: c.x + side * w, y: c.y - (0.5 + 2.8 * f) * u))
            bat.addQuadCurve(to: CGPoint(x: c.x + side * w * 0.68, y: c.y + (0.7 - 1.5 * f) * u), control: CGPoint(x: c.x + side * w * 0.9, y: c.y + (0.2 - 1.6 * f) * u))
            bat.addQuadCurve(to: CGPoint(x: c.x + side * w * 0.38, y: c.y + (1 - 0.8 * f) * u), control: CGPoint(x: c.x + side * w * 0.56, y: c.y + (0.1 - 0.8 * f) * u))
            bat.addQuadCurve(to: CGPoint(x: c.x + side * 0.8 * u, y: c.y + 1 * u), control: CGPoint(x: c.x + side * w * 0.22, y: c.y + 0.3 * u))
            bat.closeSubpath()
        }
        bat.addEllipse(in: CGRect(x: c.x - 1.3 * u, y: c.y - 1.5 * u, width: 2.6 * u, height: 3.4 * u))
        bat.addEllipse(in: CGRect(x: c.x - 1.15 * u, y: c.y - 3.1 * u, width: 2.3 * u, height: 2.2 * u))
        for side in [-1.0, 1.0] as [CGFloat] {
            bat.move(to: CGPoint(x: c.x + side * 0.4 * u, y: c.y - 2.8 * u))
            bat.addLine(to: CGPoint(x: c.x + side * 1.1 * u, y: c.y - 3.9 * u))
            bat.addLine(to: CGPoint(x: c.x + side * 1.1 * u, y: c.y - 2.4 * u))
            bat.closeSubpath()
        }
        context.fill(bat, with: .color(Palette.bat))
        context.stroke(bat, with: .color(Palette.pumpkin.opacity(0.35)), lineWidth: max(0.3, 0.4 * s))
        for side in [-1.0, 1.0] as [CGFloat] {
            context.fill(circle(CGPoint(x: c.x + side * 0.45 * u, y: c.y - 2.1 * u), 0.32 * u), with: .color(Palette.candleLight))
        }
    }

    private func drawCobwebs(in context: inout GraphicsContext) {
        let r = 18 * s
        let k = cornerRadius * 0.29
        let left = CGPoint(x: bar.minX + k, y: bar.minY + k)
        let right = CGPoint(x: bar.maxX - k, y: bar.minY + k)
        drawWeb(center: left, from: .pi * 0.92, to: .pi * 1.58, radius: r, in: &context)
        drawWeb(center: right, from: .pi * 1.42, to: .pi * 2.08, radius: r, in: &context)
        // A spider dangling from the right one, going up and down its thread.
        let angle = Double.pi * 1.86
        let anchor = CGPoint(x: right.x + r * 0.8 * CGFloat(cos(angle)), y: right.y + r * 0.8 * CGFloat(sin(angle)))
        let spider = CGPoint(x: anchor.x, y: bar.minY + (8 + 4 * CGFloat(sin(t * 1.1))) * s)
        var thread = Path()
        thread.move(to: anchor)
        thread.addLine(to: spider)
        context.stroke(thread, with: .color(Palette.web.opacity(0.7)), lineWidth: max(0.35, 0.5 * s))
        drawSpider(at: spider, wiggle: CGFloat(sin(t * 6)), in: &context)
    }

    private func drawWeb(center: CGPoint, from start: Double, to end: Double, radius r: CGFloat, in context: inout GraphicsContext) {
        let threads = 6
        let angles = (0..<threads).map { start + (end - start) * Double($0) / Double(threads - 1) }
        var web = Path()
        for angle in angles {
            web.move(to: center)
            web.addLine(to: CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle))))
        }
        for ring in [0.36, 0.64, 0.92] as [CGFloat] {
            let points = angles.map { CGPoint(x: center.x + r * ring * CGFloat(cos($0)), y: center.y + r * ring * CGFloat(sin($0))) }
            web.move(to: points[0])
            for j in 1..<points.count {
                let a = points[j - 1]
                let b = points[j]
                // Each strand sags toward the center.
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let control = CGPoint(x: mid.x + (center.x - mid.x) * 0.2, y: mid.y + (center.y - mid.y) * 0.2)
                web.addQuadCurve(to: b, control: control)
            }
        }
        context.stroke(web, with: .color(Palette.web.opacity(0.55)), lineWidth: max(0.35, 0.55 * s))
    }

    private func drawSpider(at c: CGPoint, wiggle: CGFloat, in context: inout GraphicsContext) {
        var legs = Path()
        for side in [-1.0, 1.0] as [CGFloat] {
            for k in 0..<4 {
                let row = CGFloat(k) - 1.5
                let hip = CGPoint(x: c.x + side * 1.2 * s, y: c.y + row * 0.9 * s)
                let knee = CGPoint(x: c.x + side * 3.2 * s, y: c.y + (row * 1.3 - 1.6 + (k % 2 == 0 ? wiggle : -wiggle) * 0.4) * s)
                let foot = CGPoint(x: c.x + side * 4.4 * s, y: c.y + (row * 1.7 + 0.6) * s)
                legs.move(to: hip)
                legs.addLine(to: knee)
                legs.addLine(to: foot)
            }
        }
        context.stroke(legs, with: .color(Palette.web.opacity(0.85)), lineWidth: max(0.4, 0.6 * s))
        let body = Path(ellipseIn: CGRect(x: c.x - 2 * s, y: c.y - 1.6 * s, width: 4 * s, height: 4.6 * s))
        let head = circle(CGPoint(x: c.x, y: c.y - 2.2 * s), 1.4 * s)
        for part in [body, head] {
            context.fill(part, with: .color(Palette.spider))
            context.stroke(part, with: .color(Palette.web.opacity(0.5)), lineWidth: max(0.3, 0.45 * s))
        }
        for side in [-1.0, 1.0] as [CGFloat] {
            context.fill(circle(CGPoint(x: c.x + side * 0.5 * s, y: c.y - 2.4 * s), 0.3 * s), with: .color(Palette.candleLight))
        }
    }

    // MARK: Haunted Night

    private func drawFog(in context: inout GraphicsContext) {
        let span = Double(size.width) + 120 * Double(s)
        let count = Int(size.width / (60 * s)) + 4
        for i in 0..<count {
            let w = (60 + 50 * rand(i, 41)) * s
            let h = (16 + 12 * rand(i, 42)) * s
            let direction: Double = i % 2 == 0 ? 1 : -1
            let drift = (3 + 4 * Self.noise(i, 43)) * Double(s) * direction
            let x = CGFloat(wrap(Self.noise(i, 44) * span + t * drift, span)) - 60 * s
            let period = 9 + 6 * Self.noise(i, 45)
            let u = wrap(t + Self.noise(i, 46) * period, period) / period
            let rise = bar.height * 0.9 + 10 * s
            let y = bar.maxY + 8 * s - CGFloat(u) * rise
            let opacity = 0.34 * sin(Double.pi * u)
            var blob = context
            blob.translateBy(x: x, y: y)
            blob.scaleBy(x: 1, y: h / w)
            blob.fill(circle(.zero, w / 2), with: .radialGradient(
                Gradient(colors: [Palette.fog.opacity(opacity), Palette.fog.opacity(0)]), center: .zero, startRadius: 0, endRadius: w / 2
            ))
        }
    }

    private func drawSlime(in context: inout GraphicsContext) {
        let x0 = bar.minX + 1 * s
        let x1 = bar.maxX - 1 * s
        var band = Path()
        band.move(to: CGPoint(x: x0, y: top(x0) - 0.6 * s))
        var x = x0
        while x < x1 {
            x = min(x1, x + 2 * s)
            band.addLine(to: CGPoint(x: x, y: top(x) - 0.6 * s))
        }
        while x > x0 {
            x = max(x0, x - 2 * s)
            band.addLine(to: CGPoint(x: x, y: top(x) + (1.7 + 0.7 * sin(x / s * 0.35 + 1)) * s))
        }
        band.closeSubpath()
        let shade = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Palette.slime, Palette.slimeDark]),
            startPoint: CGPoint(x: 0, y: bar.minY - 1 * s), endPoint: CGPoint(x: 0, y: bar.minY + 9 * s)
        )
        context.fill(band, with: shade)
        var dx = x0 + 7 * s
        var i = 0
        while dx < x1 - 7 * s {
            let w = (2.2 + 1.6 * rand(i, 21)) * s
            let length = (3 + 7 * rand(i, 22)) * s + 1.5 * s * CGFloat(sin(t * 0.7 + Self.noise(i, 23) * 6.28))
            let root = top(dx) + 0.5 * s
            var drip = Path(roundedRect: CGRect(x: dx - w / 2, y: root, width: w, height: length), cornerRadius: w / 2)
            drip.addEllipse(in: CGRect(x: dx - w * 0.62, y: root + length - w * 0.62, width: w * 1.24, height: w * 1.24))
            context.fill(drip, with: shade)
            context.fill(
                Path(ellipseIn: CGRect(x: dx - w * 0.38, y: root + length - w * 0.4, width: w * 0.36, height: w * 0.42)),
                with: .color(.white.opacity(0.45))
            )
            // Now and then a drop falls off the tip.
            if Self.noise(i, 24) > 0.5 {
                let period = 2.6 + 2.4 * Self.noise(i, 25)
                let u = wrap(t + Self.noise(i, 26) * period, period) / period
                if u > 0.55 {
                    let fall = CGFloat((u - 0.55) / 0.45)
                    let y = root + length + w * 0.7 + fall * fall * 16 * s
                    if y < bar.maxY + 6 * s {
                        context.fill(circle(CGPoint(x: dx, y: y), w * 0.38), with: .color(Palette.slime.opacity(Double(1 - fall))))
                    }
                }
            }
            dx += (12 + 20 * rand(i, 27)) * s
            i += 1
        }
    }

    // MARK: Autumn

    private func leaf(at center: CGPoint, length: CGFloat, angle: Double) -> Path {
        let half = length / 2
        var leaf = Path()
        leaf.move(to: CGPoint(x: -half, y: 0))
        leaf.addQuadCurve(to: CGPoint(x: half, y: 0), control: CGPoint(x: -half * 0.1, y: -length * 0.56))
        leaf.addQuadCurve(to: CGPoint(x: -half, y: 0), control: CGPoint(x: -half * 0.1, y: length * 0.56))
        leaf.closeSubpath()
        leaf.move(to: CGPoint(x: -half * 1.25, y: 0))
        leaf.addLine(to: CGPoint(x: half * 0.7, y: 0))
        return leaf.applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
    }

    private func drawLeaf(at center: CGPoint, length: CGFloat, angle: Double, color: Color, opacity: Double = 1, in context: inout GraphicsContext) {
        let path = leaf(at: center, length: length, angle: angle)
        context.fill(path, with: .color(color.opacity(opacity)))
        context.stroke(path, with: .color(Palette.leafVein.opacity(0.55 * opacity)), lineWidth: max(0.3, 0.45 * s))
    }

    private func drawFallingLeaves(in context: inout GraphicsContext) {
        let count = max(4, Int(size.width / (70 * s)))
        for i in 0..<count {
            let speed = (4 + 4 * Self.noise(i, 51)) * Double(s)
            let phase = Self.noise(i, 52) * 6.28
            let x = rand(i, 53) * size.width + 7 * s * CGFloat(sin(t * 0.8 + phase))
            let floor = x > bar.minX && x < bar.maxX ? top(x) : size.height
            let y = CGFloat(wrap(t * speed + Self.noise(i, 54) * Double(floor), Double(floor)))
            let fade = Double(min(1, y / (5 * s), (floor - y) / (4 * s)))
            drawLeaf(
                at: CGPoint(x: x, y: y), length: (8 + 3 * rand(i, 55)) * s,
                angle: phase + 0.9 * sin(t * 1.3 + phase), color: Palette.leaves[i % Palette.leaves.count], opacity: max(0, fade), in: &context
            )
        }
    }

    private func drawLeafPile(in context: inout GraphicsContext) {
        let x0 = bar.minX + 4 * s
        let x1 = bar.maxX - 4 * s
        var x = x0
        var i = 0
        while x < x1 {
            // Deeper toward the ends, as if blown there.
            let nearEnd = min(x - x0, x1 - x) < 30 * s
            if Self.noise(i, 61) > 0.12 {
                let lift = (0.8 + 1.8 * rand(i, 62)) * s + (nearEnd ? 1.2 * s : 0)
                let flip = Self.noise(i, 63) > 0.5 ? Double.pi : 0
                drawLeaf(
                    at: CGPoint(x: x, y: top(x) - lift), length: (7.5 + 3 * rand(i, 64)) * s,
                    angle: (Self.noise(i, 65) - 0.5) * 1.3 + flip, color: Palette.leaves[i % Palette.leaves.count], in: &context
                )
            }
            x += (nearEnd ? 5 : 9) * s
            i += 1
        }
    }

    private func drawCandies(in context: inout GraphicsContext) {
        let places: [(CGPoint, Double, Bool)] = [
            (CGPoint(x: bar.minX - 9 * s, y: bar.maxY - 6 * s), -0.35, true),
            (CGPoint(x: bar.minX - 16 * s, y: bar.maxY - 1 * s), 0.2, false),
            (CGPoint(x: bar.minX - 5 * s, y: bar.maxY + 5 * s), 1.2, true),
            (CGPoint(x: bar.maxX + 9 * s, y: bar.maxY - 6 * s), 0.35, true),
            (CGPoint(x: bar.maxX + 16 * s, y: bar.maxY - 1 * s), -0.2, false),
            (CGPoint(x: bar.maxX + 5 * s, y: bar.maxY + 5 * s), -1.2, true),
            (CGPoint(x: bar.minX + 26 * s, y: bar.minY - 4.5 * s), 0.15, true),
            (CGPoint(x: bar.maxX - 30 * s, y: bar.minY - 3.5 * s), 0, false),
        ]
        for (index, place) in places.enumerated() {
            if place.2 {
                drawCandyCorn(at: place.0, angle: place.1, in: &context)
            } else {
                drawWrappedCandy(at: place.0, angle: place.1, color: Palette.wrappers[index % Palette.wrappers.count], in: &context)
            }
        }
    }

    private func drawCandyCorn(at center: CGPoint, angle: Double, in context: inout GraphicsContext) {
        let w = 7 * s
        let h = 9 * s
        var corn = context
        corn.translateBy(x: center.x, y: center.y)
        corn.rotate(by: .radians(angle))
        var shape = Path()
        shape.move(to: CGPoint(x: -w * 0.12, y: -h / 2))
        shape.addQuadCurve(to: CGPoint(x: w * 0.12, y: -h / 2), control: CGPoint(x: 0, y: -h / 2 - 1 * s))
        shape.addLine(to: CGPoint(x: w / 2, y: h * 0.38))
        shape.addQuadCurve(to: CGPoint(x: -w / 2, y: h * 0.38), control: CGPoint(x: 0, y: h * 0.62))
        shape.closeSubpath()
        corn.clip(to: shape)
        corn.fill(Path(CGRect(x: -w, y: -h, width: w * 2, height: h * 2)), with: .color(Palette.cornYellow))
        corn.fill(Path(CGRect(x: -w, y: -h, width: w * 2, height: h * 1.25)), with: .color(Palette.pumpkin))
        corn.fill(Path(CGRect(x: -w, y: -h, width: w * 2, height: h * 0.86)), with: .color(Palette.cream))
    }

    private func drawWrappedCandy(at center: CGPoint, angle: Double, color: Color, in context: inout GraphicsContext) {
        var candy = context
        candy.translateBy(x: center.x, y: center.y)
        candy.rotate(by: .radians(angle))
        let r = 3.1 * s
        var ends = Path()
        for side in [-1.0, 1.0] as [CGFloat] {
            ends.move(to: CGPoint(x: side * r * 0.8, y: 0))
            ends.addLine(to: CGPoint(x: side * r * 2, y: -r * 0.75))
            ends.addQuadCurve(to: CGPoint(x: side * r * 2, y: r * 0.75), control: CGPoint(x: side * r * 1.7, y: 0))
            ends.closeSubpath()
        }
        candy.fill(ends, with: .color(color.opacity(0.85)))
        candy.fill(circle(.zero, r), with: .color(color))
        var swirl = Path()
        swirl.addArc(center: .zero, radius: r * 0.55, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
        candy.stroke(swirl, with: .color(.white.opacity(0.85)), lineWidth: max(0.4, 0.8 * s))
    }

    // MARK: Winter

    private func drawSnow(in context: inout GraphicsContext) {
        let count = min(160, Int(size.width / (12 * s)))
        for i in 0..<count {
            let speed = (7 + 7 * Self.noise(i, 1)) * Double(s)
            let r = (0.7 + 1 * rand(i, 2)) * s
            let x = rand(i, 3) * size.width + (2 + 4 * rand(i, 4)) * s * CGFloat(sin(t * (0.6 + Self.noise(i, 5)) + Self.noise(i, 6) * 6.28))
            let floor = (x > bar.minX && x < bar.maxX ? top(x) : size.height) + 1 * s
            let y = CGFloat(wrap(t * speed + Self.noise(i, 7) * Double(floor), Double(floor)))
            let fade = Double(min(1, y / (4 * s), (floor - y) / (3 * s)))
            context.fill(circle(CGPoint(x: x, y: y), r), with: .color(.white.opacity(0.88 * max(0, fade))))
        }
    }

    private func drawSnowCap(in context: inout GraphicsContext) {
        let x0 = bar.minX + 1.5 * s
        let x1 = bar.maxX - 1.5 * s
        guard x1 > x0 else { return }
        func taper(_ x: CGFloat) -> CGFloat { min(1, (x - x0) / (12 * s), (x1 - x) / (12 * s)) }
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        var x = x0
        while true {
            let k = taper(x)
            let rx = x / s
            let height = (2.6 + 1.1 * sin(rx * 0.19 + 1.3) + 0.7 * sin(rx * 0.47)) * s * k
            let depth = (1.4 + 0.8 * max(0, sin(rx * 0.31))) * s * k
            upper.append(CGPoint(x: x, y: top(x) - height))
            lower.append(CGPoint(x: x, y: top(x) + depth))
            if x >= x1 { break }
            x = min(x1, x + 2 * s)
        }
        var cap = Path()
        cap.addLines(upper)
        for point in lower.reversed() { cap.addLine(to: point) }
        cap.closeSubpath()
        context.fill(cap, with: .color(Palette.snow))
        var underside = Path()
        underside.addLines(lower)
        context.stroke(underside, with: .color(Palette.snowShade.opacity(0.7)), lineWidth: max(0.5, 0.8 * s))
    }

    private func drawIcicles(in context: inout GraphicsContext) {
        let x0 = bar.minX + max(cornerRadius * 0.5, 6 * s)
        let x1 = bar.maxX - max(cornerRadius * 0.5, 6 * s)
        var x = x0
        var i = 0
        while x < x1 {
            if Self.noise(i, 71) > 0.25 {
                let length = (2.5 + 6 * rand(i, 72) * rand(i, 72)) * s
                let w = (1.6 + 1 * rand(i, 73)) * s
                let root = top(x) + 1.2 * s
                var icicle = Path()
                icicle.move(to: CGPoint(x: x - w / 2, y: root))
                icicle.addLine(to: CGPoint(x: x + w / 2, y: root))
                icicle.addLine(to: CGPoint(x: x + w * 0.08, y: root + length))
                icicle.closeSubpath()
                context.fill(icicle, with: .linearGradient(
                    Gradient(colors: [Palette.snow.opacity(0.95), Palette.ice.opacity(0.35)]),
                    startPoint: CGPoint(x: x, y: root), endPoint: CGPoint(x: x, y: root + length)
                ))
            }
            x += (5 + 3 * rand(i, 74)) * s
            i += 1
        }
    }

    private func drawCandyStripes(in context: inout GraphicsContext) {
        let width = 3.2 * s
        var band = Path(roundedRect: bar, cornerRadius: radius, style: .continuous)
        band.addPath(Path(roundedRect: bar.insetBy(dx: width, dy: width), cornerRadius: max(0, radius - width), style: .continuous))
        var stripes = context
        stripes.clip(to: band, style: FillStyle(eoFill: true))
        stripes.fill(band, with: .color(.white), style: FillStyle(eoFill: true))
        var lines = Path()
        var x = bar.minX - bar.height
        while x < bar.maxX {
            lines.move(to: CGPoint(x: x, y: bar.maxY))
            lines.addLine(to: CGPoint(x: x + bar.height, y: bar.minY))
            x += 6 * s
        }
        stripes.stroke(lines, with: .color(Palette.caneRed), lineWidth: 2.6 * s)
    }
}

/// The decorations' colors.
private enum Palette {
    static func hex(_ text: String) -> Color { Color(hex: text) ?? .white }

    static let ink = hex("#141018")
    static let pumpkin = hex("#F28C28")
    static let pumpkinDark = hex("#C9621A")
    static let pumpkinGlow = hex("#FF8A1F")
    static let stem = hex("#4E7A2E")
    static let candleLight = hex("#FFE36E")
    static let vineWire = hex("#2E3B1F")
    static let bat = hex("#1D1029")
    static let web = hex("#E6E0F0")
    static let spider = hex("#2A1F33")
    static let ghost = hex("#EFFFF6")
    static let ghostGlow = hex("#7CFFB0")
    static let fog = hex("#D4FFE8")
    static let slime = hex("#8DF25E")
    static let slimeDark = hex("#3E9E2A")
    static let leaves = [hex("#E8742A"), hex("#C8402A"), hex("#E8B33A"), hex("#9A5B2E"), hex("#D95F1E")]
    static let leafVein = hex("#5A2E12")
    static let cream = hex("#FFF8E7")
    static let cornYellow = hex("#F9C440")
    static let wrappers = [hex("#E8483B"), hex("#8E44AD"), hex("#F28C28")]
    static let snow = hex("#FBFDFF")
    static let snowShade = hex("#B8CBE0")
    static let ice = hex("#BFE4FF")
    static let caneRed = hex("#D7263D")
    static let twinkle = [hex("#FF4D4D"), hex("#3DDC84"), hex("#FFD34D"), hex("#4DA6FF")]
    static let warm = [hex("#FFE3A3"), hex("#FFC65C"), hex("#FFF1CF")]
    static let candy = [hex("#FF3347"), hex("#2ED158")]
    static let pineWire = hex("#173D22")
    static let brownWire = hex("#3A2A1C")
    static let grayWire = hex("#4A4A4F")
}
