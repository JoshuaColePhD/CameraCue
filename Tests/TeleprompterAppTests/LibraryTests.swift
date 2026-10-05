import XCTest
@testable import TeleprompterApp
import TeleprompterCore

@MainActor final class LibraryTests: XCTestCase {
    func testImportFormattingReportsCompletionPreservesWordsAndRejectsUnsupportedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = ScriptLibrary(storageDirectory: directory.appendingPathComponent("Library"))
        let original = "[Pause.]\n" + Array(repeating: "Exact café words.", count: 1400).joined(separator: "\n")
        let file = directory.appendingPathComponent("Read.md")
        try original.write(to: file, atomically: true, encoding: .utf8)
        let imported = try library.importFile(file)
        let result = await PerformanceStyleService.suggestWithStatus(for: imported.body)
        XCTAssertFalse(result.status.isEmpty)
        XCTAssertTrue(result.plan.isValid(for: original))
        XCTAssertTrue(library.apply(result.plan, to: imported.id))
        XCTAssertEqual(library.selected?.body, original)
        XCTAssertTrue(try XCTUnwrap(library.dashboardEntries().first { $0.id == imported.id }).isStyled)
        XCTAssertThrowsError(try library.importFile(directory.appendingPathComponent("Read.pdf")))
        let oversized = directory.appendingPathComponent("Big.txt")
        try Data(repeating: 65, count: 2_000_001).write(to: oversized)
        XCTAssertThrowsError(try library.importFile(oversized))
        XCTAssertEqual(library.scripts.count, 2)
    }
    func testImportStyleEditAndReopenInIsolatedLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Read.txt")
        let original = "[Pause.]\nOne GIANT horse walks through the gate."
        try original.write(to: file, atomically: true, encoding: .utf8)
        let library = ScriptLibrary(storageDirectory: directory.appendingPathComponent("Library"))
        let imported = try library.importFile(file)
        let plan = PerformanceLayout.localPlan(for: original)
        XCTAssertTrue(library.apply(plan, to: imported.id))
        XCTAssertEqual(library.selected?.body, original)
        library.update(body: original + "\nThe end.")
        XCTAssertNil(library.selected?.performance)
        XCTAssertFalse(library.apply(plan, to: imported.id), "A late AI result must not style changed text")
        let reopened = ScriptLibrary(storageDirectory: directory.appendingPathComponent("Library"))
        XCTAssertEqual(reopened.scripts.first(where: { $0.id == imported.id })?.body, original + "\nThe end.")
        XCTAssertNil(reopened.storageError)
    }
    func testUnreadableLibraryIsPreservedBeforeRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("scripts.json")
        try "broken original".write(to: file, atomically: true, encoding: .utf8)
        let library = ScriptLibrary(storageDirectory: directory)
        XCTAssertNotNil(library.recoveryNotice)
        let backup = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix("scripts-recovery-") })
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backup), encoding: .utf8), "broken original")
    }
}
