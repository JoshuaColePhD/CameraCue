import XCTest
import Foundation
import TeleprompterCore
@testable import TeleprompterApp

@MainActor final class LanguageModelTests: XCTestCase {
    func testSettingsPersistWithoutSecretsAndKeepKeysScopedToEndpoint() throws {
        let domain = "CameraCue.ModelTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let keys = MemoryScriptModelCredentials()
        let settings = LanguageModelSettings(defaults: defaults, credentials: keys)
        XCTAssertEqual(settings.selected.provider, .apple)
        let first = ScriptModelProfile(provider: .custom, baseURL: "https://one.fixture.invalid/v1", model: "fixture-model")
        try settings.save(first, apiKey: "fixture-credential")
        let persisted = try XCTUnwrap(defaults.data(forKey: LanguageModelSettings.preferenceKey))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("fixture-credential"))
        let restored = LanguageModelSettings(defaults: defaults, credentials: keys)
        XCTAssertEqual(restored.selected, first)
        XCTAssertEqual(try restored.apiKey(for: first), "fixture-credential")
        let second = ScriptModelProfile(provider: .custom, baseURL: "https://two.fixture.invalid/v1", model: "fixture-model")
        XCTAssertEqual(try restored.apiKey(for: second), "")
        try restored.save(second, apiKey: "other-fixture-credential")
        try restored.removeKey(for: first)
        XCTAssertEqual(try restored.apiKey(for: first), "")
        XCTAssertEqual(try restored.apiKey(for: second), "other-fixture-credential")
        try restored.save(ScriptModelProfile(provider: .apple), apiKey: "")
        XCTAssertEqual(restored.selected.provider, .apple)
        XCTAssertEqual(try restored.apiKey(for: second), "other-fixture-credential")
    }

    func testKeychainFailureDoesNotActivateAnUnsavedProvider() throws {
        let keys = MemoryScriptModelCredentials()
        keys.failWrites = true
        let settings = LanguageModelSettings(defaults: nil, credentials: keys)
        XCTAssertThrowsError(try settings.save(ScriptModelProfile(provider: .openAI, model: "fixture-model"), apiKey: "fixture"))
        XCTAssertEqual(settings.selected.provider, .apple)
        XCTAssertEqual(settings.profile(for: .openAI).model, "")
    }

    func testRenderingReadinessDoesNotRepeatedlyReadTheKeychain() throws {
        let keys = MemoryScriptModelCredentials()
        let settings = LanguageModelSettings(defaults: nil, credentials: keys)
        try settings.save(ScriptModelProfile(provider: .openAI, model: "fixture-model"), apiKey: "fixture")
        let reads = keys.reads
        for _ in 0..<10 {
            XCTAssertTrue(settings.canGenerate)
            XCTAssertFalse(settings.status.isEmpty)
        }
        XCTAssertEqual(keys.reads, reads)
        _ = try settings.makeSession()
        XCTAssertEqual(keys.reads, reads + 1)
    }

    func testEndpointsAllowLocalServersAndRejectCredentialLeaks() throws {
        for url in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1", " https://models.example/v1 "] {
            XCTAssertNoThrow(try ScriptModelProfile(provider: .custom, baseURL: url, model: "text").endpoint(), url)
        }
        for url in ["http://remote.example/v1", "http://localhost.evil.example/v1", "http://127.evil.example/v1",
                    "https://user:credential@example.com/v1", "https://example.com/v1?key=private", "https://example.com/v1#private",
                    "ftp://localhost/v1", "http://localhost:0/v1"] {
            XCTAssertThrowsError(try ScriptModelProfile(provider: .custom, baseURL: url, model: "text").endpoint(), url)
        }
        XCTAssertThrowsError(try ScriptModelProfile(provider: .openAI, baseURL: "https://another.example/v1", model: "text").endpoint())
        XCTAssertThrowsError(try ScriptModelProfile(provider: .openAI, model: "text").validate(apiKey: ""))
        XCTAssertThrowsError(try ScriptModelProfile(provider: .custom, model: "text").validate(apiKey: "two\nlines"))
    }

    func testOpenAIAndAnthropicUseTheirOwnRequestFormats() async throws {
        let openAI = ModelHTTPHarness(json: #"{"choices":[{"message":{"content":"A readable draft."},"finish_reason":"stop"}]}"#)
        defer { openAI.close() }
        let output = try await openAI.client.generate(profile: ScriptModelProfile(provider: .openAI, model: "fixture-model"),
                                                    apiKey: "fixture", instructions: "Write a script.", prompt: "A garden.")
        XCTAssertEqual(output, "A readable draft.")
        let request = try XCTUnwrap(openAI.state.requests.first)
        XCTAssertEqual(request.url.path, "/v1/chat/completions")
        XCTAssertEqual(request.authorization, "Bearer fixture")
        XCTAssertNil(request.anthropicKey)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 4096)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] }, ["system", "user"])

        let claude = ModelHTTPHarness(json: #"{"content":[{"type":"thinking"},{"type":"text","text":"A second draft."}],"stop_reason":"end_turn"}"#)
        defer { claude.close() }
        let claudeOutput = try await claude.client.generate(profile: ScriptModelProfile(provider: .anthropic, model: "fixture-model", workspaceID: "fixture-workspace"),
                                                          apiKey: "fixture", instructions: "Write a script.", prompt: "A garden.")
        XCTAssertEqual(claudeOutput, "A second draft.")
        let message = try XCTUnwrap(claude.state.requests.first)
        XCTAssertEqual(message.url.path, "/v1/messages")
        XCTAssertEqual(message.anthropicKey, "fixture")
        XCTAssertEqual(message.anthropicVersion, "2023-06-01")
        XCTAssertEqual(message.anthropicWorkspace, "fixture-workspace")
        XCTAssertNil(message.authorization)
        let claudeBody = try XCTUnwrap(JSONSerialization.jsonObject(with: message.body) as? [String: Any])
        XCTAssertEqual(claudeBody["system"] as? String, "Write a script.")
        XCTAssertEqual(claudeBody["max_tokens"] as? Int, 4096)
    }

    func testLocalModelDiscoveryAndCompatibleTextPartsNeedNoKey() async throws {
        let fixture = ModelHTTPHarness(json: #"{"data":[{"id":"text-b"},{"id":"text-a"},{"id":"text-b"}]}"#)
        defer { fixture.close() }
        let profile = ScriptModelProfile(provider: .ollama)
        let models = try await fixture.client.models(profile: profile, apiKey: "")
        XCTAssertEqual(models, ["text-a", "text-b"])
        XCTAssertEqual(fixture.state.requests.first?.method, "GET")
        XCTAssertEqual(fixture.state.requests.first?.url.path, "/v1/models")
        XCTAssertNil(fixture.state.requests.first?.authorization)
        fixture.state.reply = .http(200, Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"Local draft."}]},"finish_reason":"stop"}]}"#.utf8))
        let output = try await fixture.client.generate(profile: ScriptModelProfile(provider: .ollama, model: "text-a"), apiKey: "", instructions: "Write.", prompt: "A garden.")
        XCTAssertEqual(output, "Local draft.")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.state.requests[1].body) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertNil(body["max_completion_tokens"])
    }

    func testGenerationKeepsItsProviderSnapshotAfterSettingsChange() async throws {
        let fixture = ModelHTTPHarness(json: #"{"choices":[{"message":{"content":"First provider draft."},"finish_reason":"stop"}]}"#)
        defer { fixture.close() }
        let settings = LanguageModelSettings(defaults: nil, credentials: MemoryScriptModelCredentials(), client: fixture.client)
        try settings.save(ScriptModelProfile(provider: .custom, baseURL: "https://first.fixture.invalid/v1", model: "first-model"), apiKey: "first-fixture")
        let snapshot = try settings.makeSession()
        try settings.save(ScriptModelProfile(provider: .custom, baseURL: "https://second.fixture.invalid/v1", model: "second-model"), apiKey: "second-fixture")
        let draft = try await ScriptDevelopmentService.generate(mode: .draft, brief: "A fictional garden.", source: nil, session: snapshot)
        XCTAssertEqual(draft, "First provider draft.")
        XCTAssertEqual(fixture.state.requests.first?.url.host, "first.fixture.invalid")
        XCTAssertEqual(fixture.state.requests.first?.authorization, "Bearer first-fixture")
    }

    func testProviderErrorsDoNotRetryLeakBodiesOrReturnTruncatedDrafts() async throws {
        let fixture = ModelHTTPHarness(json: "provider-body-containing-a-private-value", status: 401)
        defer { fixture.close() }
        let profile = ScriptModelProfile(provider: .custom, model: "fixture-model")
        do {
            _ = try await fixture.client.generate(profile: profile, apiKey: "fixture", instructions: "Write.", prompt: "A garden.")
            XCTFail("Access rejection must be surfaced")
        } catch {
            XCTAssertEqual(error as? ScriptModelError, .http(401))
            XCTAssertFalse(error.localizedDescription.contains("private-value"))
        }
        XCTAssertEqual(fixture.state.requests.count, 1)
        fixture.state.reply = .http(200, Data(#"{"choices":[{"message":{"content":"An incomplete"},"finish_reason":"length"}]}"#.utf8))
        do {
            _ = try await fixture.client.generate(profile: profile, apiKey: "", instructions: "Write.", prompt: "A garden.")
            XCTFail("Truncated results must not be presented as complete")
        } catch { XCTAssertEqual(error as? ScriptModelError, .incompleteResponse) }
        fixture.state.reply = .failure(.cancelled)
        do {
            _ = try await fixture.client.generate(profile: profile, apiKey: "", instructions: "Write.", prompt: "A garden.")
            XCTFail("Cancellation must be preserved")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOwnModelCuesAndFormattingKeepSpokenWordsIntact() async throws {
        let source = "A clear idea.\nGive important words room."
        let changedWords = ScriptModelSession(name: "Fixture") { _, _ in "A different idea." }
        do {
            _ = try await ScriptDevelopmentService.generate(mode: .cues, brief: "Add cues.", source: source, session: changedWords)
            XCTFail("A provider must not rewrite spoken words in cue mode")
        } catch { XCTAssertEqual(error as? ScriptDevelopmentError, .changedSpokenWords) }
        let accents = ScriptModelSession(name: "Fixture") { _, _ in "0|A clear idea|huge" }
        let styled = await PerformanceStyleService.suggestWithStatus(for: source, session: accents)
        XCTAssertTrue(styled.plan.usedAI)
        XCTAssertTrue(styled.plan.isValid(for: source))
        XCTAssertTrue(styled.status.contains("Fixture"))
        let failing = ScriptModelSession(name: "Fixture") { _, _ in throw ScriptModelError.http(429) }
        let fallback = await PerformanceStyleService.suggestWithStatus(for: source, session: failing)
        XCTAssertFalse(fallback.plan.usedAI)
        XCTAssertTrue(fallback.plan.isValid(for: source))
        XCTAssertTrue(fallback.needsRetry)
        XCTAssertTrue(fallback.status.contains("quota"))
    }

    func testAutomaticImportsNeverSendTextToAnExternalModel() async throws {
        let fixture = ModelHTTPHarness(json: #"{"choices":[{"message":{"content":"0|A clear idea|huge"},"finish_reason":"stop"}]}"#)
        defer { fixture.close() }
        let settings = LanguageModelSettings(defaults: nil, credentials: MemoryScriptModelCredentials(), client: fixture.client)
        try settings.save(ScriptModelProfile(provider: .custom, model: "fixture-model"), apiKey: "")
        let source = "A clear idea."
        let imported = await PerformanceStyleService.suggestWithStatus(for: source, settings: settings, allowsExternalModel: false)
        XCTAssertTrue(fixture.state.requests.isEmpty)
        XCTAssertFalse(imported.plan.usedAI)
        XCTAssertTrue(imported.plan.isValid(for: source))
        let explicit = await PerformanceStyleService.suggestWithStatus(for: source, settings: settings)
        XCTAssertEqual(fixture.state.requests.count, 1)
        XCTAssertTrue(explicit.plan.usedAI)
    }
}

@MainActor final class MemoryScriptModelCredentials: ScriptModelCredentials {
    var values: [String: String] = [:]
    var failWrites = false
    var reads = 0
    func read(account: String) throws -> String { reads += 1; return values[account] ?? "" }
    func write(_ value: String, account: String) throws {
        if failWrites { throw ScriptModelError.keychain }
        values[account] = value
    }
    func remove(account: String) throws { values.removeValue(forKey: account) }
}

private struct ModelHTTPRequest: Sendable {
    let url: URL
    let method: String
    let authorization: String?
    let anthropicKey: String?
    let anthropicVersion: String?
    let anthropicWorkspace: String?
    let body: Data
}
private enum ModelHTTPReply: Sendable { case http(Int, Data), failure(URLError.Code) }
private final class ModelHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReply: ModelHTTPReply
    private var storedRequests: [ModelHTTPRequest] = []
    init(reply: ModelHTTPReply) { storedReply = reply }
    var reply: ModelHTTPReply {
        get { lock.lock(); defer { lock.unlock() }; return storedReply }
        set { lock.lock(); defer { lock.unlock() }; storedReply = newValue }
    }
    var requests: [ModelHTTPRequest] { lock.lock(); defer { lock.unlock() }; return storedRequests }
    func append(_ request: ModelHTTPRequest) { lock.lock(); defer { lock.unlock() }; storedRequests.append(request) }
}
private struct ModelHTTPHarness {
    let id = UUID().uuidString
    let state: ModelHTTPState
    let client: RemoteScriptModelClient
    init(json: String, status: Int = 200) {
        state = ModelHTTPState(reply: .http(status, Data(json.utf8)))
        ModelHTTPProtocol.registry.add(state, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelHTTPProtocol.self]
        configuration.httpAdditionalHeaders = ["X-CameraCue-Fixture": id]
        client = RemoteScriptModelClient(session: URLSession(configuration: configuration))
    }
    func close() { client.session.invalidateAndCancel(); ModelHTTPProtocol.registry.remove(id: id) }
}
private final class ModelHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: ModelHTTPState] = [:]
    func add(_ state: ModelHTTPState, id: String) { lock.lock(); defer { lock.unlock() }; states[id] = state }
    func get(_ id: String) -> ModelHTTPState? { lock.lock(); defer { lock.unlock() }; return states[id] }
    func remove(id: String) { lock.lock(); defer { lock.unlock() }; states.removeValue(forKey: id) }
}
private final class ModelHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ModelHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-CameraCue-Fixture"), let state = Self.registry.get(id), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        state.append(ModelHTTPRequest(url: url, method: request.httpMethod ?? "GET",
                                      authorization: request.value(forHTTPHeaderField: "Authorization"),
                                      anthropicKey: request.value(forHTTPHeaderField: "x-api-key"),
                                      anthropicVersion: request.value(forHTTPHeaderField: "anthropic-version"),
                                      anthropicWorkspace: request.value(forHTTPHeaderField: "anthropic-workspace-id"), body: body))
        switch state.reply {
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let data):
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
