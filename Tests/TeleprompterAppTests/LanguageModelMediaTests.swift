import XCTest
import AppKit
import SwiftUI
@testable import TeleprompterApp

/// Isolated settings, no real Keychain entries, network requests, or user scripts.
@MainActor final class LanguageModelMediaTests: XCTestCase {
    func testRenderSettings() async throws {
        guard let destination = ProcessInfo.processInfo.environment["CAMERACUE_MODEL_MEDIA"] else {
            throw XCTSkip("Opt-in model settings renderer")
        }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CameraCue — AI Model Setup Preview"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for provider in [ScriptModelProvider.apple, .ollama, .openAI, .anthropic] {
            let settings = LanguageModelSettings(defaults: nil, credentials: MemoryScriptModelCredentials())
            if provider != .apple {
                try settings.save(ScriptModelProfile(provider: provider, model: "your-text-model"), apiKey: provider.requiresKey ? "fixture" : "")
            }
            let host = NSHostingView(rootView: LanguageModelSettingsView(settings: settings))
            window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(provider.rawValue + ".png"))
            if provider == .ollama {
                window.setContentSize(CGSize(width: 560, height: 560))
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let compact = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: compact)
                try XCTUnwrap(compact.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("compact.png"))
                window.setContentSize(CGSize(width: 640, height: 700))
            }
        }
        window.setContentSize(CGSize(width: 880, height: 680))
        let source = ScriptRecord(id: UUID(), title: "A clear opening", body: "Welcome to our gardening club.\nStart with one small pot.\nGive your idea room to grow.", modifiedAt: .now)
        let draft = NSHostingView(rootView: ScriptDevelopmentView(source: source) { _, _ in })
        window.contentView = draft
        try await Task.sleep(for: .milliseconds(400))
        draft.layoutSubtreeIfNeeded(); draft.displayIfNeeded()
        let rep = try XCTUnwrap(draft.bitmapImageRepForCachingDisplay(in: draft.bounds))
        draft.cacheDisplay(in: draft.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("draft.png"))
    }
}
