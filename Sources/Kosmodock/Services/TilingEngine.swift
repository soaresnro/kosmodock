import CoreGraphics
import Foundation

/// Pure layout math for the tiling presets. Works in a top-left-origin space
/// (the Accessibility API's global coordinates), so `.minYEdge` is the top.
enum TilingEngine {
    static func frames(
        for layout: TilingLayout,
        count: Int,
        in bounds: CGRect,
        gap: CGFloat = 0,
        roundToPixels: Bool = true
    ) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        // Half the gap around the outer edge plus half around every cell gives
        // a uniform `gap` between windows and between windows and the screen.
        let half = max(0, gap) / 2
        let area = bounds.insetBy(dx: half, dy: half)

        let cells: [CGRect]
        switch layout {
        case .maximizeAll:
            cells = Array(repeating: area, count: count)

        case .splitHorizontal50_50:
            if count == 1 {
                cells = [area]
            } else {
                let (left, right) = area.divided(atDistance: area.width / 2, from: .minXEdge)
                cells = [left] + rows(in: right, count: count - 1)
            }

        case .dev70_30Stack:
            if count == 1 {
                cells = [area]
            } else {
                let (main, side) = area.divided(atDistance: area.width * 0.7, from: .minXEdge)
                cells = [main] + rows(in: side, count: count - 1)
            }

        case .mainPlusBottom25:
            if count == 1 {
                cells = [area]
            } else {
                let (top, bottom) = area.divided(atDistance: area.height * 0.75, from: .minYEdge)
                cells = [top] + columns(in: bottom, count: count - 1)
            }

        case .grid2x2:
            switch count {
            case 1:
                cells = [area]
            case 2:
                cells = columns(in: area, count: 2)
            default:
                let columnCount = count <= 4 ? 2 : Int(ceil(sqrt(Double(count))))
                let rowCount = Int(ceil(Double(count) / Double(columnCount)))
                cells = Array(grid(in: area, columns: columnCount, rows: rowCount).prefix(count))
            }
        }

        return cells.map { cell in
            let inset = cell.insetBy(dx: half, dy: half)
            guard roundToPixels else { return inset }
            return CGRect(x: inset.minX.rounded(), y: inset.minY.rounded(),
                          width: inset.width.rounded(), height: inset.height.rounded())
        }
    }

    /// Converts an AppKit rect (bottom-left origin) to Accessibility
    /// coordinates (top-left origin of the primary display).
    static func accessibilityRect(fromCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func rows(in rect: CGRect, count: Int) -> [CGRect] {
        let height = rect.height / CGFloat(count)
        return (0..<count).map { CGRect(x: rect.minX, y: rect.minY + CGFloat($0) * height, width: rect.width, height: height) }
    }

    private static func columns(in rect: CGRect, count: Int) -> [CGRect] {
        let width = rect.width / CGFloat(count)
        return (0..<count).map { CGRect(x: rect.minX + CGFloat($0) * width, y: rect.minY, width: width, height: rect.height) }
    }

    private static func grid(in rect: CGRect, columns: Int, rows: Int) -> [CGRect] {
        let width = rect.width / CGFloat(columns)
        let height = rect.height / CGFloat(rows)
        var cells: [CGRect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                cells.append(CGRect(x: rect.minX + CGFloat(column) * width, y: rect.minY + CGFloat(row) * height,
                                    width: width, height: height))
            }
        }
        return cells
    }
}
