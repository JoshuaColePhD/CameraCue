import XCTest
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import TeleprompterApp

/// Opt-in documentation capture of production views with an isolated script library
/// and injected transcript callbacks. Never opens a camera or microphone.
@MainActor final class DocumentationMediaTests: XCTestCase {
    func testRenderDocumentationMedia() async throws {
        guard let path = ProcessInfo.processInfo.environment["CAMERACUE_DOC_MEDIA"] else {
            throw XCTSkip("Opt-in documentation renderer; no user data is captured")
        }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let body = "[Take a breath.]\nYour next great presentation starts with a clear idea.\nWrite the words you want to say.\nGive the important phrases a little room.\nThen practice at your own pace.\nCameraCue keeps your next line close to the lens.\nPause when you need a moment.\nFind your place and keep going.\nYour voice leads the way."
        let titles = ["Your next great presentation", "A welcome worth remembering", "The story behind the idea", "A lesson in three minutes", "A thoughtful update"]
        let records = titles.enumerated().map { index, title in
            ScriptRecord(id: UUID(), title: title, body: body, modifiedAt: Date(timeIntervalSince1970: 1_791_234_000 - Double(index * 3600)))
        }
        try JSONEncoder().encode(records).write(to: storage.appendingPathComponent("scripts.json"))
        let library = ScriptLibrary(storageDirectory: storage)
        let capture = DocumentationSpeech()
        let model = TeleprompterModel(capture: capture, defaults: nil)
        model.load(records[0])
        let controller = NotchController(defaults: nil)
        let host = NSHostingView(rootView: StudioView().environmentObject(library).environmentObject(model).environmentObject(controller).frame(width: 1230, height: 800).environment(\.controlActiveState, .active))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1230, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(600))
        resizeSidebar(host)
        try await Task.sleep(for: .milliseconds(200))
        try png(host, to: folder.appendingPathComponent("studio.png"))
        let surface = NotchSurface(model: model, interactive: false)
        surface.reduceMotionOverride = true
        surface.configure(size: CGSize(width: 548, height: 380), housing: 0, header: 28, scale: 2)
        surface.setExpanded(true, animated: false)
        surface.updateControls(model: model, expanded: true)
        window.setContentSize(CGSize(width: 548, height: 380)); window.contentView = surface
        try await Task.sleep(for: .milliseconds(200))
        try png(surface, to: folder.appendingPathComponent("reader.png"))
        model.load(ScriptRecord(id: UUID(), title: "A natural read", body: "Speak naturally. Pause when you need to. Keep going.", modifiedAt: .now))
        await model.start()
        XCTAssertTrue(model.isRunning)
        let url = folder.appendingPathComponent("voice-follow.gif")
        let endpoints = Array(2...model.document.tokens.count)
        let gif = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, endpoints.count, nil))
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for endpoint in endpoints {
            capture.onTranscript?(model.document.tokens.prefix(endpoint).joined(separator: " "))
            surface.updateControls(model: model, expanded: true)
            try await Task.sleep(for: .milliseconds(500))
            let rep = try bitmap(surface)
            let image = try XCTUnwrap(rep.cgImage)
            CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.65]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(gif))
        model.finish()
    }
    private func resizeSidebar(_ view: NSView) {
        if let split = view as? NSSplitView, split.isVertical, split.subviews.count > 1 {
            split.setPosition(234, ofDividerAt: 0)
        }
        for child in view.subviews { resizeSidebar(child) }
    }
    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
    private func png(_ view: NSView, to url: URL) throws {
        try XCTUnwrap(try bitmap(view).representation(using: .png, properties: [:])).write(to: url)
    }
}
@MainActor private final class DocumentationSpeech: SpeechCapturing {
    var state: SpeechFollower.State = .idle
    var onTranscript: ((String) -> Void)?
    var onUnexpectedStop: (() -> Void)?
    func start() async { state = .listening }
    func pause() { state = .paused }
    func stop() { state = .idle }
}
