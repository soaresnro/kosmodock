import Foundation

extension AppModel {
    /// Reads the native Dock's badges only while they are wanted and
    /// Accessibility lets Kosmodock read them.
    func applyNotificationBadges() {
        dockBadges.setActive(config.behavior.showsNotificationBadges && windows.isTrusted)
    }

    /// The badge the native Dock shows for `app` ("3", "•"), if any.
    func notificationBadge(for app: DockApp) -> String? {
        guard config.behavior.showsNotificationBadges else { return nil }
        return workspace.bundleID(for: app).flatMap { dockBadges.badges[$0] }
    }
}
