import AppKit

@main
enum KosmodockMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Accessory: no Dock icon, no menu bar takeover (LSUIElement in the bundle).
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
