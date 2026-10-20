import Foundation
import FoundationModels
import Security

enum ScriptModelProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple, openAI, anthropic, ollama, lmStudio, custom
    var id: String { rawValue }
    var name: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .openAI: "OpenAI"
        case .anthropic: "Claude (Anthropic)"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }
    var baseURL: String {
        switch self {
        case .apple: ""
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        case .custom: "http://localhost:8080/v1"
        }
    }
    var requiresKey: Bool { self == .openAI || self == .anthropic }
    var editableEndpoint: Bool { self == .ollama || self == .lmStudio || self == .custom }
    var guideURL: URL? {
        let address: String
        switch self {
        case .apple: address = "https://support.apple.com/en-us/121115"
        case .openAI: address = "https://developers.openai.com/api/docs/quickstart"
        case .anthropic: address = "https://platform.claude.com/docs/en/get-api-key"
        case .ollama: address = "https://docs.ollama.com/api/openai-compatibility"
        case .lmStudio: address = "https://lmstudio.ai/docs/developer/openai-compat"
        case .custom: return nil
        }
        return URL(string: address)
    }
}

struct ScriptModelProfile: Codable, Equatable, Sendable {
    var provider: ScriptModelProvider
    var baseURL: String
    var model: String
    var workspaceID: String?
    init(provider: ScriptModelProvider, baseURL: String? = nil, model: String = "", workspaceID: String? = nil) {
        self.provider = provider; self.baseURL = baseURL ?? provider.baseURL; self.model = model; self.workspaceID = workspaceID
    }
    var displayName: String { provider == .apple ? provider.name : "\(provider.name) · \(model)" }
    var isLoopback: Bool {
        guard let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        if ["localhost", "::1", "[::1]"].contains(host) { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.first == "127" && parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }
    func endpoint() throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value), let url = components.url,
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.scheme == "https" || (components.scheme == "http" && isLoopback)
        else { throw ScriptModelError.invalidEndpoint }
        if !provider.editableEndpoint && value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != provider.baseURL {
            throw ScriptModelError.invalidEndpoint
        }
        return url
    }
    func credentialAccount() throws -> String {
        let url = try endpoint().absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return provider.rawValue + "|" + url
    }
    func validate(apiKey: String, requiresModel: Bool = true) throws {
        guard provider != .apple else { return }
        _ = try endpoint()
        if requiresModel && (model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.count > 250) {
            throw ScriptModelError.missingModel
        }
        if provider.requiresKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ScriptModelError.missingKey }
        if apiKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { throw ScriptModelError.invalidKey }
        if let workspaceID, workspaceID.count > 250 || workspaceID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            throw ScriptModelError.invalidWorkspace
        }
    }
}

enum ScriptModelError: LocalizedError, Equatable {
    case invalidEndpoint, missingModel, missingKey, invalidKey, invalidWorkspace, keychain, appleUnavailable
    case connection, timeout, http(Int), invalidResponse, emptyResponse, incompleteResponse, refusal, noModels
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Use an HTTPS API base URL, or HTTP on localhost. Include /v1 where your server requires it; omit credentials, query parameters, and fragments."
        case .missingModel: "Fetch available models and choose a text model, or enter its model ID."
        case .missingKey: "Add your own provider API key. Open the setup guide if you need to create one."
        case .invalidKey: "Paste the API key as one line, without other text."
        case .invalidWorkspace: "Enter the provider workspace ID as one line."
        case .keychain: "macOS could not access the API key in Keychain. Unlock your login Keychain and try again."
        case .appleUnavailable: "Apple's on-device model is unavailable. Enable Apple Intelligence on a compatible Mac, or choose your own model in AI model settings."
        case .connection: "Could not reach the model server. Check its address, network connection, and whether the server is running."
        case .timeout: "The model did not reply in time. Check the server and try again."
        case .http(401), .http(403): "The provider rejected access. Check your API key and model permissions."
        case .http(404): "The model or API route was not found. Check the model ID and API base URL."
        case .http(429): "The provider's rate limit or quota was reached. Check your provider account and try later."
        case .http(300...399): "This address redirects elsewhere. Enter the server's final API base URL and try again."
        case .http(let status): "The model server returned HTTP \(status). Check the model and API settings, then try again."
        case .invalidResponse: "The server did not return a supported response. Choose a text chat model and check API compatibility."
        case .emptyResponse: "The model returned no text. Choose a text chat model or try again."
        case .incompleteResponse: "The model reached its output limit. That incomplete result was discarded; try a shorter script or a different model."
        case .refusal: "The model declined this request. Review your prompt or choose another model."
        case .noModels: "The server returned no models. Download or enable a text model in your provider, or enter its model ID manually."
        }
    }
}

@MainActor protocol ScriptModelCredentials {
    func read(account: String) throws -> String
    func write(_ value: String, account: String) throws
    func remove(account: String) throws
}

/// Only credentials use Keychain; model IDs and endpoint preferences contain no keys.
@MainActor struct KeychainScriptModelCredentials: ScriptModelCredentials {
    private let service = "com.joshuacole.cameracue.script-model"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(account: String) throws -> String {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw ScriptModelError.keychain }
        return value
    }
    func write(_ value: String, account: String) throws {
        if value.isEmpty { try remove(account: account); return }
        let request = query(account)
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = request.merging(attributes) { _, new in new }
            item[kSecAttrLabel as String] = "CameraCue AI model API key"
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ScriptModelError.keychain }
        } else if status != errSecSuccess { throw ScriptModelError.keychain }
    }
    func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ScriptModelError.keychain }
    }
}

@MainActor struct ScriptModelSession {
    let name: String
    let generate: @MainActor (String, String) async throws -> String
}

@MainActor final class LanguageModelSettings: ObservableObject {
    static let shared = LanguageModelSettings()
    static let preferenceKey = "scriptLanguageModel.v1"
    private struct Saved: Codable {
        var selected: ScriptModelProvider
        var profiles: [String: ScriptModelProfile]
    }
    @Published private(set) var selected: ScriptModelProfile
    @Published private var hasSavedKey = false
    @Published private var credentialIssue: ScriptModelError?
    private var profiles: [String: ScriptModelProfile]
    private let defaults: UserDefaults?
    private let credentials: any ScriptModelCredentials
    private let client: RemoteScriptModelClient

    init(defaults: UserDefaults? = .standard,
         credentials: any ScriptModelCredentials = KeychainScriptModelCredentials(),
         client: RemoteScriptModelClient = .live) {
        self.defaults = defaults; self.credentials = credentials; self.client = client
        let saved = defaults?.data(forKey: Self.preferenceKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        profiles = saved?.profiles ?? [:]
        let provider = saved?.selected ?? .apple
        selected = profiles[provider.rawValue].flatMap { $0.provider == provider ? $0 : nil } ?? ScriptModelProfile(provider: provider)
        refreshCredentialReadiness()
    }
    func profile(for provider: ScriptModelProvider) -> ScriptModelProfile {
        profiles[provider.rawValue].flatMap { $0.provider == provider ? $0 : nil } ?? ScriptModelProfile(provider: provider)
    }
    func apiKey(for profile: ScriptModelProfile) throws -> String {
        guard profile.provider != .apple else { return "" }
        return try credentials.read(account: profile.credentialAccount())
    }
    func save(_ profile: ScriptModelProfile, apiKey: String) throws {
        var profile = profile
        profile.baseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.workspaceID = profile.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try profile.validate(apiKey: key)
        if profile.provider != .apple { try credentials.write(key, account: profile.credentialAccount()) }
        profiles[profile.provider.rawValue] = profile
        let saved = Saved(selected: profile.provider, profiles: profiles)
        defaults?.set(try JSONEncoder().encode(saved), forKey: Self.preferenceKey)
        selected = profile
        hasSavedKey = !key.isEmpty
        credentialIssue = nil
    }
    func removeKey(for profile: ScriptModelProfile) throws {
        let account = try profile.credentialAccount()
        try credentials.remove(account: account)
        if (try? selected.credentialAccount()) == account {
            hasSavedKey = false
            credentialIssue = nil
        }
    }
    func refreshCredentialReadiness() {
        guard selected.provider != .apple else { hasSavedKey = false; credentialIssue = nil; return }
        do {
            let key = try apiKey(for: selected)
            try selected.validate(apiKey: key, requiresModel: false)
            hasSavedKey = !key.isEmpty; credentialIssue = nil
        } catch { hasSavedKey = false; credentialIssue = (error as? ScriptModelError) ?? .keychain }
    }
    var canGenerate: Bool {
        if selected.provider == .apple {
            guard #available(macOS 26, *) else { return false }
            if case .available = SystemLanguageModel.default.availability { return true }
            return false
        }
        guard credentialIssue == nil else { return false }
        do { try selected.validate(apiKey: hasSavedKey ? "present" : ""); return true }
        catch { return false }
    }
    var status: String {
        if selected.provider == .apple {
            return canGenerate ? "Apple Intelligence is available on this Mac." : ScriptModelError.appleUnavailable.localizedDescription
        }
        if let credentialIssue { return credentialIssue.localizedDescription }
        do { try selected.validate(apiKey: hasSavedKey ? "present" : ""); return "Configured · Requests go directly to your selected server." }
        catch { return error.localizedDescription }
    }
    func makeSession() throws -> ScriptModelSession {
        if selected.provider == .apple {
            guard #available(macOS 26, *), case .available = SystemLanguageModel.default.availability else { throw ScriptModelError.appleUnavailable }
            return ScriptModelSession(name: "on-device AI") { instructions, prompt in
                try Task.checkCancellation()
                return try await LanguageModelSession(instructions: instructions).respond(to: prompt).content
            }
        }
        let profile = selected
        let key: String
        do {
            key = try apiKey(for: profile)
            try profile.validate(apiKey: key)
            hasSavedKey = !key.isEmpty; credentialIssue = nil
        } catch {
            credentialIssue = (error as? ScriptModelError) ?? .keychain
            throw error
        }
        let client = client
        return ScriptModelSession(name: profile.displayName) { instructions, prompt in
            try await client.generate(profile: profile, apiKey: key, instructions: instructions, prompt: prompt)
        }
    }
    func fetchModels(profile: ScriptModelProfile, apiKey: String) async throws -> [String] {
        try await client.models(profile: profile, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func testConnection(profile: ScriptModelProfile, apiKey: String) async throws {
        if profile.provider == .apple {
            guard #available(macOS 26, *), case .available = SystemLanguageModel.default.availability else { throw ScriptModelError.appleUnavailable }
            return
        }
        _ = try await client.generate(profile: profile, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                      instructions: "Respond briefly and literally.", prompt: "Reply with: CameraCue connected.", maxOutputTokens: 1024)
    }
}
