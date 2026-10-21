import AppKit
import SwiftUI

// MARK: - Colors

extension Color {
    /// Parses `#RRGGBB` or `#RRGGBBAA`.
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var hexString: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#8B7CFF" }
        func component(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(color.redComponent), component(color.greenComponent), component(color.blueComponent))
    }
}

extension HealthLevel {
    var color: Color {
        switch self {
        case .ok: Color(red: 0.20, green: 0.84, blue: 0.45)
        case .warning: Color(red: 1.00, green: 0.76, blue: 0.18)
        case .critical: Color(red: 1.00, green: 0.33, blue: 0.33)
        case .unknown: Color.secondary
        }
    }
}

extension GlassMaterial {
    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .hudWindow: .hudWindow
        case .popover: .popover
        case .menu: .menu
        case .sidebar: .sidebar
        case .underWindowBackground: .underWindowBackground
        case .fullScreenUI: .fullScreenUI
        }
    }
}

extension AppearanceMode {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}

// MARK: - Glass

/// Native behind-window vibrancy. `state = .active` keeps the blur lively even
/// though Kosmodock is never the active app.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var cornerRadius: CGFloat
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// Forces light or dark vibrancy; `nil` follows the window.
    var appearance: NSAppearance?

    final class Coordinator {
        var radius: CGFloat = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    private func update(_ view: NSVisualEffectView, coordinator: Coordinator) {
        if view.material != material { view.material = material }
        if view.blendingMode != blending { view.blendingMode = blending }
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        if coordinator.radius != cornerRadius {
            coordinator.radius = cornerRadius
            view.maskImage = Self.maskImage(cornerRadius: cornerRadius)
        }
    }

    /// Stretchable rounded-rect mask — the AppKit-sanctioned way to round a
    /// behind-window effect view.
    static func maskImage(cornerRadius: CGFloat) -> NSImage {
        let radius = max(0, cornerRadius)
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension DockSurface {
    /// Text and symbols must contrast with a colored fill, so it picks the
    /// scheme. The window-background fill already follows light and dark mode.
    var colorScheme: ColorScheme? {
        guard fillOpacity >= 0.4, let top = fillTopHex, let bottom = fillBottomHex,
              let topLuminance = Self.luminance(hex: top), let bottomLuminance = Self.luminance(hex: bottom)
        else { return nil }
        return (topLuminance + bottomLuminance) / 2 > 0.6 ? .light : .dark
    }

    var vibrancyAppearance: NSAppearance? {
        guard let colorScheme else { return nil }
        return NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    /// Relative luminance (0 black … 1 white) of a `#RRGGBB` color.
    static func luminance(hex: String) -> Double? {
        guard let color = Color(hex: hex), let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}

extension ThemeConfig {
    /// Corner radius of the capsules and buttons inside the bar.
    var capsuleRadius: CGFloat { max(6, CGFloat(surface.cornerRadius) - 9) }
}

/// Without a bar (the floating style) a capsule draws its own glass, so it
/// stays readable over any wallpaper.
struct FloatingGlass: ViewModifier {
    @Environment(AppModel.self) private var model
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            if !model.theme.surface.isVisible {
                SurfaceBackground(surface: DockStyle.glass.surface, cornerRadius: cornerRadius, scale: 0.5)
            }
        }
    }
}

/// Draws a `DockSurface`: drop shadow, behind-window blur, fill, top sheen,
/// border and glow. `scale` shrinks the shadow and glow for small previews.
struct SurfaceBackground: View {
    var surface: DockSurface
    var cornerRadius: CGFloat
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var scale: CGFloat = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let border = Color(hex: surface.borderHex) ?? .white
        let glow = Color(hex: surface.glowHex) ?? .white
        ZStack {
            if surface.isVisible {
                shape
                    .fill(Color.black.opacity(0.22))
                    .shadow(color: .black.opacity(0.35), radius: 18 * scale, x: 0, y: 10 * scale)
            }
            if surface.blur {
                VisualEffectBackground(
                    material: surface.material.nsMaterial, cornerRadius: cornerRadius,
                    blending: blending, appearance: surface.vibrancyAppearance
                )
            }
            shape.fill(fill)
            if surface.sheen {
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.white.opacity(0)],
                    startPoint: .top, endPoint: .center
                ))
            }
        }
        .overlay {
            if surface.borderWidth > 0, surface.borderOpacity > 0 {
                let opacity = surface.borderOpacity
                shape.strokeBorder(
                    surface.specularBorder
                        ? LinearGradient(
                            colors: [border.opacity(0.50 * opacity), border.opacity(0.08 * opacity), border.opacity(0.22 * opacity)],
                            startPoint: .top, endPoint: .bottom
                        )
                        : LinearGradient(colors: [border.opacity(opacity)], startPoint: .top, endPoint: .bottom),
                    lineWidth: surface.borderWidth
                )
            }
        }
        .background {
            // Stays within the panel's shadow inset (`DockMetrics.shadowInset`).
            if surface.glowOpacity > 0 {
                shape
                    .stroke(glow.opacity(surface.glowOpacity), lineWidth: 3 * scale)
                    .shadow(color: glow.opacity(surface.glowOpacity), radius: 5 * scale)
                    .shadow(color: glow.opacity(surface.glowOpacity * 0.8), radius: 14 * scale)
            }
        }
    }

    private var fill: AnyShapeStyle {
        guard let top = Color(hex: surface.fillTopHex), let bottom = Color(hex: surface.fillBottomHex) else {
            // The original glass tint, kept as it was.
            return AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(surface.fillOpacity * 0.85))
        }
        let points = surface.fillPoints
        return AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: points.start, endPoint: points.end).opacity(surface.fillOpacity))
    }
}

extension DockSurface {
    /// Ends of the fill gradient: top → bottom turned clockwise by `fillAngle`,
    /// reaching the shape's edges (corner to corner at 45°).
    var fillPoints: (start: UnitPoint, end: UnitPoint) {
        let radians = fillAngle * .pi / 180
        let dx = -sin(radians), dy = cos(radians)
        let half = 2 * max(abs(dx), abs(dy))
        return (UnitPoint(x: 0.5 - dx / half, y: 0.5 - dy / half), UnitPoint(x: 0.5 + dx / half, y: 0.5 + dy / half))
    }
}

// MARK: - Small components

struct StatusDot: View {
    var level: HealthLevel
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: size, height: size)
            .shadow(color: level == .unknown ? .clear : level.color.opacity(0.75), radius: size * 0.45)
    }
}

struct BadgeView: View {
    var badge: WidgetBadge

    var body: some View {
        HStack(spacing: 4) {
            if let level = badge.level { StatusDot(level: level, size: 6) }
            ZStack(alignment: .leading) {
                // Invisible widest readings hold the width while the numbers change.
                ForEach(badge.reserve.indices, id: \.self) { index in
                    Text(badge.reserve[index]).hidden()
                }
                Text(badge.text)
                    .contentTransition(.numericText())
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .frame(minWidth: 72, alignment: .leading)
        }
        .foregroundStyle(.secondary)
    }
}

struct GroupGlyph: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .frame(width: size, height: size)
    }
}

/// Miniature diagram of a tiling layout, drawn with the real tiling math.
struct LayoutGlyph: View {
    var layout: TilingLayout

    var body: some View {
        Canvas { context, size in
            let frames = TilingEngine.frames(
                for: layout, count: layout.previewCount,
                in: CGRect(origin: .zero, size: size), gap: 1.6, roundToPixels: false
            )
            for frame in frames {
                context.fill(Path(roundedRect: frame, cornerRadius: 1.4), with: .foreground)
            }
        }
    }
}

struct RingGauge: View {
    var value: Double
    var color: Color
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.6), value: value)
    }
}

struct UsageBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.6), value: fraction)
    }
}

struct GlassPillButtonStyle: ButtonStyle {
    var tint: Color
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
            .background {
                Capsule().fill(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
            }
            .overlay { Capsule().strokeBorder(Color.white.opacity(prominent ? 0.28 : 0.08), lineWidth: 0.5) }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var size: CGFloat = 24
    var action: () -> Void
    @ViewState private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.14 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Rounded inner card used to compose the Bento layout.
struct BentoCard<Content: View, Accessory: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.7)
                Spacer(minLength: 4)
                accessory
            }
            .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.55)
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

extension BentoCard where Accessory == EmptyView {
    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
        self.accessory = EmptyView()
    }
}

struct StatLine: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 10.5))
    }
}

// MARK: - State

/// Toolchain-independent `@State`.
///
/// In the macOS 27 SDK `@State` resolves to a SwiftUI macro whose plugin ships
/// only with Xcode, so `swift build` under the Command Line Tools can't expand
/// it. Holding the `State` property-wrapper struct as a plain stored property
/// keeps identical semantics with either toolchain: SwiftUI discovers dynamic
/// properties nested inside this one.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
