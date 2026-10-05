import AppKit
import SwiftUI

/// Uses the real native shell, controls, reader, and presentation model.
struct LiveNotchPreview: NSViewRepresentable {
    @ObservedObject var model: TeleprompterModel
    let layout: NotchLayout
    let scale: CGFloat
    let date: Date

    func makeNSView(context: Context) -> NotchSurface {
        let view = NotchSurface(model: model, interactive: false)
        view.configure(size: layout.size, housing: layout.housing, header: layout.header, scale: scale)
        view.updateControls(model: model, expanded: true, at: date)
        view.setExpanded(true, animated: false)
        view.setAccessibilityLabel("Live notch preview. Controls are noninteractive.")
        context.coordinator.layout = layout
        return view
    }
    func updateNSView(_ view: NotchSurface, context: Context) {
        if context.coordinator.layout != layout {
            view.configure(size: layout.size, housing: layout.housing, header: layout.header, scale: scale)
            context.coordinator.layout = layout
        }
        view.updateControls(model: model, expanded: true, at: date)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var layout: NotchLayout? }
}

/// Captures the actual Studio window; no assumptions about the mouse or primary display.
struct StudioWindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowProbe { WindowProbe(onWindow: onWindow) }
    func updateNSView(_ view: WindowProbe, context: Context) {
        view.onWindow = onWindow
    }
    private static func alignToolbar(in window: NSWindow) {
        window.titlebarSeparatorStyle = .none
        guard let content = window.contentView else { return }
        func sidebarSplit(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2 { return split }
            for child in view.subviews {
                if let split = sidebarSplit(in: child) { return split }
            }
            return nil
        }
        guard let split = sidebarSplit(in: content) else { return }
        window.toolbarStyle = .unified
        for separator in window.toolbar?.items.compactMap({ $0 as? NSTrackingSeparatorToolbarItem }) ?? [] {
            separator.splitView = split
            separator.dividerIndex = 0
        }
    }
    final class WindowProbe: NSView {
        var onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { [weak self, weak window] in
                if let window {
                    StudioWindowReader.alignToolbar(in: window)
                    self?.onWindow(window)
                }
            } }
        }
    }
}
