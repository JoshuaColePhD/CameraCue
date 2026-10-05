import AppKit

enum NotchReaderSize {
    static let defaultHeight: CGFloat = 248
    static let maximumHeight: CGFloat = 680
    static let preferenceKey = "notchReaderHeight"

    static func validHeight(_ height: CGFloat) -> CGFloat {
        height.isFinite ? min(maximumHeight, max(defaultHeight, height)) : defaultHeight
    }
    static func load(from defaults: UserDefaults?) -> CGFloat {
        guard let value = defaults?.object(forKey: preferenceKey) as? NSNumber else { return defaultHeight }
        return validHeight(CGFloat(value.doubleValue))
    }
}

/// Screen coordinates remain stable as the panel's bottom edge moves. Using local
/// coordinates here would feed each window resize back into the next drag delta.
struct NotchResizeSession {
    let height: CGFloat
    let screenY: CGFloat
    func height(atScreenY y: CGFloat) -> CGFloat { height + screenY - y }
}

/// Native tracking keeps the drag attached to the grip even outside the window.
final class NotchResizeHandle: NSView {
    var onBegin: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    var onAdjust: ((CGFloat) -> Void)?
    var onSetHeight: ((CGFloat) -> Void)?
    var allowsInteraction = true
    private(set) var isDragging = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag up or down to show more or fewer words. Double-click to reset height."
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Reader height")
        setAccessibilityHelp("Drag the bottom edge to resize the reader. Increase or decrease to adjust by 40 points.")
        setAccessibilityOrientation(.vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { allowsInteraction && !isHidden }
    override func accessibilityPerformIncrement() -> Bool { adjust(by: 40) }
    override func accessibilityPerformDecrement() -> Bool { adjust(by: -40) }
    override func setAccessibilityValue(_ value: Any?) {
        guard allowsInteraction, !isHidden, let value = value as? NSNumber else { return }
        onSetHeight?(CGFloat(value.doubleValue))
    }
    private func adjust(by amount: CGFloat) -> Bool {
        guard allowsInteraction, !isHidden, let onAdjust else { return false }
        onAdjust(amount)
        return true
    }
    func configure(height: CGFloat, range: ClosedRange<CGFloat>) {
        super.setAccessibilityValue(NSNumber(value: Double(height)))
        setAccessibilityMinValue(NSNumber(value: Double(range.lowerBound)))
        setAccessibilityMaxValue(NSNumber(value: Double(range.upperBound)))
    }
    override func resetCursorRects() {
        if allowsInteraction && !isHidden { addCursorRect(bounds, cursor: .resizeUpDown) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(red: 0.79, green: 0.73, blue: 0.98, alpha: 1)
        color.withAlphaComponent(isDragging ? 0.95 : hovered ? 0.8 : 0.32).setFill()
        NSBezierPath(roundedRect: CGRect(x: bounds.midX - 18, y: bounds.midY - 1.5, width: 36, height: 3),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard allowsInteraction, !isHidden else { return }
        if event.clickCount == 2 { cancelDrag(); onReset?(); return }
        guard !isDragging else { return }
        isDragging = true
        NSCursor.resizeUpDown.push()
        needsDisplay = true
        onBegin?(screenPoint(for: event))
    }
    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag?(screenPoint(for: event))
    }
    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        onDrag?(screenPoint(for: event))
        cancelDrag()
    }
    func cancelDrag() {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        needsDisplay = true
        onEnd?()
    }
    private func screenPoint(for event: NSEvent) -> CGPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }
}
