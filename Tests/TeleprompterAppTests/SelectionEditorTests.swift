import XCTest
import AppKit
import TeleprompterCore
@testable import TeleprompterApp

@MainActor final class SelectionEditorTests: XCTestCase {
    func testFormattingUndoRedoPreservesWordsAndExactOccurrence() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ScriptLibrary(storageDirectory: directory)
        let body = "Wait here. Wait here."
        library.createDraft(title: "Selection", body: body)
        let text = UndoTextView()
        text.string = body
        text.setSelectedRange((body as NSString).range(of: "Wait here", options: .backwards))
        let selection = ScriptSelection()
        selection.update(text, library: library)
        text.testUndo.beginUndoGrouping()
        selection.format(.emphasize)
        text.testUndo.endUndoGrouping()
        XCTAssertEqual(library.selected?.performance?.moments.last?.tokenAnchor?.range, 2..<4)
        XCTAssertTrue(text.testUndo.canUndo)
        text.testUndo.undo()
        XCTAssertNil(library.selected?.performance)
        XCTAssertEqual(library.selected?.body, body)
        text.testUndo.redo()
        XCTAssertEqual(library.selected?.performance?.moments.last?.tokenAnchor?.range, 2..<4)
        XCTAssertEqual(library.selected?.body, body)
    }
    func testSourceEditsPreventUndoFromAttachingStaleFormatting() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ScriptLibrary(storageDirectory: directory)
        let record = library.createDraft(title: "Changed", body: "Original words.")
        let plan = PerformanceLayout.localPlan(for: record.body)
        library.update(body: "Different words.")
        library.restorePerformance(plan, id: record.id, expectedBody: record.body)
        XCTAssertNil(library.selected?.performance)
        XCTAssertEqual(library.selected?.body, "Different words.")
    }
}

@MainActor private final class UndoTextView: NSTextView {
    let testUndo = UndoManager()
    override var undoManager: UndoManager? { testUndo }
}
