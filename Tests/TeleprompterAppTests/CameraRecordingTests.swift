import XCTest
import AVFoundation
import AppKit
import TeleprompterCore
@testable import TeleprompterApp

@MainActor final class CameraRecordingTests: XCTestCase {
    private func fixture(exportFailure: Bool = false, permission: Bool = true) -> (CameraRecording, MovieFixture, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCue-video-tests-\(UUID())")
        let backend = MovieFixture()
        let video = CameraRecording(backend: backend, defaults: nil, folder: folder, authorize: { permission }, export: { source, destination in
            if exportFailure { throw RecordingFailure.message("Export fixture failure") }
            try Data(contentsOf: source).write(to: destination)
        })
        video.enabled = true
        return (video, backend, folder)
    }
    private func model(_ video: CameraRecording, _ capture: VideoSpeechFixture? = nil) -> TeleprompterModel {
        let model = TeleprompterModel(capture: capture ?? VideoSpeechFixture(), video: video, defaults: nil)
        model.load(ScriptRecord(id: UUID(), title: "A test take", body: "Hello from CameraCue.", modifiedAt: Date()))
        model.mode = .manual
        return model
    }
    func testSuccessfulSaveCollapsesButFailureStaysVisible() async {
        for failure in [false, true] {
            let (video, _, folder) = fixture(exportFailure: failure)
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = model(video)
            let notch = NotchController(defaults: nil)
            notch.setExpanded(true)
            notch.observeSaveCompletion(model: model, delay: .milliseconds(30))
            await model.start()
            model.finish()
            XCTAssertTrue(notch.expanded, "Never collapse while writing the MP4")
            await video.waitUntilSaved()
            try? await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(notch.expanded, failure)
        }
    }
    func testManualReopeningCancelsSaveCollapse() async {
        let (video, _, folder) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(video)
        let notch = NotchController(defaults: nil)
        notch.setExpanded(true)
        notch.observeSaveCompletion(model: model, delay: .milliseconds(30))
        await model.start(); model.finish(); await video.waitUntilSaved()
        notch.setExpanded(false); notch.setExpanded(true)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(notch.expanded)
    }
    func testRestartSavesPreviousTakeAndStartsDistinctRecording() async throws {
        let (video, backend, folder) = fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(video)
        await model.start()
        model.move(lines: 1)
        let firstMovie = try XCTUnwrap(backend.url)
        await model.restartTake()
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.tokenIndex, 0)
        XCTAssertNil(model.followedWordIndex)
        XCTAssertEqual(backend.starts, 2)
        XCTAssertEqual(backend.finishes, 1)
        XCTAssertNotEqual(backend.url, firstMovie)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstMovie.deletingPathExtension().appendingPathExtension("mp4").path))
        XCTAssertFalse(model.isRestartingTake)
        model.finish(); await video.waitUntilSaved()
        XCTAssertEqual(try RecordingDiscovery.scan(folders: [folder]).count, 2)
    }
    func testRestartStopsOnSaveFailureAndKeepsOriginal() async throws {
        let (video, backend, folder) = fixture(exportFailure: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(video)
        await model.start(); await model.restartTake()
        XCTAssertEqual(video.state, .failed)
        XCTAssertEqual(backend.starts, 1)
        XCTAssertEqual(model.phase, .finished)
        XCTAssertNotNil(model.presentationNotice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(video.recoveryURL).path))
    }
    func testBackgroundChangesAreLockedThroughoutRecordingAndSaving() async {
        let (video, _, folder) = fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var setting = CameraBackground(); setting.mode = .color; setting.color = "peach"
        await video.changeBackground(setting)
        _ = await video.prepare(); _ = await video.start(title: "Background lock")
        var changed = setting; changed.mode = .blur
        await video.changeBackground(changed)
        XCTAssertEqual(video.background, setting)
        video.finish()
        await video.changeBackground(changed)
        XCTAssertEqual(video.background, setting)
        await video.waitUntilSaved()
        await video.changeBackground(changed)
        XCTAssertEqual(video.background, changed)
    }
    func testKeptOriginalIsExportedAndLinkedWithoutDuplicatingLibraryCards() async throws {
        let (video, backend, folder) = fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        backend.produceOriginal = true
        var setting = CameraBackground(); setting.mode = .color; await video.changeBackground(setting)
        _ = await video.prepare(); _ = await video.start(title: "Original copy")
        video.finish(); await video.waitUntilSaved()
        let saved = try XCTUnwrap(video.savedURL), original = try XCTUnwrap(video.originalSavedURL)
        XCTAssertEqual(original.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: original), Data("original camera movie".utf8))
        XCTAssertEqual(RecordingBackgroundSource.resolve(saved).url, original.resolvingSymlinksInPath())
        XCTAssertTrue(RecordingBackgroundSource.resolve(saved).isCameraOriginal)
        XCTAssertEqual(try RecordingDiscovery.scan(folders: [folder]).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(backend.original).path))
    }
    func testOriginalMP4FailureKeepsRawMOVAndPrimaryVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("raw-export-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = MovieFixture(); backend.produceOriginal = true
        let video = CameraRecording(backend: backend, defaults: nil, folder: folder, authorize: { true }, export: { source, destination in
            if source.deletingLastPathComponent().lastPathComponent == ".Originals" {
                try Data("partial".utf8).write(to: destination)
                throw RecordingFailure.message("Fixture encoder failure")
            }
            try Data(contentsOf: source).write(to: destination)
        })
        var setting = CameraBackground(); setting.mode = .color; await video.changeBackground(setting)
        _ = await video.prepare(); _ = await video.start(title: "Failure recovery")
        video.finish(); await video.waitUntilSaved()
        XCTAssertEqual(video.state, .saved)
        let saved = try XCTUnwrap(video.savedURL), original = try XCTUnwrap(video.originalSavedURL)
        XCTAssertEqual(original.pathExtension, "mov"); XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.deletingPathExtension().appendingPathExtension("mp4").path))
        XCTAssertEqual(RecordingBackgroundSource.resolve(saved).url, original.resolvingSymlinksInPath())
        XCTAssertNotNil(video.saveNotice)
    }
    func testRecordPauseResumeAndStopSaveOneFile() async throws {
        let (video, backend, folder) = fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(video)
        await model.performNotchRecordAction()
        XCTAssertEqual(model.phase, .running); XCTAssertEqual(video.state, .recording)
        XCTAssertEqual(backend.starts, 1)
        model.pause()
        XCTAssertEqual(model.phase, .paused); XCTAssertTrue(video.isRecording)
        await model.start()
        XCTAssertEqual(backend.starts, 1, "Resume prompting must keep the same video")
        await model.performNotchRecordAction(); await video.waitUntilSaved()
        XCTAssertEqual(model.phase, .finished); XCTAssertEqual(video.state, .saved)
        let saved = try XCTUnwrap(video.savedURL)
        XCTAssertEqual(saved.pathExtension, "mp4"); XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(backend.url).path), "Remove original only after successful MP4 export")
        XCTAssertEqual(backend.finishes, 1)
    }
    func testNotchStopAlsoFinishesWhilePromptingPaused() async {
        let (video, _, folder) = fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(video); await model.start(); model.pause()
        await model.performNotchRecordAction(); await video.waitUntilSaved()
        XCTAssertEqual(model.phase, .finished); XCTAssertEqual(video.state, .saved)
    }
    func testDeniedPermissionDoesNotStartPromptingOrVideo() async {
        let (video, backend, _) = fixture(permission: false)
        let model = model(video); await model.start()
        XCTAssertEqual(model.phase, .ready); XCTAssertEqual(video.state, .failed)
        XCTAssertEqual(backend.starts, 0); XCTAssertFalse(model.displayIsLocked)
        XCTAssertNotNil(model.presentationNotice)
    }
    func testCameraPreparationFailureDoesNotStartTake() async {
        let (video, backend, _) = fixture(); backend.failPrepare = true
        let model = model(video); await model.start()
        XCTAssertEqual(model.phase, .ready); XCTAssertEqual(backend.starts, 0)
        XCTAssertEqual(video.state, .failed); XCTAssertNotNil(model.presentationNotice)
    }
    func testSpeechFailureDoesNotRecordAndClosesPreview() async {
        let (video, backend, _) = fixture(); let speech = VideoSpeechFixture(); speech.fail = true
        let model = model(video, speech); model.mode = .voice
        await model.start()
        XCTAssertEqual(model.phase, .ready); XCTAssertEqual(backend.starts, 0)
        XCTAssertGreaterThan(backend.closes, 0)
    }
    func testCancelledCountInDoesNotRecord() async {
        let (video, backend, _) = fixture(); let model = model(video); model.useCountIn = true
        let task = Task { await model.start() }
        while model.countInSeconds == nil { await Task.yield() }
        model.pause(); await task.value
        XCTAssertEqual(backend.starts, 0); XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(video.state, .idle)
    }
    func testCancelDuringMovieStartSavesLateRecordingAndDoesNotResume() async throws {
        let (video, backend, folder) = fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        backend.holdStart = true
        let model = model(video)
        let task = Task { await model.start() }
        while backend.pending == nil { await Task.yield() }
        model.pause(); backend.completeStart(); await task.value; await video.waitUntilSaved()
        XCTAssertEqual(model.phase, .ready); XCTAssertFalse(model.isRunning)
        XCTAssertEqual(video.state, .saved); XCTAssertNotNil(video.savedURL)
    }
    func testFailedExportKeepsOriginalAndDuplicateFinishIsIgnored() async throws {
        let (video, backend, folder) = fixture(exportFailure: true); defer { try? FileManager.default.removeItem(at: folder) }
        let prepared = await video.prepare(); XCTAssertTrue(prepared)
        _ = await video.start(title: "Test")
        video.finish(); video.finish(); await video.waitUntilSaved()
        XCTAssertEqual(backend.finishes, 1); XCTAssertEqual(video.state, .failed)
        XCTAssertNotNil(video.recoveryURL); XCTAssertNil(video.savedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(video.recoveryURL).path))
    }
    func testExportRetryRemovesPartialMP4ButRetainsSourceUntilSuccess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCue-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = MovieFixture()
        var attempts = 0
        let video = CameraRecording(backend: backend, defaults: nil, folder: folder, authorize: { true }, export: { source, destination in
            attempts += 1
            if attempts == 1 {
                try Data("partial".utf8).write(to: destination)
                throw RecordingFailure.message("Disk fixture")
            }
            try Data(contentsOf: source).write(to: destination)
        })
        _ = await video.prepare(); _ = await video.start(title: "Retry")
        video.finish(); await video.waitUntilSaved()
        XCTAssertEqual(video.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(backend.url).path))
        video.retrySave(); await video.waitUntilSaved()
        XCTAssertEqual(video.state, .saved); XCTAssertEqual(attempts, 2)
        XCTAssertNotNil(video.savedURL); XCTAssertNil(video.recoveryURL)
    }
    func testSavingBlocksAnotherTakeAndPausedNotchKeepsStop() async throws {
        _ = NSApplication.shared // SwiftPM CLI runners do not initialize AppKit.
        let (video, _, folder) = fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(video); await model.start(); model.pause()
        let surface = NotchSurface(model: model)
        surface.reduceMotionOverride = true
        surface.configure(size: CGSize(width: 548, height: 248), housing: 0, header: 28, scale: 1)
        surface.setExpanded(true, animated: false)
        surface.updateControls(model: model, expanded: true, at: Date())
        XCTAssertEqual(surface.subviews.compactMap { $0 as? NotchRecordControl }.first?.accessibilityLabel(), "Stop and save video")
        model.finish()
        let starts = model.phase
        XCTAssertEqual(starts, .finished); XCTAssertEqual(video.state, .saving)
        await model.performNotchRecordAction()
        XCTAssertFalse(model.isRunning)
        await video.waitUntilSaved()
        XCTAssertEqual(video.state, .saved)
    }

    func testUnexpectedCameraStopPausesAndSavesWithoutDoubleFinishing() async throws {
        let (video, backend, folder) = fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = model(video); await model.start()
        backend.onUnexpectedFinish?(backend.url, nil); await video.waitUntilSaved()
        XCTAssertEqual(model.phase, .paused); XCTAssertEqual(video.state, .saved)
        XCTAssertEqual(backend.finishes, 0); XCTAssertNotNil(model.presentationNotice)
    }
    func testUniqueSafeFilenamesAndPromptingOnlyMode() async {
        let folder = URL(fileURLWithPath: "/tmp")
        let a = CameraRecording.destination(folder: folder, title: "../A / title:🦄")
        let b = CameraRecording.destination(folder: folder, title: "../A / title:🦄")
        XCTAssertEqual(a.deletingLastPathComponent().path, folder.path); XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.pathExtension, "mp4")
        let (video, backend, _) = fixture(); video.enabled = false
        let model = model(video); await model.start(); model.finish()
        XCTAssertEqual(model.phase, .finished); XCTAssertEqual(backend.starts, 0)
    }
}

@MainActor private final class MovieFixture: MovieCapturing {
    var session: AVCaptureSession? { nil }
    var onUnexpectedFinish: ((URL?, String?) -> Void)?
    var starts = 0, finishes = 0, closes = 0
    var url: URL?, failPrepare = false, holdStart = false
    var pending: CheckedContinuation<Void, Never>?
    var produceOriginal = false
    var original: URL?
    func originalRecording() async -> URL? { original }
    func prepare(camera: String?, microphone: String?) async throws { if failPrepare { throw RecordingFailure.message("Camera unavailable") } }
    func start(to url: URL) async throws {
        starts += 1; self.url = url; try Data("fixture movie".utf8).write(to: url)
        if produceOriginal {
            let directory = url.deletingLastPathComponent().appendingPathComponent(".Originals")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            original = directory.appendingPathComponent(url.lastPathComponent)
            try Data("original camera movie".utf8).write(to: original!)
        }
        if holdStart { await withCheckedContinuation { pending = $0 } }
    }
    func completeStart() { pending?.resume(); pending = nil }
    func finish() async throws -> URL { finishes += 1; return url! }
    func closePreview() { closes += 1 }
}
@MainActor private final class VideoSpeechFixture: SpeechCapturing {
    var state: SpeechFollower.State = .idle
    var onTranscript: ((String) -> Void)?
    var onUnexpectedStop: (() -> Void)?
    var fail = false
    func start() async { state = fail ? .error : .listening }
    func pause() { state = .paused }
    func stop() { state = .idle }
}
