import XCTest
@testable import Kosmodock

/// The app's own items, out of a menu read from the native Dock.
final class DockMenuTests: XCTestCase {
    private func item(_ title: String, enabled: Bool = true, submenu: Bool = false) -> RawDockMenuItem {
        RawDockMenuItem(title: title, isEnabled: enabled, hasSubmenu: submenu)
    }

    private let separator = RawDockMenuItem(title: "", isEnabled: false)

    func testFinderKeepsItsItemsAndWindowsButNotTheDocksBlock() {
        // As read on macOS 27 in Portuguese, window list shortened.
        let finder = [
            item("Nova Janela do Finder"), item("Nova Pasta Inteligente"), item("Buscar…"), separator,
            item("Ir para Pasta…"), item("Conectar ao Servidor…"), separator,
            item("Downloads"), item("www"), separator,
            item("Mostrar Todas as Janelas"), item("Ocultar"), item("Ocultar Outros"),
        ]
        let entries = DockMenuFilter.appItems(finder)
        XCTAssertEqual(entries.map(\.title), ["Nova Janela do Finder", "Nova Pasta Inteligente", "Buscar…", "", "Ir para Pasta…", "Conectar ao Servidor…", "", "Downloads", "www"])
        XCTAssertEqual(entries.first { $0.title == "Downloads" }?.index, 7, "indexes point into the native menu")
    }

    func testOptionsSubmenuAndTrailingSeparatorsGo() {
        let safari = [
            item("GitHub"), separator, item("New Window"), item("New Private Window", enabled: false), separator,
            item("Options", submenu: true), separator, item("Show All Windows"), item("Hide"), item("Quit"),
        ]
        let entries = DockMenuFilter.appItems(safari)
        XCTAssertEqual(entries.map(\.title), ["GitHub", "", "New Window", "New Private Window"])
        XCTAssertEqual(entries.last?.isEnabled, false)
        XCTAssertFalse(entries.contains { $0.isSeparator && $0 == entries.last })
    }

    func testAnAppThatIsntRunningHasNothingOfItsOwn() {
        XCTAssertEqual(DockMenuFilter.appItems([item("Options", submenu: true), separator, item("Open")]), [])
        XCTAssertEqual(DockMenuFilter.appItems([]), [])
        XCTAssertEqual(DockMenuFilter.appItems([item("Quit")]), [], "no separator: nothing is the app's")
    }

    func testRepeatedSeparatorsCollapse() {
        let menu = [separator, item("A"), separator, separator, item("B"), separator, item("Quit")]
        XCTAssertEqual(DockMenuFilter.appItems(menu).map(\.title), ["A", "", "B"])
    }
}
