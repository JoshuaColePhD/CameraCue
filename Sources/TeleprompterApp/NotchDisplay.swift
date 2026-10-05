import AppKit

/// Screen-space geometry is independent of window ownership and the current take.
struct NotchDisplay: Equatable {
    let id: UInt32
    let bounds: CGRect
    let visibleBounds: CGRect
    let cameraHousing: CGFloat
    let safeTop: CGFloat
    let scale: CGFloat

    @MainActor init(screen: NSScreen) {
        id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        bounds = screen.frame
        visibleBounds = screen.visibleFrame
        safeTop = screen.safeAreaInsets.top
        scale = screen.backingScaleFactor
        cameraHousing = Self.measureCameraHousing(bounds: bounds, safeTop: safeTop,
                                                  leftArea: screen.auxiliaryTopLeftArea,
                                                  rightArea: screen.auxiliaryTopRightArea,
                                                  scale: scale)
    }

    /// Auxiliary areas describe the usable shoulders, in points (not backing pixels).
    /// A positive safe inset is physical-obstruction evidence even while macOS is
    /// repopulating the auxiliary rectangles after a lid/scaling/Space transition.
    static func measureCameraHousing(bounds: CGRect, safeTop: CGFloat,
                                     leftArea: CGRect?, rightArea: CGRect?, scale: CGFloat) -> CGFloat {
        let pixelScale = max(1, scale)
        if let leftArea, let rightArea, leftArea.width > 0, rightArea.width > 0 {
            // Use widths so the calculation is independent of the display's origin.
            // Reserve symmetrically around the camera, including an uneven shoulder.
            let width = bounds.width - 2 * min(leftArea.width, rightArea.width)
            if width > 0, width < bounds.width / 2 {
                return ceil(width * pixelScale) / pixelScale
            }
        }
        guard safeTop > 0 else { return 0 }
        // Conservative fallback scaled with the reported notch height. Never add a
        // fictitious camera spacer to an external or older, unobstructed display.
        return ceil(max(190, safeTop * 6) * pixelScale) / pixelScale
    }

    init(id: UInt32, bounds: CGRect, visibleBounds: CGRect, cameraHousing: CGFloat = 0, safeTop: CGFloat = 0, scale: CGFloat = 2) {
        self.id = id; self.bounds = bounds; self.visibleBounds = visibleBounds
        self.cameraHousing = cameraHousing; self.safeTop = safeTop; self.scale = scale
    }

    var reservedMenuHeight: CGFloat { max(safeTop, bounds.maxY - visibleBounds.maxY) }
    var showsCompact: Bool { reservedMenuHeight >= 18 }
    var readerHeightRange: ClosedRange<CGFloat> {
        // Leave the lower part of the working display and its Dock available.
        let maximum = max(1, min(NotchReaderSize.maximumHeight, bounds.height * 0.75,
                                 bounds.maxY - visibleBounds.minY - 24))
        return min(NotchReaderSize.defaultHeight, maximum)...maximum
    }
    var layout: NotchLayout { layout(preferredHeight: NotchReaderSize.defaultHeight) }
    func layout(preferredHeight: CGFloat) -> NotchLayout {
        let header = max(18, reservedMenuHeight > 0 ? reservedMenuHeight : 24)
        let range = readerHeightRange
        let height = min(range.upperBound, max(range.lowerBound, NotchReaderSize.validHeight(preferredHeight)))
        let alignedHeight = floor(height * max(1, scale)) / max(1, scale)
        return NotchLayout(size: CGSize(width: min(max(548, cameraHousing + 368), bounds.width - 32),
                                       height: alignedHeight),
                           housing: cameraHousing, header: header)
    }
    var panelFrame: CGRect { panelFrame(preferredHeight: NotchReaderSize.defaultHeight) }
    func panelFrame(preferredHeight: CGFloat) -> CGRect {
        let size = layout(preferredHeight: preferredHeight).size
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height,
                      width: size.width, height: size.height)
    }
    var compactFrame: CGRect {
        CGRect(x: panelFrame.minX + layout.compactBounds.minX, y: bounds.maxY - layout.header,
               width: layout.compactWidth, height: layout.header)
    }
}

struct NotchDisplaySelection {
    private(set) var selectedID: UInt32?
    private(set) var locked = false

    mutating func initialize(preferred: UInt32?, available: [NotchDisplay]) {
        guard selectedID == nil else { return }
        selectedID = available.first(where: { $0.id == preferred })?.id ?? available.first?.id
    }
    mutating func click(at point: CGPoint, available: [NotchDisplay]) -> Bool {
        guard !locked, let screen = available.first(where: { $0.bounds.contains(point) }), screen.id != selectedID else { return false }
        selectedID = screen.id
        return true
    }
    @MainActor mutating func click(event: NSEvent, available: [NotchDisplay]) -> Bool {
        // The live pointer may already be on a different display by the time a
        // queued click arrives. Select using the location captured by the event.
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        return click(at: point, available: available)
    }
    mutating func setLocked(_ value: Bool) { locked = value }
    /// True means a selected display vanished. The controller must pause an active take.
    mutating func reconcile(available: [NotchDisplay], fallback: UInt32?) -> Bool {
        guard !available.contains(where: { $0.id == selectedID }) else { return false }
        let disconnected = selectedID != nil
        selectedID = available.first(where: { $0.id == fallback })?.id ?? available.first?.id
        return disconnected
    }
}
