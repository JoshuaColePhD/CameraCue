import XCTest
@testable import TeleprompterApp
import TeleprompterCore

@MainActor final class AIValidationTests: XCTestCase {
    func testInvalidDraftRequestsReturnActionableErrorsWithoutGenerating() async {
        for (mode, brief, source, expected) in [
            (ScriptDevelopmentMode.draft, "  ", nil, ScriptDevelopmentError.emptyIdea),
            (.revise, "Make it fun", Optional(""), .emptyScript),
            (.cues, "", Optional(String(repeating: "word ", count: 2000)), .scriptTooLong)
        ] {
            do {
                _ = try await ScriptDevelopmentService.generate(mode: mode, brief: brief, source: source)
                XCTFail("Invalid input must not generate a draft")
            } catch { XCTAssertEqual(error.localizedDescription, expected.localizedDescription) }
        }
    }
    func testLargeImportHasAWordPreservingFormattingFallback() async {
        let source = String(repeating: "A wooden horse waits outside the wall.\n", count: 650)
        let result = await PerformanceStyleService.suggestWithStatus(for: source)
        XCTAssertFalse(result.plan.usedAI)
        XCTAssertTrue(result.plan.isValid(for: source))
        XCTAssertFalse(result.status.isEmpty)
    }
}
