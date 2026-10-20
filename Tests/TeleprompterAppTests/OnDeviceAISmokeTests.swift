import XCTest
import FoundationModels
import TeleprompterCore
@testable import TeleprompterApp

/// Opt-in real inference with fictional text; never opens camera/microphone or saves a script.
@MainActor final class OnDeviceAISmokeTests: XCTestCase {
    func testProductionRevisionCuesAndFormatting() async throws {
        guard ProcessInfo.processInfo.environment["CAMERACUE_TEST_ON_DEVICE_AI"] == "1" else {
            throw XCTSkip("Opt-in Apple model check; ordinary CI does not run inference")
        }
        guard #available(macOS 26, *), case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple's on-device model is unavailable")
        }
        let appleSession = try LanguageModelSettings(defaults: nil, credentials: MemoryScriptModelCredentials()).makeSession()
        let source = """
        Welcome to our gardening club.
        You do not need to be an expert.
        Start with one small pot.
        Plant a few seeds and give them time.
        What would you like to grow?
        Every small success is worth celebrating.
        Bring your questions and your curiosity.
        Let us learn together.
        """
        let revised = try await ScriptDevelopmentService.generate(mode: .revise,
            brief: "Make the welcome warmer. Keep it short and add no new facts.", source: source, session: appleSession)
        XCTAssertFalse(ScriptDocument(revised).tokens.isEmpty)
        print("AI smoke: revision produced \(ScriptDocument(revised).tokens.count) spoken words")
        let cues = try await ScriptDevelopmentService.generate(mode: .cues,
            brief: "Add two short delivery directions. Preserve every spoken word.", source: source, session: appleSession)
        XCTAssertEqual(ScriptDocument(cues).tokens, ScriptDocument(source).tokens)
        print("AI smoke: delivery cues preserved all spoken words")
        let result = await PerformanceStyleService.suggestWithStatus(for: source, session: appleSession)
        XCTAssertTrue(result.plan.isValid(for: source))
        XCTAssertTrue(result.plan.usedAI, result.status)
        XCTAssertFalse(result.plan.moments.isEmpty)
        print("AI smoke: \(result.status) \(result.plan.moments.count) performance moments")
    }
}
