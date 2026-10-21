import SwiftUI

/// An app's notification badge at its icon's top-trailing corner, like the
/// macOS Dock: a red capsule with white text, or a red dot. It's an overlay,
/// so a badge appearing or changing never moves anything.
struct NotificationBadge: ViewModifier {
    enum Style: Equatable {
        /// The text in a red capsule; "•" and blank badges become a dot.
        case full
        /// Only a small dot, for the tiny icons on collapsed capsules.
        case dot
        case hidden
    }

    /// The badge text as the app set it, or `nil` for no badge.
    var label: String?
    var iconSize: CGFloat
    var style: Style = .full

    func body(content: Content) -> some View {
        let display = style == .hidden ? nil : label.map(BadgeDisplay.init(label:))
        content.overlay(alignment: .topTrailing) {
            ZStack {
                if let display {
                    badge(display)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: display)
        }
    }

    @ViewBuilder
    private func badge(_ display: BadgeDisplay) -> some View {
        let height = max(11, iconSize * 0.4)
        switch (style, display) {
        case (.full, .text(let text)):
            Text(verbatim: text)
                .font(.system(size: height * 0.68, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, height * 0.28)
                .frame(minWidth: height, minHeight: height)
                .background(Capsule().fill(Self.red))
                .fixedSize()
                .shadow(color: .black.opacity(0.25), radius: 0.8, y: 0.5)
                .offset(x: height * 0.3, y: -height * 0.22)
        case (.full, .dot):
            dot(diameter: height * 0.62)
        default:
            dot(diameter: max(5, iconSize * 0.3))
        }
    }

    private func dot(diameter: CGFloat) -> some View {
        Circle()
            .fill(Self.red)
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.3), radius: 0.6, y: 0.3)
            .offset(x: diameter * 0.25, y: -diameter * 0.25)
    }

    static let red = Color(nsColor: .systemRed)
}
