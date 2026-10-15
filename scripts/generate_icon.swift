// Renders Kosmodock's app icon with CoreGraphics and packs it into an .icns.
//
//   swift scripts/generate_icon.swift Assets/AppIcon.icns [preview.png]
//
// Every size is drawn as vectors at its own pixel size (no downsampling);
// sizes of 64 px and below drop fine detail so they stay legible.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Helpers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func white(_ alpha: CGFloat) -> CGColor { color(0xFFFFFF, alpha) }

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    let r = min(radius, rect.width / 2, rect.height / 2)
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// macOS app-icon squircle: straight sides with superellipse corners, whose
/// curvature eases to zero where they meet the sides (continuous corners).
func squircle(_ rect: CGRect, corner: CGFloat = 236, exponent: CGFloat = 4.6) -> CGPath {
    let path = CGMutablePath()
    let steps = 90
    // Corner centres, counter-clockwise from bottom-right, with the quarter
    // each one sweeps.
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: rect.maxX - corner, y: rect.minY + corner), -.pi / 2),
        (CGPoint(x: rect.maxX - corner, y: rect.maxY - corner), 0),
        (CGPoint(x: rect.minX + corner, y: rect.maxY - corner), .pi / 2),
        (CGPoint(x: rect.minX + corner, y: rect.minY + corner), .pi),
    ]
    for (index, (center, start)) in corners.enumerated() {
        for step in 0...steps {
            let t = start + CGFloat(step) / CGFloat(steps) * .pi / 2
            let (c, s) = (cos(t), sin(t))
            let point = CGPoint(
                x: center.x + corner * copysign(pow(abs(c), 2 / exponent), c),
                y: center.y + corner * copysign(pow(abs(s), 2 / exponent), s)
            )
            index == 0 && step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
    }
    path.closeSubpath()
    return path
}

func ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat) -> CGPath {
    var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
    return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &transform)
}

func pointOnEllipse(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat, degrees: CGFloat) -> CGPoint {
    let t = degrees * .pi / 180
    let (x, y) = (rx * cos(t), ry * sin(t))
    return CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
}

/// Deterministic generator so every size gets the same star field.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt64(1) << 31)
    }
}

enum Detail { case tiny, small, full }

// MARK: - Drawing (1024 × 1024 design space, origin bottom-left)

struct IconPainter {
    let ctx: CGContext
    /// Device pixels per design unit; shadows are specified in device space.
    let scale: CGFloat
    let detail: Detail

    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let orbitCenter = CGPoint(x: 512, y: 556)
    static let card = CGRect(x: 297, y: 418, width: 430, height: 300)
    static let dock = CGRect(x: 168, y: 150, width: 688, height: 116)
    static let groupTints: [UInt32] = [0x7C6CFF, 0x3FA9F5, 0x2EC27E, 0xFF8A3D]

    /// Grayscale mask over the card: opaque along the bottom, fading out by
    /// a third of the way up.
    static let frontArcMask: CGImage = {
        let height = 256
        var pixels = [UInt8](repeating: 0, count: height)
        for row in 0..<height {
            let fromBottom = 1 - CGFloat(row) / CGFloat(height - 1) // row 0 is the top
            let alpha = min(1, max(0, (0.32 - fromBottom) / 0.2))
            pixels[row] = UInt8(alpha * 255)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: 1, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }()

    func draw() {
        ctx.scaleBy(x: scale, y: scale)
        let shape = squircle(Self.body)

        // Drop shadow under the squircle.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 30 * scale, color: color(0x000000, 0.5))
        ctx.addPath(shape)
        ctx.setFillColor(color(0x0D0E12))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        drawSpace()
        drawOrbits(front: false)
        drawCard()
        drawOrbits(front: true)
        drawDock()
        drawRim(shape)
        ctx.restoreGState()
    }

    // Space Black body with nebulae and stars.
    private func drawSpace() {
        ctx.drawLinearGradient(
            gradient([color(0x34363F), color(0x17181E), color(0x07080B)], [0, 0.42, 1]),
            start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
        )
        radialGlow(at: CGPoint(x: 300, y: 720), radius: 470, color: color(0x7B4DFF, 0.45))
        radialGlow(at: CGPoint(x: 770, y: 500), radius: 430, color: color(0x2E8BFF, 0.40))
        radialGlow(at: CGPoint(x: 560, y: 330), radius: 330, color: color(0xFF5FD2, 0.14))

        guard detail == .full else { return }
        var random = SeededRandom(state: 0x0B17_D0C4)
        for _ in 0..<80 {
            let point = CGPoint(x: 120 + random.next() * 784, y: 300 + random.next() * 610)
            let radius = 0.9 + random.next() * 2.3
            ctx.setFillColor(white(0.12 + random.next() * 0.5))
            ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    private func radialGlow(at center: CGPoint, radius: CGFloat, color glow: CGColor) {
        ctx.drawRadialGradient(
            gradient([glow, glow.copy(alpha: 0)!]),
            startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: []
        )
    }

    // Two luminous orbital rings around the card. The lower ("front") half of
    // the main ring is drawn again over the card so it wraps around it.
    private func drawOrbits(front: Bool) {
        let center = Self.orbitCenter
        let widthBoost: CGFloat = detail == .full ? 1 : (detail == .small ? 1.5 : 2.4)
        let ringA = ellipse(center: center, rx: 372, ry: 132, angle: -0.33)
        let ringB = ellipse(center: center, rx: 330, ry: 112, angle: 0.42)

        if front {
            guard detail != .tiny else { return }
            // Front arc: ring A emerges in front of the card's lower edge,
            // faded in with a soft mask so there's no hard seam.
            ctx.saveGState()
            ctx.addPath(roundedRect(Self.card, 60))
            ctx.clip()
            ctx.clip(to: Self.card, mask: Self.frontArcMask)
            gradientStroke(ringA, width: 10 * widthBoost, colors: [color(0x58B4FF), color(0x9D6BFF), color(0xFF7AD9)])
            ctx.restoreGState()
            return
        }

        // Tiny sizes: one bold ring around a glowing gauge reads best.
        guard detail != .tiny else {
            glowStroke(ringA, width: 10 * widthBoost, colors: [color(0x58B4FF), color(0x9D6BFF), color(0xFF7AD9)], glow: color(0x6A8CFF, 0.9))
            return
        }

        if detail == .full {
            ctx.addPath(ellipse(center: center, rx: 420, ry: 158, angle: 0.06))
            ctx.setLineWidth(3)
            ctx.setStrokeColor(white(0.13))
            ctx.strokePath()
        }
        glowStroke(ringB, width: 7 * widthBoost, colors: [color(0xA77BFF), color(0x4FA3FF)], glow: color(0x8B6BFF, 0.85))
        glowStroke(ringA, width: 10 * widthBoost, colors: [color(0x58B4FF), color(0x9D6BFF), color(0xFF7AD9)], glow: color(0x6A8CFF, 0.9))

        guard detail != .tiny else { return }
        planet(at: pointOnEllipse(center: center, rx: 372, ry: 132, angle: -0.33, degrees: 200), radius: 22, core: color(0xBFE3FF), glow: color(0x4FA3FF))
        planet(at: pointOnEllipse(center: center, rx: 330, ry: 112, angle: 0.42, degrees: 22), radius: 15, core: color(0xE6D6FF), glow: color(0x9D6BFF))
        if detail == .full {
            planet(at: pointOnEllipse(center: center, rx: 372, ry: 132, angle: -0.33, degrees: 112), radius: 9, core: color(0xFFE1F6), glow: color(0xFF7AD9))
        }
    }

    private func glowStroke(_ path: CGPath, width: CGFloat, colors: [CGColor], glow: CGColor) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 28 * scale, color: glow)
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(glow)
        ctx.strokePath()
        ctx.restoreGState()
        gradientStroke(path, width: width, colors: colors)
    }

    private func gradientStroke(_ path: CGPath, width: CGFloat, colors: [CGColor]) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let bounds = path.boundingBox
        ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: bounds.minX, y: bounds.midY), end: CGPoint(x: bounds.maxX, y: bounds.midY), options: [])
        ctx.restoreGState()
    }

    private func planet(at point: CGPoint, radius: CGFloat, core: CGColor, glow: CGColor) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 26 * scale, color: glow)
        ctx.setFillColor(glow)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.drawRadialGradient(
            gradient([core, glow]),
            startCenter: CGPoint(x: point.x - radius * 0.35, y: point.y + radius * 0.35), startRadius: 0,
            endCenter: point, endRadius: radius, options: []
        )
        ctx.restoreGState()
    }

    // Frosted Bento card. Rings show through the dark translucent fill.
    private func drawCard() {
        let card = Self.card
        guard detail != .tiny else {
            gauge(center: Self.orbitCenter, radius: 118, width: 58)
            return
        }
        let path = roundedRect(card, 60)
        glass(path, rect: card, tint: color(0x8B7CFF), darkness: 0.58, shadow: 46)

        guard detail == .full else {
            gauge(center: CGPoint(x: card.midX, y: card.midY), radius: 92, width: 26)
            return
        }

        let inner = card.insetBy(dx: 26, dy: 26)
        let gap: CGFloat = 16
        let left = CGRect(x: inner.minX, y: inner.minY, width: inner.width * 0.43, height: inner.height)
        let rightWidth = inner.width - left.width - gap
        let halfHeight = (inner.height - gap) / 2
        let topRight = CGRect(x: left.maxX + gap, y: inner.minY + halfHeight + gap, width: rightWidth, height: halfHeight)
        let bottomRight = CGRect(x: left.maxX + gap, y: inner.minY, width: rightWidth, height: halfHeight)
        for tile in [left, topRight, bottomRight] { self.tile(tile) }

        gauge(center: CGPoint(x: left.midX, y: left.midY), radius: min(left.width, left.height) * 0.3, width: 17)

        // Bar chart.
        let heights: [CGFloat] = [0.42, 0.72, 0.55, 0.92, 0.64]
        let barWidth: CGFloat = 17
        let barGap = (topRight.width - 44 - barWidth * CGFloat(heights.count)) / CGFloat(heights.count - 1)
        for (index, fraction) in heights.enumerated() {
            let height = (topRight.height - 40) * fraction
            let bar = CGRect(x: topRight.minX + 22 + CGFloat(index) * (barWidth + barGap), y: topRight.minY + 20, width: barWidth, height: height)
            ctx.saveGState()
            ctx.addPath(roundedRect(bar, barWidth / 2))
            ctx.clip()
            ctx.drawLinearGradient(gradient([color(0x4FA3FF), color(0xA77BFF)]), start: CGPoint(x: bar.midX, y: bar.minY), end: CGPoint(x: bar.midX, y: bar.minY + topRight.height - 40), options: [])
            ctx.restoreGState()
        }

        // Status rows.
        let rows: [(UInt32, CGFloat)] = [(0x34D46F, 0.78), (0xFFC22E, 0.58)]
        for (index, row) in rows.enumerated() {
            let y = bottomRight.maxY - 30 - CGFloat(index) * 44
            let dot = CGRect(x: bottomRight.minX + 22, y: y - 10, width: 20, height: 20)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 12 * scale, color: color(row.0, 0.9))
            ctx.setFillColor(color(row.0))
            ctx.fillEllipse(in: dot)
            ctx.restoreGState()
            let lineWidth = (bottomRight.width - 80) * row.1
            ctx.addPath(roundedRect(CGRect(x: dot.maxX + 14, y: y - 6, width: lineWidth, height: 12), 6))
            ctx.setFillColor(white(0.55))
            ctx.fillPath()
        }
    }

    private func tile(_ rect: CGRect) {
        let path = roundedRect(rect, 30)
        ctx.addPath(path)
        ctx.setFillColor(white(0.075))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setLineWidth(2)
        ctx.setStrokeColor(white(0.12))
        ctx.strokePath()
    }

    private func gauge(center: CGPoint, radius: CGFloat, width: CGFloat) {
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(white(0.13))
        ctx.strokePath()

        let start = CGFloat.pi / 2
        let end = start - .pi * 2 * 0.72
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 16 * scale, color: color(0x6A8CFF, 0.8))
        ctx.addPath(arc)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([color(0x58B4FF), color(0xB07BFF)]), start: CGPoint(x: center.x - radius, y: center.y + radius), end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
        ctx.restoreGState()
    }

    // Glass dock bar holding four widget capsules.
    private func drawDock() {
        let dock = Self.dock
        glass(roundedRect(dock, dock.height / 2), rect: dock, tint: color(0x5A7BFF), darkness: 0.55, shadow: 34)

        let tints = detail == .tiny ? Array(Self.groupTints.prefix(3)) : Self.groupTints
        let inner = dock.insetBy(dx: 20, dy: 18)
        let gap: CGFloat = detail == .tiny ? 24 : 14
        let width = (inner.width - gap * CGFloat(tints.count - 1)) / CGFloat(tints.count)
        for (index, tint) in tints.enumerated() {
            let capsule = CGRect(x: inner.minX + CGFloat(index) * (width + gap), y: inner.minY, width: width, height: inner.height)
            widgetCapsule(capsule, tint: tint)
        }
    }

    private func widgetCapsule(_ rect: CGRect, tint: UInt32) {
        let path = roundedRect(rect, 26)
        ctx.addPath(path)
        ctx.setFillColor(color(tint, 0.24))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setLineWidth(2)
        ctx.setStrokeColor(color(tint, 0.6))
        ctx.strokePath()

        let side: CGFloat = detail == .tiny ? rect.height - 12 : 46
        let glyph = CGRect(
            x: detail == .tiny ? rect.midX - side / 2 : rect.minX + 14,
            y: rect.midY - side / 2, width: side, height: side
        )
        ctx.saveGState()
        ctx.addPath(roundedRect(glyph, side * 0.3))
        ctx.clip()
        ctx.drawLinearGradient(gradient([color(tint).copy(alpha: 1)!, color(tint, 0.7)]), start: CGPoint(x: glyph.midX, y: glyph.maxY), end: CGPoint(x: glyph.midX, y: glyph.minY), options: [])
        ctx.setFillColor(white(0.92))
        ctx.fillEllipse(in: glyph.insetBy(dx: side * 0.32, dy: side * 0.32))
        ctx.restoreGState()

        guard detail == .full else { return }
        // Badge "text" lines and a live status dot.
        ctx.addPath(roundedRect(CGRect(x: glyph.maxX + 12, y: rect.midY + 3, width: rect.width - side - 44, height: 11), 5.5))
        ctx.setFillColor(white(0.78))
        ctx.fillPath()
        ctx.addPath(roundedRect(CGRect(x: glyph.maxX + 12, y: rect.midY - 15, width: (rect.width - side - 44) * 0.65, height: 9), 4.5))
        ctx.setFillColor(white(0.36))
        ctx.fillPath()
        let dot = CGRect(x: glyph.maxX - 9, y: glyph.maxY - 9, width: 14, height: 14)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 10 * scale, color: color(0x34D46F, 0.9))
        ctx.setFillColor(color(0x34D46F))
        ctx.fillEllipse(in: dot)
        ctx.restoreGState()
    }

    /// Dark translucent glass with a top sheen and a specular gradient border.
    private func glass(_ path: CGPath, rect: CGRect, tint: CGColor, darkness: CGFloat, shadow: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: shadow * scale, color: color(0x000000, 0.55))
        ctx.addPath(path)
        ctx.setFillColor(color(0x0E0F15, darkness))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([white(0.17), white(0.06), tint.copy(alpha: 0.10)!], [0, 0.55, 1]),
            start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: []
        )
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(detail == .full ? 3 : 5)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([white(0.62), white(0.14), white(0.26)], [0, 0.6, 1]),
            start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: []
        )
        ctx.restoreGState()
    }

    /// Specular highlight along the top of the squircle.
    private func drawRim(_ shape: CGPath) {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setLineWidth(detail == .full ? 7 : 12)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([white(0.42), white(0.06), white(0)], [0, 0.5, 1]),
            start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
        )
        ctx.restoreGState()
    }
}

// MARK: - Rendering & packaging

func render(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    let detail: Detail = pixels <= 32 ? .tiny : (pixels <= 64 ? .small : .full)
    IconPainter(ctx: context, scale: CGFloat(pixels) / 1024, detail: detail).draw()
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/generate_icon.swift <AppIcon.icns> [preview.png]\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[1])
let preview = arguments.count >= 3 ? URL(fileURLWithPath: arguments[2]) : nil
for directory in [output, preview].compactMap({ $0?.deletingLastPathComponent() }) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Kosmodock-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
var rendered: [Int: CGImage] = [:]
for entry in entries {
    let image = rendered[entry.pixels] ?? render(pixels: entry.pixels)
    rendered[entry.pixels] = image
    try writePNG(image, to: iconset.appendingPathComponent("\(entry.name).png"))
}
if let preview, let large = rendered[1024] {
    try writePNG(large, to: preview)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (\(iconutil.terminationStatus))\n".utf8))
    exit(1)
}
print("✓ Wrote \(output.path) (\(entries.count) images, 16–1024 px)")
