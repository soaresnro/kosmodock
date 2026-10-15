import AppKit
import QuartzCore

/// Plays the "window flies into its group" animation on a transparent,
/// click-through overlay panel above the dock. The card is drawn with Core
/// Animation so it runs on the render server at the display's refresh rate.
@MainActor
final class WindowMinimizeAnimator {
    static let duration: CFTimeInterval = 0.28

    private var activePanels: [FloatingPanel] = []

    /// - Parameters:
    ///   - windowFrame: The window's frame in Cocoa screen coordinates.
    ///   - capsuleFrame: The group capsule's frame in Cocoa screen coordinates.
    func play(
        _ direction: MinimizeAnimationRequest.Direction,
        windowFrame: CGRect,
        capsuleFrame: CGRect,
        icon: NSImage,
        title: String,
        tint: NSColor,
        completion: @escaping () -> Void
    ) {
        guard windowFrame.width > 20, windowFrame.height > 20, capsuleFrame.width > 0 else {
            completion()
            return
        }
        let canvas = windowFrame.union(capsuleFrame).insetBy(dx: -80, dy: -80).integral
        let panel = FloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2), allowsKey: false)
        panel.ignoresMouseEvents = true
        panel.setFrame(canvas, display: false)

        let host = NSView(frame: CGRect(origin: .zero, size: canvas.size))
        host.wantsLayer = true
        panel.contentView = host
        guard let root = host.layer else {
            completion()
            return
        }

        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - canvas.minX, y: point.y - canvas.minY)
        }
        let windowCenter = local(CGPoint(x: windowFrame.midX, y: windowFrame.midY))
        let capsuleCenter = local(CGPoint(x: capsuleFrame.midX, y: capsuleFrame.midY))
        let landedScale = max(0.02, min(capsuleFrame.width / windowFrame.width, capsuleFrame.height / windowFrame.height) * 0.9)

        let card = makeCard(size: windowFrame.size, icon: icon, title: title, tint: tint, scale: panel.backingScaleFactor)
        root.addSublayer(card)

        // A quadratic curve that drops toward the dock first, like a genie
        // falling into place; the restore path is the exact mirror.
        let control = CGPoint(
            x: windowCenter.x + (capsuleCenter.x - windowCenter.x) * 0.2,
            y: capsuleCenter.y + (windowCenter.y - capsuleCenter.y) * 0.65
        )
        let intoGroup = direction == .intoGroup
        let start = intoGroup ? windowCenter : capsuleCenter
        let end = intoGroup ? capsuleCenter : windowCenter
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)

        let position = CAKeyframeAnimation(keyPath: "position")
        position.path = path

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = intoGroup ? 1 : landedScale
        scale.toValue = intoGroup ? landedScale : 1

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        if intoGroup {
            opacity.values = [1, 0.95, 0]
            opacity.keyTimes = [0, 0.72, 1]
        } else {
            opacity.values = [0, 1, 1, 0]
            opacity.keyTimes = [0, 0.18, 0.78, 1]
        }

        let group = CAAnimationGroup()
        group.animations = [position, scale, opacity]
        group.duration = intoGroup ? Self.duration : Self.duration + 0.06
        group.timingFunction = intoGroup
            ? CAMediaTimingFunction(controlPoints: 0.5, 0, 0.25, 1)
            : CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.position = end
        card.opacity = 0
        card.transform = CATransform3DMakeScale(intoGroup ? landedScale : 1, intoGroup ? landedScale : 1, 1)
        CATransaction.commit()

        activePanels.append(panel)
        panel.orderFrontRegardless()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak panel] in
            MainActor.assumeIsolated {
                if let panel {
                    panel.orderOut(nil)
                    self?.activePanels.removeAll { $0 === panel }
                }
                completion()
            }
        }
        card.add(group, forKey: "kosmodock.minimize")
        CATransaction.commit()
    }

    /// Translucent stand-in for the window: tinted glass, a title-bar strip,
    /// the app's icon and the window title.
    private func makeCard(size: CGSize, icon: NSImage, title: String, tint: NSColor, scale: CGFloat) -> CALayer {
        let bounds = CGRect(origin: .zero, size: size)
        let radius: CGFloat = 12

        let card = CALayer()
        card.bounds = bounds
        card.cornerRadius = radius
        card.cornerCurve = .continuous
        card.backgroundColor = NSColor(white: 0.10, alpha: 0.78).cgColor
        card.borderWidth = 1
        card.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.4
        card.shadowRadius = 20
        card.shadowOffset = CGSize(width: 0, height: -10)

        let wash = CAGradientLayer()
        wash.frame = bounds
        wash.cornerRadius = radius
        wash.cornerCurve = .continuous
        wash.colors = [tint.withAlphaComponent(0.38).cgColor, tint.withAlphaComponent(0.06).cgColor]
        wash.startPoint = CGPoint(x: 0.5, y: 1)
        wash.endPoint = CGPoint(x: 0.5, y: 0)
        card.addSublayer(wash)

        let barHeight = min(28, size.height * 0.12)
        let bar = CALayer()
        bar.frame = CGRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)
        bar.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        bar.cornerRadius = radius
        bar.cornerCurve = .continuous
        bar.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        card.addSublayer(bar)

        let iconSide = min(128, min(size.width, size.height) * 0.38)
        let iconLayer = CALayer()
        iconLayer.bounds = CGRect(x: 0, y: 0, width: iconSide, height: iconSide)
        iconLayer.position = CGPoint(x: size.width / 2, y: size.height / 2 + iconSide * 0.12)
        var proposed = CGRect(x: 0, y: 0, width: iconSide * scale, height: iconSide * scale)
        iconLayer.contents = icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        iconLayer.contentsGravity = .resizeAspect
        card.addSublayer(iconLayer)

        if !title.isEmpty {
            let text = CATextLayer()
            text.string = title
            text.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            text.fontSize = 15
            text.foregroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            text.alignmentMode = .center
            text.truncationMode = .end
            text.contentsScale = scale
            let width = min(size.width - 40, 420)
            text.frame = CGRect(x: (size.width - width) / 2, y: iconLayer.position.y - iconSide / 2 - 30, width: width, height: 20)
            card.addSublayer(text)
        }
        return card
    }
}
