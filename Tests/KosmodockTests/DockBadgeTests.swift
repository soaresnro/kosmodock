import Foundation
import XCTest
@testable import Kosmodock

/// Records shaped like the native Dock's AX items (`AXDockItem` children of
/// its `AXList`), as read on macOS 27.
final class DockBadgeTests: XCTestCase {
    private let app = DockBadgeMapping.applicationSubrole
    private let bundleIDs = [
        "/System/Applications/Mail.app": "com.apple.mail",
        "/Applications/Slack.app": "com.tinyspeck.slackmacgap",
        "/System/Applications/App Store.app": "com.apple.AppStore",
    ]

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: path.hasSuffix(".app")) }

    private func bundleID(_ url: URL) -> String? { bundleIDs[url.path] }

    private func record(_ subrole: String?, _ path: String?, _ label: String?) -> DockItemRecord {
        DockItemRecord(subrole: subrole, url: path.map(url), statusLabel: label)
    }

    // MARK: Mapping

    func testMapsBadgedAppItemsToBundleIDs() {
        let records = [
            record(app, "/System/Applications/Mail.app", "3"),
            record(app, "/Applications/Slack.app", "•"),
            record(app, "/System/Applications/App Store.app", nil),
        ]
        XCTAssertEqual(DockBadgeMapping.badges(from: records, bundleID: bundleID), [
            "com.apple.mail": "3",
            "com.tinyspeck.slackmacgap": "•",
        ])
    }

    func testSkipsItemsThatAreNotBadgedApps() {
        let records = [
            // A Handoff item's AXStatusLabel holds a device id, not a badge.
            record("AXHandoffDockItem", nil, "com.apple.iphone-15-1"),
            record("AXSeparatorDockItem", nil, nil),
            record("AXTrashDockItem", nil, "1"),
            // An unbundled executable has a URL but no bundle identifier.
            record(app, "/tmp/badgeprobe", "5"),
            record(app, nil, "2"),
            record(nil, "/System/Applications/Mail.app", "4"),
        ]
        XCTAssertEqual(DockBadgeMapping.badges(from: records, bundleID: bundleID), [:])
    }

    func testResolvesOnlyBadgedItems() {
        var resolved: [String] = []
        let records = [
            record(app, "/System/Applications/Mail.app", "1"),
            record(app, "/Applications/Slack.app", nil),
            record("AXHandoffDockItem", "/Applications/Slack.app", "device"),
        ]
        _ = DockBadgeMapping.badges(from: records) { url in
            resolved.append(url.path)
            return self.bundleID(url)
        }
        XCTAssertEqual(resolved, ["/System/Applications/Mail.app"])
    }

    func testKeepsTheTextWhenAnAppIsListedTwice() {
        let records = [
            record(app, "/System/Applications/Mail.app", "•"),
            record(app, "/System/Applications/Mail.app", "7"),
            record(app, "/System/Applications/Mail.app", " "),
        ]
        XCTAssertEqual(DockBadgeMapping.badges(from: records, bundleID: bundleID), ["com.apple.mail": "7"])
    }

    // MARK: Display

    func testDotAndBlankLabelsBecomeADot() {
        for label in ["", " ", "\n", "•", " • ", "●"] {
            XCTAssertEqual(BadgeDisplay(label: label), .dot, String(reflecting: label))
        }
    }

    func testShortLabelsAreShownTrimmed() {
        XCTAssertEqual(BadgeDisplay(label: "3"), .text("3"))
        XCTAssertEqual(BadgeDisplay(label: "99+"), .text("99+"))
        XCTAssertEqual(BadgeDisplay(label: " 12 "), .text("12"))
        XCTAssertEqual(BadgeDisplay(label: "New"), .text("New"))
        XCTAssertEqual(BadgeDisplay(label: "12345"), .text("12345"))
    }

    func testLongLabelsAreShortened() {
        XCTAssertEqual(BadgeDisplay(label: "123456"), .text("1234…"))
        XCTAssertEqual(BadgeDisplay(label: "12345678"), .text("1234…"))
        XCTAssertEqual(BadgeDisplay(label: "Updates available"), .text("Upda…"))
        if case .text(let text) = BadgeDisplay(label: String(repeating: "9", count: 40)) {
            XCTAssertEqual(text.count, BadgeDisplay.maxLength)
        } else {
            XCTFail("a long label is text")
        }
    }

    // MARK: Publishing

    func testPublishesOnlyWhenBadgesChange() {
        var state = DockBadgeState()
        XCTAssertNil(state.apply([:]), "no badges before, none now")
        XCTAssertEqual(state.apply(["com.apple.mail": "3"]), ["com.apple.mail": "3"])
        XCTAssertNil(state.apply(["com.apple.mail": "3"]), "same reading")
        XCTAssertEqual(state.apply(["com.apple.mail": "4"]), ["com.apple.mail": "4"])
        XCTAssertEqual(state.apply([:]), [:], "badge cleared")
        XCTAssertNil(state.apply([:]))
    }

    func testKeepsBadgesThroughAFewFailedPolls() {
        var state = DockBadgeState()
        _ = state.apply(["com.apple.mail": "3"])
        for _ in 1..<DockBadgeState.failuresBeforeClearing {
            XCTAssertNil(state.apply(nil), "the Dock is restarting")
        }
        XCTAssertEqual(state.badges, ["com.apple.mail": "3"])
        XCTAssertNil(state.apply(["com.apple.mail": "3"]), "back with the same badges")
        XCTAssertEqual(state.consecutiveFailures, 0)
    }

    func testClearsBadgesWhenTheDockStaysUnreadable() {
        var state = DockBadgeState()
        _ = state.apply(["com.apple.mail": "3"])
        var published: [[String: String]] = []
        for _ in 0..<(DockBadgeState.failuresBeforeClearing + 2) {
            if let badges = state.apply(nil) { published.append(badges) }
        }
        XCTAssertEqual(published, [[:]], "cleared once")
        XCTAssertEqual(state.badges, [:])
    }

    // MARK: Setting

    func testSettingDefaultsToOnAndDecodes() throws {
        XCTAssertTrue(BehaviorConfig().showsNotificationBadges)
        let old = try JSONDecoder().decode(BehaviorConfig.self, from: Data(#"{ "focusMode": true }"#.utf8))
        XCTAssertTrue(old.showsNotificationBadges, "configs without the key keep badges on")
        let off = try JSONDecoder().decode(BehaviorConfig.self, from: Data(#"{ "showsNotificationBadges": false }"#.utf8))
        XCTAssertFalse(off.showsNotificationBadges)
        XCTAssertThrowsError(try JSONDecoder().decode(BehaviorConfig.self, from: Data(#"{ "showsNotificationBadges": "yes" }"#.utf8)))
    }
}
