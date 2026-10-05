import XCTest
import TeleprompterCore
@testable import TeleprompterApp

@MainActor final class DashboardFormattingTests: XCTestCase {
    private var folder: URL!
    private var library: ScriptLibrary!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = ScriptLibrary(storageDirectory: folder)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }
    private func waitUntilComplete(_ state: DashboardFormatting, _ id: UUID) async {
        for _ in 0..<500 {
            if state.progress[id]?.phase != .formatting { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Formatting did not complete")
    }
    func testCompletionPreservesWordsAndSelectionAfterNavigation() async {
        let state = DashboardFormatting { source in
            await Task.yield()
            return .init(plan: PerformanceLayout.localPlan(for: source), status: "Local formatting ready")
        }
        let script = library.importText("Exact café words.\nAnother phrase.")
        state.start(script, library: library)
        XCTAssertEqual(state.progress[script.id]?.phase, .formatting)
        library.create()
        let other = library.selected!
        await waitUntilComplete(state, script.id)
        XCTAssertEqual(library.selectedID, other.id)
        XCTAssertEqual(library.scripts.first { $0.id == script.id }?.body, script.body)
        XCTAssertEqual(state.progress[script.id]?.phase, .ready)
    }
    func testEditingDuringFormattingRejectsLateResponseAndRetryUsesNewWords() async {
        let gate = FormattingGate()
        let state = DashboardFormatting { source in
            await gate.wait()
            return .init(plan: PerformanceLayout.localPlan(for: source), status: "Ready")
        }
        let script = library.importText("Original words.")
        state.start(script, library: library)
        while gate.continuation == nil { await Task.yield() }
        library.update(body: "Changed wording.")
        gate.release()
        await waitUntilComplete(state, script.id)
        XCTAssertEqual(state.progress[script.id]?.phase, .attention)
        XCTAssertEqual(library.selected?.body, "Changed wording.")
        XCTAssertNil(library.selected?.performance)
        state.start(library.selected!, library: library)
        while gate.continuation == nil { await Task.yield() }
        gate.release()
        await waitUntilComplete(state, script.id)
        XCTAssertEqual(state.progress[script.id]?.phase, .ready)
        XCTAssertEqual(library.selected?.body, "Changed wording.")
    }
    func testSeparateImportsKeepIndependentProgress() async {
        let state = DashboardFormatting { source in .init(plan: PerformanceLayout.localPlan(for: source), status: "Ready") }
        let first = library.importText("First exact script.")
        let second = library.importText("Second exact script.")
        state.start(first, library: library); state.start(second, library: library)
        await waitUntilComplete(state, first.id); await waitUntilComplete(state, second.id)
        XCTAssertEqual(state.latestID, second.id)
        XCTAssertEqual(state.progress[first.id]?.phase, .ready)
        XCTAssertEqual(state.progress[second.id]?.phase, .ready)
    }
    func testModelFailureRetainsReadableFallbackAndOffersRetry() async {
        let state = DashboardFormatting { source in
            .init(plan: PerformanceLayout.localPlan(for: source), status: "Model failed; local formatting used.", needsRetry: true)
        }
        let script = library.importText("Readable original words.")
        state.start(script, library: library)
        await waitUntilComplete(state, script.id)
        XCTAssertEqual(state.progress[script.id]?.phase, .attention)
        XCTAssertNotNil(library.selected?.performance)
        XCTAssertEqual(library.selected?.body, script.body)
    }
    func testInvalidPlanKeepsImportAndReportsAttention() async {
        let state = DashboardFormatting { _ in .init(plan: PerformanceLayout.localPlan(for: "Different words"), status: "Failed") }
        let script = library.importText("Keep my words.")
        state.start(script, library: library)
        await waitUntilComplete(state, script.id)
        XCTAssertEqual(state.progress[script.id]?.phase, .attention)
        XCTAssertEqual(library.selected?.body, script.body)
        XCTAssertNil(library.selected?.performance)
    }
}
@MainActor private final class FormattingGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
