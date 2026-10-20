import Foundation

/// Stateless requests to the user's server. No developer account, cookies, cache, or automatic retries.
struct RemoteScriptModelClient: Sendable {
    static let live: RemoteScriptModelClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        return RemoteScriptModelClient(session: URLSession(configuration: configuration, delegate: ScriptModelRedirectPolicy(), delegateQueue: nil))
    }()
    let session: URLSession

    func generate(profile: ScriptModelProfile, apiKey: String, instructions: String, prompt: String,
                  maxOutputTokens: Int = 4096) async throws -> String {
        try profile.validate(apiKey: apiKey)
        let anthropic = profile.provider == .anthropic
        let path = anthropic ? "messages" : "chat/completions"
        var request = try request(profile: profile, apiKey: apiKey, path: path)
        request.httpMethod = "POST"
        var body: [String: Any] = ["model": profile.model, "stream": false]
        if anthropic {
            body["system"] = instructions
            body["messages"] = [["role": "user", "content": prompt]]
            body["max_tokens"] = maxOutputTokens
        } else {
            body["messages"] = [["role": "system", "content": instructions], ["role": "user", "content": prompt]]
            body[profile.provider == .openAI ? "max_completion_tokens" : "max_tokens"] = maxOutputTokens
            if profile.provider == .openAI { body["store"] = false }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        do {
            let text: String
            if anthropic {
                let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
                if response.stop_reason == "max_tokens" { throw ScriptModelError.incompleteResponse }
                if response.stop_reason == "refusal" { throw ScriptModelError.refusal }
                text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
            } else {
                let response = try JSONDecoder().decode(ChatResponse.self, from: data)
                guard let choice = response.choices.first else { throw ScriptModelError.invalidResponse }
                if choice.finish_reason == "length" { throw ScriptModelError.incompleteResponse }
                if choice.finish_reason == "content_filter" || choice.message.refusal?.isEmpty == false { throw ScriptModelError.refusal }
                text = choice.message.content?.text ?? ""
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ScriptModelError.emptyResponse }
            return trimmed
        } catch let error as ScriptModelError { throw error }
        catch { throw ScriptModelError.invalidResponse }
    }

    func models(profile: ScriptModelProfile, apiKey: String) async throws -> [String] {
        try profile.validate(apiKey: apiKey, requiresModel: false)
        let data = try await send(request(profile: profile, apiKey: apiKey, path: "models"))
        guard let response = try? JSONDecoder().decode(ModelList.self, from: data) else { throw ScriptModelError.invalidResponse }
        let ids = Set(response.data.prefix(1000).map(\.id).filter { !$0.isEmpty && $0.count <= 250 }).sorted()
        guard !ids.isEmpty else { throw ScriptModelError.noModels }
        return ids
    }

    private func request(profile: ScriptModelProfile, apiKey: String, path: String) throws -> URLRequest {
        var url = try profile.endpoint()
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if profile.provider == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            if let workspace = profile.workspaceID, !workspace.isEmpty {
                request.setValue(workspace, forHTTPHeaderField: "anthropic-workspace-id")
            }
        } else if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ScriptModelError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw ScriptModelError.http(http.statusCode) }
            guard data.count <= 2_000_000 else { throw ScriptModelError.invalidResponse }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as ScriptModelError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? ScriptModelError.timeout : ScriptModelError.connection
        } catch { throw ScriptModelError.connection }
    }

    private struct ModelList: Decodable { let data: [Model]; struct Model: Decodable { let id: String } }
    private struct TextPart: Decodable { let type: String; let text: String? }
    private struct AnthropicResponse: Decodable { let content: [TextPart]; let stop_reason: String? }
    private enum TextContent: Decodable {
        case string(String), parts([TextPart])
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .string(value) }
            else { self = .parts(try container.decode([TextPart].self)) }
        }
        var text: String {
            switch self {
            case .string(let value): value
            case .parts(let parts): parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
            }
        }
    }
    private struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Message
            let finish_reason: String?
            struct Message: Decodable { let content: TextContent?; let refusal: String? }
        }
    }
}

/// Never forward credentials or prompts to a redirect destination.
final class ScriptModelRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
