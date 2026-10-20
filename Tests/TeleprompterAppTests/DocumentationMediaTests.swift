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
        let shortcut = PresentationShortcut()
        let host = NSHostingView(rootView: StudioView().environmentObject(library).environmentObject(model).environmentObject(controller).environmentObject(shortcut).environment(\.controlActiveState, .active))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1230, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(600))
        resizeSidebar(host)
        try await Task.sleep(for: .milliseconds(200))
        try png(host, to: folder.appendingPathComponent("studio.png"))
        var tourFrames = [try tourFrame(host, delay: 2.2)]
        window.setContentSize(CGSize(width: 900, height: 680))
        try await Task.sleep(for: .milliseconds(300))
        resizeSidebar(host)
        try await Task.sleep(for: .milliseconds(200))
        try png(host, to: folder.appendingPathComponent("studio-compact.png"))

        window.setContentSize(CGSize(width: 1230, height: 800))
        controller.onReturnToScript?()
        try await Task.sleep(for: .milliseconds(500))
        resizeSidebar(host)
        try await Task.sleep(for: .milliseconds(200))
        try png(host, to: folder.appendingPathComponent("write.png"))
        tourFrames.append(try tourFrame(host, delay: 2.8))

        model.video.enabled = true
        controller.onViewRecording?()
        try await Task.sleep(for: .milliseconds(600))
        try png(host, to: folder.appendingPathComponent("record-setup.png"))
        tourFrames.append(try tourFrame(host, delay: 2.8))
        // Showing setup never starts a camera. Disable video before replaying speech.
        model.video.enabled = false

        let blankStorage = storage.appendingPathComponent("blank-library")
        try FileManager.default.createDirectory(at: blankStorage, withIntermediateDirectories: true)
        let blank = ScriptRecord(id: UUID(), title: "Untitled Script", body: "", modifiedAt: .now)
        try JSONEncoder().encode([blank]).write(to: blankStorage.appendingPathComponent("scripts.json"))
        let blankLibrary = ScriptLibrary(storageDirectory: blankStorage)
        let emptyHost = NSHostingView(rootView: ScriptLibraryHome(
            entries: blankLibrary.dashboardEntries(), selectedID: nil,
            search: .constant(""), filter: .constant(.all), sort: .constant(.recent),
            canRehearse: true, storageNotice: nil, isHome: true,
            importProgress: [:], latestImportID: nil, importingTitle: nil,
            onRetryFormatting: { _ in }, canDelete: false, onViewAll: {},
            onNew: {}, onImport: {}, onDevelop: {}, onOpen: { _, _ in },
            onRename: { _ in }, onDuplicate: { _ in }, onFavorite: { _ in },
            onDelete: { _ in }, onDrop: { _ in false }))
        window.contentView = emptyHost
        window.setContentSize(CGSize(width: 666, height: 680))
        try await Task.sleep(for: .milliseconds(300))
        try png(emptyHost, to: folder.appendingPathComponent("studio-empty.png"))
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
        let readerStage = DocumentationReaderStage(reader: surface)
        window.setContentSize(CGSize(width: 1230, height: 800))
        window.contentView = readerStage
        try await Task.sleep(for: .milliseconds(200))
        tourFrames.append(try tourFrame(readerStage, delay: 1))
        for endpoint in endpoints {
            capture.onTranscript?(model.document.tokens.prefix(endpoint).joined(separator: " "))
            surface.updateControls(model: model, expanded: true)
            try await Task.sleep(for: .milliseconds(500))
            let rep = try bitmap(surface)
            let image = try XCTUnwrap(rep.cgImage)
            CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.65]] as CFDictionary)
            tourFrames.append(try tourFrame(readerStage, delay: 0.65))
            if endpoint == endpoints[endpoints.count / 2] {
                try png(readerStage, to: folder.appendingPathComponent("voice-follow-tour.png"))
            }
        }
        XCTAssertTrue(CGImageDestinationFinalize(gif))
        model.pause()
        surface.updateControls(model: model, expanded: true)
        try await Task.sleep(for: .milliseconds(200))
        tourFrames.append(try tourFrame(readerStage, delay: 1.3))
        model.finish()

        let tourURL = folder.appendingPathComponent("studio-demo.gif")
        let tour = try XCTUnwrap(CGImageDestinationCreateWithURL(tourURL as CFURL, UTType.gif.identifier as CFString, tourFrames.count, nil))
        CGImageDestinationSetProperties(tour, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (image, delay) in tourFrames {
            CGImageDestinationAddImage(tour, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(tour))
    }
    private func tourFrame(_ view: NSView, delay: Double) throws -> (CGImage, Double) {
        let source = try XCTUnwrap(bitmap(view).cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: 984, height: 640,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: 984, height: 640))
        return (try XCTUnwrap(context.makeImage()), delay)
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
@MainActor private final class DocumentationReaderStage: NSView {
    init(reader: NSView) {
        super.init(frame: CGRect(x: 0, y: 0, width: 1230, height: 800))
        wantsLayer = true
        layer?.backgroundColor = NSColor(StudioPalette.canvas).cgColor
        for (text, y, size) in [("Your words, closer to the camera.", 704.0, 30.0),
                                ("Voice Follow keeps your next line in view.", 660.0, 18.0),
                                ("Sample script · Simulated speech input", 168.0, 14.0)] {
            let label = NSTextField(labelWithString: text)
            label.frame = CGRect(x: 40, y: y, width: 1150, height: 44)
            label.alignment = .center
            label.font = .systemFont(ofSize: size, weight: size == 30 ? .semibold : .regular)
            label.textColor = NSColor(size == 30 ? StudioPalette.ink : StudioPalette.mutedInk)
            addSubview(label)
        }
        reader.frame = CGRect(x: 341, y: 236, width: 548, height: 380)
        addSubview(reader)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
@MainActor private final class DocumentationSpeech: SpeechCapturing {
    var state: SpeechFollower.State = .idle
    var onTranscript: ((String) -> Void)?
    var onUnexpectedStop: (() -> Void)?
    func start() async { state = .listening }
    func pause() { state = .paused }
    func stop() { state = .idle }
}
