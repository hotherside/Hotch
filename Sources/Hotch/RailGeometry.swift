import Foundation
import CoreGraphics

/// Shared geometry for the six permanent rail targets. Coordinates within a
/// side rail run down from its top; bottom-bar coordinates run from its left.
enum RailGeometry {
    enum Side: CaseIterable { case left, right, bottom }
    static let width: CGFloat = 42
    static let height: CGFloat = 312
    static let slot: CGFloat = 34
    static let count = 6
    static let endInset: CGFloat = 54
    static let bottomInset: CGFloat = 16
    static let bottomWidth = bottomInset * 2 + slot * CGFloat(count)
    static let taper: CGFloat = 52
    static let cardGap: CGFloat = 8
    static let screenInset: CGFloat = 6

    static func center(_ index: Int, bottom: Bool = false) -> CGFloat {
        (bottom ? bottomInset : endInset) + slot * (CGFloat(index) + 0.5)
    }

    static func nearestSlot(to position: CGFloat, bottom: Bool = false) -> Int {
        min(count - 1, max(0, Int(((position - (bottom ? bottomInset : endInset)) / slot).rounded(.down))))
    }

    /// Reserve the card's largest supported height once when opening, so all
    /// its sections share one attachment point even near the display edges.
    static func cardAttachment(rail: CGRect, visible: CGRect, side: Side, maximumHeight: CGFloat) -> CGFloat {
        if side == .bottom {
            return max(visible.minY + screenInset,
                       min(rail.maxY + cardGap, visible.maxY - screenInset - maximumHeight))
        }
        return min(visible.maxY - screenInset,
                   max(rail.maxY, visible.minY + screenInset + maximumHeight))
    }

    static func cardFrame(size: CGSize, rail: CGRect, visible: CGRect, side: Side, attachment: CGFloat) -> CGRect {
        let desiredX: CGFloat
        switch side {
        case .left: desiredX = rail.maxX + cardGap
        case .right: desiredX = rail.minX - cardGap - size.width
        case .bottom: desiredX = rail.midX - size.width / 2
        }
        let x = max(visible.minX + screenInset, min(desiredX, visible.maxX - screenInset - size.width))
        let y = side == .bottom ? attachment : attachment - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The convex bridge covers a diagonal journey from any target into the
    /// card, including short pages whose bottom sits above a low rail target.
    /// Unlike the entire bounding rectangle, it drops away from that journey.
    static func hoverBridgeContains(_ point: CGPoint, rail: CGRect, card: CGRect) -> Bool {
        func corners(_ rect: CGRect) -> [CGPoint] {
            [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        }
        func cross(_ origin: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)
        }
        let points = (corners(rail.insetBy(dx: -8, dy: -10)) + corners(card.insetBy(dx: -10, dy: -10)))
            .sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        var lower: [CGPoint] = []
        for p in points {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in points.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        let hull = Array(lower.dropLast()) + Array(upper.dropLast())
        guard hull.count >= 3 else { return false }
        return hull.indices.allSatisfy { cross(hull[$0], hull[($0 + 1) % hull.count], point) >= 0 }
    }
}
