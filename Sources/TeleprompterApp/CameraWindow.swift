import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
    }
}

@MainActor enum CameraWindow {
    static func configure(_ window: NSWindow) {
        window.title = "CameraCue Studio"
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 300, height: 210)
        window.backgroundColor = NSColor(red: 0.055, green: 0.065, blue: 0.09, alpha: 1)
        if !UserDefaults.standard.bool(forKey: "cameraWindowPositioned") {
            placeBelowCamera(window)
            UserDefaults.standard.set(true, forKey: "cameraWindowPositioned")
        }
    }
    static func placeBelowCamera(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let width = min(390, max(320, frame.width * 0.30))
        let height = min(350, max(260, frame.height * 0.37))
        let x = frame.midX - width / 2
        // The camera is centered above the display. Leave a little room below the menu bar.
        let y = frame.maxY - height - 16
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: true)
        window.makeKeyAndOrderFront(nil)
    }
}
