import XCTest
@testable import TeleprompterApp
import TeleprompterCore

@MainActor final class DashboardTests: XCTestCase {
    private func entry(_ title: String, body: String, edited: TimeInterval = 0,
                       id: UUID = UUID()) -> ScriptDashboardEntry {
        let record = ScriptRecord(id: id, title: title, body: body,
                                  modifiedAt: Date(timeIntervalSince1970: edited))
        return ScriptDashboardEntry(script: record, text: ScriptTextSummary(body: body))
    }

    func testSearchFindsTitlesAndBodyWithoutChangingSource() {
        let source = "[Pause.]\nThe café opens at sunrise.\nKeep this exact wording."
        let cafe = entry("Morning story", body: source)
        let horse = entry("Trojan War", body: "A wooden horse.")
        let entries = [cafe, horse]
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "  CAFE \n").map(\.id), [cafe.id])
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "trojan").map(\.id), [horse.id])
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "exact wording").map(\.id), [cafe.id])
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "not found").count, 0)
        XCTAssertEqual(cafe.script.body, source)
    }

    func testFullLibraryFiltersIncludeOlderScriptsAndCueOnlyDrafts() {
        let spoken = (0..<8).map { entry("Script \($0)", body: "A spoken line", edited: Double($0)) }
        let blank = entry("Empty", body: "", edited: 10)
        let cues = entry("Cue notes", body: "[Pause.]\n[Lean forward.]", edited: 11)
        let entries = spoken + [blank, cues]
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "").count, 10)
        XCTAssertEqual(Set(ScriptDashboardQuery.results(entries, search: "", filter: .ready).map(\.id)), Set(spoken.map(\.id)))
        XCTAssertEqual(Set(ScriptDashboardQuery.results(entries, search: "", filter: .drafts).map(\.id)), [blank.id, cues.id])
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "notes", filter: .ready).count, 0)
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "notes", filter: .drafts).map(\.id), [cues.id])
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "   ").count, 10)
    }

    func testSortingUsesDurationAndStableTieBreakers() {
        let older = entry("Beta", body: "One two", edited: 1)
        let newer = entry("Alpha", body: "One two three four five six", edited: 2)
        let blank = entry("Draft", body: "", edited: 3)
        let entries = [older, blank, newer]
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "").map(\.id), [blank.id, newer.id, older.id])
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "", sort: .name).map(\.id), [newer.id, older.id, blank.id])
        XCTAssertEqual(ScriptDashboardQuery.results(entries, search: "", sort: .duration).map(\.id), [older.id, newer.id, blank.id])
        let first = entry("Same", body: "Word", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = entry("Same", body: "Word", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        for sort in ScriptLibrarySort.allCases {
            XCTAssertEqual(ScriptDashboardQuery.results([second, first], search: "", sort: sort).map(\.id), [first.id, second.id])
        }
    }

    func testContinuationPrioritizesLastReadableScriptAndFallsBackAfterRemoval() {
        let selected = entry("Selected", body: "Some words", edited: 1)
        let newer = entry("Newer", body: "More words", edited: 2)
        let blank = entry("Draft", body: "", edited: 3)
        let entries = [blank, newer, selected]
        XCTAssertEqual(ScriptDashboardQuery.continuation(entries, selectedID: selected.id)?.id, selected.id)
        XCTAssertEqual(ScriptDashboardQuery.continuation(entries, selectedID: blank.id)?.id, newer.id)
        XCTAssertEqual(ScriptDashboardQuery.continuation(entries, selectedID: nil)?.id, newer.id)
        XCTAssertNil(ScriptDashboardQuery.continuation([blank], selectedID: nil))
        XCTAssertNil(ScriptDashboardQuery.continuation([], selectedID: nil))
    }

    func testHomeLimitDoesNotLimitSearchFiltersOrFullLibrary() {
        let ready = (0..<10).map { entry("Script \($0)", body: "Spoken words", edited: Double($0)) }
        let blank = entry("Empty", body: "[Pause.]", edited: 20)
        let all = ready + [blank]
        XCTAssertEqual(ScriptDashboardQuery.homeResults(all, search: "", filter: .all, sort: .recent, isHome: true).map(\.id), Array(ready.reversed().prefix(6)).map(\.id))
        XCTAssertEqual(ScriptDashboardQuery.homeResults(all, search: "Spoken", filter: .all, sort: .recent, isHome: true).count, 10)
        XCTAssertEqual(ScriptDashboardQuery.homeResults(all, search: "", filter: .ready, sort: .recent, isHome: true).count, 10)
        XCTAssertEqual(ScriptDashboardQuery.homeResults(all, search: "", filter: .all, sort: .recent, isHome: false).count, 11)
        XCTAssertEqual(ScriptDashboardQuery.homeResults(all, search: "", filter: .drafts, sort: .recent, isHome: true).map(\.id), [blank.id])
        XCTAssertEqual(ScriptDashboardQuery.continuation(all, selectedID: UUID())?.id, ready.last?.id)
    }

    func testSidebarPrioritizesReadableScriptsAndFallsBackToDrafts() {
        let draft = entry("Untitled", body: "", edited: 10)
        let script = entry("Ready", body: "Read these words", edited: 1)
        XCTAssertEqual(ScriptDashboardQuery.sidebarResults([draft, script], search: "").map(\.id), [script.id])
        XCTAssertEqual(ScriptDashboardQuery.sidebarResults([draft], search: "").map(\.id), [draft.id])
        XCTAssertEqual(ScriptDashboardQuery.sidebarResults([draft, script], search: "Untitled").map(\.id), [draft.id])
    }

    func testSummarySkipsDeliveryCuesPreservesUnicodeAndUsesSeconds() {
        let source = "[Lean forward.]\nBonjour, café!\n[Pause.]\nWe’re ready.\nThe end."
        let summary = ScriptTextSummary(body: source)
        XCTAssertEqual(summary.excerpt, "Bonjour, café! We’re ready. The end.")
        XCTAssertEqual(summary.wordCount, ScriptDocument(source).tokens.count)
        XCTAssertFalse(summary.excerpt.contains("Pause"))
        XCTAssertEqual(summary.excerptLines, ["Bonjour, café!", "We’re ready.", "The end."])
        let minute = ScriptTextSummary(body: Array(repeating: "word", count: 135).joined(separator: " "))
        XCTAssertEqual(minute.readingSeconds, 60)
        XCTAssertEqual(minute.durationLabel, "~1:00 read")
        let empty = ScriptTextSummary(body: "[Pause.]\n")
        XCTAssertEqual(empty.wordCount, 0)
        XCTAssertEqual(empty.durationLabel, "Blank draft")
        XCTAssertEqual(entry("  ", body: "").title, "Untitled Script")
    }

    func testFavoritesIntersectSearchAndKeepSourceAndEditTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ScriptLibrary(storageDirectory: directory)
        let favorite = library.createDraft(title: "Café", body: "[Pause.]\nKeep these words.")
        let other = library.createDraft(title: "Other", body: "Another script")
        library.toggleFavorite(id: favorite.id)
        XCTAssertEqual(library.selectedID, other.id)
        XCTAssertEqual(library.scripts.first { $0.id == favorite.id }?.modifiedAt, favorite.modifiedAt)
        XCTAssertEqual(ScriptDashboardQuery.results(library.dashboardEntries(), search: "CAFE", filter: .favorites).map(\.id), [favorite.id])
        XCTAssertTrue(ScriptDashboardQuery.results(library.dashboardEntries(), search: "Other", filter: .favorites).isEmpty)
        let reopened = ScriptLibrary(storageDirectory: directory)
        XCTAssertTrue(try XCTUnwrap(reopened.scripts.first { $0.id == favorite.id }).isFavorite)
        XCTAssertEqual(reopened.scripts.first { $0.id == favorite.id }?.body, favorite.body)
        reopened.toggleFavorite(id: favorite.id)
        XCTAssertTrue(ScriptDashboardQuery.results(reopened.dashboardEntries(), search: "", filter: .favorites).isEmpty)
        XCTAssertEqual(ScriptLibraryFilter.ready.rawValue, "Ready to read")
    }

    func testTargetedRowActionsNeverModifyAnotherScript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ScriptLibrary(storageDirectory: directory)
        let original = library.createDraft(title: "Original", body: "Exact words, café 👋")
        let plan = PerformanceLayout.localPlan(for: original.body)
        XCTAssertTrue(library.apply(plan, to: original.id))
        let selected = library.createDraft(title: "Selected", body: "Other words")
        library.rename(id: original.id, title: "  Renamed café 👋  ")
        library.rename(id: original.id, title: " \n ")
        XCTAssertEqual(library.selectedID, selected.id)
        XCTAssertEqual(library.scripts.first { $0.id == original.id }?.title, "Renamed café 👋")
        XCTAssertEqual(library.scripts.first { $0.id == original.id }?.performance, plan)
        let copy = try XCTUnwrap(library.duplicate(id: original.id))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.title, "Renamed café 👋 Copy")
        XCTAssertEqual(copy.body, original.body)
        XCTAssertEqual(copy.performance, plan)
        library.delete(id: original.id)
        XCTAssertEqual(library.selectedID, copy.id)
        XCTAssertEqual(library.scripts.first { $0.id == selected.id }, selected)
        XCTAssertNil(library.scripts.first { $0.id == original.id })
        XCTAssertNil(library.duplicate(id: UUID()))
        let reopened = ScriptLibrary(storageDirectory: directory)
        XCTAssertEqual(reopened.scripts.first { $0.id == copy.id }, copy)
    }

    func testOlderLibraryWithoutFavoriteMetadataStillLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ScriptLibrary(storageDirectory: directory)
        let record = try XCTUnwrap(library.selected)
        let oldJSON = try JSONEncoder().encode([record])
        XCTAssertFalse(String(decoding: oldJSON, as: UTF8.self).contains("favorite"))
        let reopened = ScriptLibrary(storageDirectory: directory)
        XCTAssertFalse(try XCTUnwrap(reopened.selected).isFavorite)
        XCTAssertNil(reopened.recoveryNotice)
        reopened.delete(id: record.id)
        XCTAssertEqual(reopened.scripts.count, 1)
    }

    func testCachedSummariesRefreshAfterEditingAndReopenWithoutSelectingOtherScripts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ScriptLibrary(storageDirectory: directory)
        let sample = try XCTUnwrap(library.selected)
        let draft = library.createDraft(title: "Draft", body: "One line")
        let first = try XCTUnwrap(library.dashboardEntries().first { $0.id == draft.id })
        XCTAssertEqual(first.text.wordCount, 2)
        XCTAssertEqual(library.selectedID, draft.id)
        library.update(title: "Renamed", body: "One line\nAnd another line")
        let edited = try XCTUnwrap(library.dashboardEntries().first { $0.id == draft.id })
        XCTAssertEqual(edited.title, "Renamed")
        XCTAssertEqual(edited.text.wordCount, 5)
        XCTAssertEqual(edited.text.excerpt, "One line And another line")
        XCTAssertEqual(library.selectedID, draft.id)
        XCTAssertTrue(library.apply(PerformanceLayout.localPlan(for: edited.script.body), to: draft.id))
        XCTAssertTrue(try XCTUnwrap(library.dashboardEntries().first { $0.id == draft.id }).isStyled)
        library.update(body: "")
        let blank = try XCTUnwrap(library.dashboardEntries().first { $0.id == draft.id })
        XCTAssertFalse(blank.isReady)
        XCTAssertFalse(blank.isStyled)
        XCTAssertEqual(library.scripts.first { $0.id == sample.id }, sample)
        let reopened = ScriptLibrary(storageDirectory: directory)
        XCTAssertEqual(reopened.dashboardEntries().first { $0.id == draft.id }?.text, blank.text)
        XCTAssertEqual(reopened.scripts.first { $0.id == sample.id }?.body, sample.body)
    }
}
