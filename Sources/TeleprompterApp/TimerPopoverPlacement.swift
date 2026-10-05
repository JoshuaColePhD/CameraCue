import AppKit

enum TimerPopoverPlacement {
    static let width: CGFloat = 380
    static func edge(anchor: CGRect, screen: CGRect) -> NSRectEdge {
        let clearance = width / 2 + 16
        if anchor.midX > screen.maxX - clearance { return .minX }
        if anchor.midX < screen.minX + clearance { return .maxX }
        return .maxY
    }
}
