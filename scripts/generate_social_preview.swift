// Renders the GitHub/social link preview (1280 × 640) in the app icon's style.
//
//   swift scripts/generate_social_preview.swift Assets/social-preview.png
//
// Upload the result in GitHub → Settings → General → Social preview.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 1280
let height = 640
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func white(_ alpha: CGFloat) -> CGColor { color(0xFFFFFF, alpha) }

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: min(radius, rect.height / 2), cornerHeight: min(radius, rect.height / 2), transform: nil)
}

struct SeededRandom {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt64(1) << 31)
    }
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/generate_social_preview.swift <output.png>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Assets/AppIcon.icns")

let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let canvas = CGRect(x: 0, y: 0, width: width, height: height)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

// MARK: Space background

ctx.drawLinearGradient(gradient([color(0x2C2E37), color(0x14151B), color(0x07080B)], [0, 0.5, 1]),
                       start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: 0), options: [])
func glow(_ center: CGPoint, _ radius: CGFloat, _ tint: CGColor) {
    ctx.drawRadialGradient(gradient([tint, tint.copy(alpha: 0)!]), startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}
glow(CGPoint(x: 250, y: 470), 520, color(0x7B4DFF, 0.42))
glow(CGPoint(x: 1080, y: 300), 560, color(0x2E8BFF, 0.34))
glow(CGPoint(x: 700, y: 120), 380, color(0xFF5FD2, 0.12))

var random = SeededRandom(state: 0x5EED_0C1A)
for _ in 0..<120 {
    let point = CGPoint(x: random.next() * CGFloat(width), y: 180 + random.next() * CGFloat(height - 180))
    let radius = 0.6 + random.next() * 1.6
    ctx.setFillColor(white(0.10 + random.next() * 0.45))
    ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
}

// Orbit rings sweeping behind the title, echoing the icon.
func ring(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat, width lineWidth: CGFloat, colors: [CGColor], glowColor: CGColor) {
    var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
    let path = CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &transform)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: glowColor)
    ctx.addPath(path)
    ctx.setLineWidth(lineWidth)
    ctx.setStrokeColor(glowColor)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(lineWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let box = path.boundingBox
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: box.minX, y: box.midY), end: CGPoint(x: box.maxX, y: box.midY), options: [])
    ctx.restoreGState()
}
ring(center: CGPoint(x: 880, y: 430), rx: 520, ry: 120, angle: -0.12, width: 3,
     colors: [color(0x58B4FF, 0.30), color(0x9D6BFF, 0.30), color(0xFF7AD9, 0.24)], glowColor: color(0x6A8CFF, 0.18))
ring(center: CGPoint(x: 900, y: 440), rx: 470, ry: 90, angle: 0.16, width: 2,
     colors: [color(0xA77BFF, 0.20), color(0x4FA3FF, 0.20)], glowColor: color(0x8B6BFF, 0.12))

// MARK: Icon + title

if let icon = NSImage(contentsOf: iconURL) {
    icon.draw(in: NSRect(x: 60, y: 224, width: 340, height: 340), from: .zero, operation: .sourceOver, fraction: 1)
}

func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color textColor: NSColor, kern: CGFloat = 0) -> CGSize {
    let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.rounded)
    let font = descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: weight)
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor, .kern: kern])
    string.draw(at: point)
    return string.size()
}

_ = draw("Kosmodock", at: CGPoint(x: 410, y: 432), size: 100, weight: .bold, color: .white, kern: -1.5)
_ = draw("A macOS Dock replacement with live widget groups", at: CGPoint(x: 416, y: 382), size: 33, weight: .medium,
         color: NSColor(white: 1, alpha: 0.78))

// Feature chips.
var chipX: CGFloat = 416
for (label, tint) in [("Live telemetry", 0x58B4FF), ("Podman", 0x3FA9F5), ("Window tiling", 0x9D6BFF),
                      ("Minimize into groups", 0xFF7AD9), ("EN · PT · ES", 0x2EC27E)] as [(String, UInt32)] {
    let font = NSFont.systemFont(ofSize: 19, weight: .semibold)
    let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
    let chip = CGRect(x: chipX, y: 300, width: text.size().width + 32, height: 40)
    ctx.addPath(rounded(chip, 20))
    ctx.setFillColor(color(tint, 0.20))
    ctx.fillPath()
    ctx.addPath(rounded(chip, 20))
    ctx.setLineWidth(1.5)
    ctx.setStrokeColor(color(tint, 0.65))
    ctx.strokePath()
    text.draw(at: CGPoint(x: chip.minX + 16, y: chip.minY + (chip.height - text.size().height) / 2))
    chipX = chip.maxX + 12
}

// MARK: Dock bar with live capsules

let dock = CGRect(x: 60, y: 56, width: CGFloat(width) - 120, height: 128)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: color(0x000000, 0.6))
ctx.addPath(rounded(dock, 40))
ctx.setFillColor(color(0x0E0F15, 0.62))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded(dock, 40))
ctx.clip()
ctx.drawLinearGradient(gradient([white(0.16), white(0.05), color(0x5A7BFF, 0.08)], [0, 0.55, 1]),
                       start: CGPoint(x: 0, y: dock.maxY), end: CGPoint(x: 0, y: dock.minY), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded(dock, 40))
ctx.setLineWidth(2)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([white(0.6), white(0.12), white(0.25)], [0, 0.6, 1]),
                       start: CGPoint(x: 0, y: dock.maxY), end: CGPoint(x: 0, y: dock.minY), options: [])
ctx.restoreGState()

struct Capsule {
    let name: String
    let badge: String
    let symbol: String
    let tint: UInt32
    let status: UInt32?
}
let capsules = [
    Capsule(name: "Code", badge: "12% CPU • 3.8 GB", symbol: "chevron.left.forwardslash.chevron.right", tint: 0x7C6CFF, status: nil),
    Capsule(name: "Containers", badge: "🦭 3 UP • 4% CPU", symbol: "shippingbox.fill", tint: 0x3FA9F5, status: 0x34D46F),
    Capsule(name: "Data & APIs", badge: "2/2 ports • 1.1 GB", symbol: "cylinder.split.1x2.fill", tint: 0x2EC27E, status: 0x34D46F),
    Capsule(name: "Web", badge: "3% CPU • 812 MB", symbol: "globe", tint: 0xFF8A3D, status: nil),
    Capsule(name: "System", badge: "Battery 🔋 80%", symbol: "gearshape.2.fill", tint: 0x8E8E93, status: 0x34D46F),
]
let inner = dock.insetBy(dx: 22, dy: 22)
let gap: CGFloat = 14
let capsuleWidth = (inner.width - gap * CGFloat(capsules.count - 1)) / CGFloat(capsules.count)
for (index, capsule) in capsules.enumerated() {
    let rect = CGRect(x: inner.minX + CGFloat(index) * (capsuleWidth + gap), y: inner.minY, width: capsuleWidth, height: inner.height)
    ctx.addPath(rounded(rect, 22))
    ctx.setFillColor(color(capsule.tint, 0.22))
    ctx.fillPath()
    ctx.addPath(rounded(rect, 22))
    ctx.setLineWidth(1.5)
    ctx.setStrokeColor(color(capsule.tint, 0.6))
    ctx.strokePath()

    let glyph = CGRect(x: rect.minX + 14, y: rect.midY - 25, width: 50, height: 50)
    ctx.saveGState()
    ctx.addPath(rounded(glyph, 15))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(capsule.tint), color(capsule.tint, 0.7)]),
                           start: CGPoint(x: 0, y: glyph.maxY), end: CGPoint(x: 0, y: glyph.minY), options: [])
    ctx.restoreGState()
    let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: capsule.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: glyph.midX - size.width / 2, y: glyph.midY - size.height / 2, width: size.width, height: size.height))
    }

    _ = draw(capsule.name, at: CGPoint(x: glyph.maxX + 12, y: rect.midY + 2), size: 18, weight: .semibold, color: .white)
    var badgeX = glyph.maxX + 12
    if let status = capsule.status {
        let dot = CGRect(x: badgeX, y: rect.midY - 19, width: 9, height: 9)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6, color: color(status, 0.9))
        ctx.setFillColor(color(status))
        ctx.fillEllipse(in: dot)
        ctx.restoreGState()
        badgeX = dot.maxX + 6
    }
    _ = draw(capsule.badge, at: CGPoint(x: badgeX, y: rect.midY - 26), size: 13, weight: .medium, color: NSColor(white: 1, alpha: 0.7))
}

// MARK: Write

let image = ctx.makeImage()!
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("✓ Wrote \(output.path) (\(width)×\(height))")
