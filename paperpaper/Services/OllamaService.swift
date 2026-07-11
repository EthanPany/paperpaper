import Foundation
import ImageIO
import os
#if canImport(AppKit)
import AppKit
#endif

private let ollamaLog = Logger(subsystem: "me.ethanpan.paperpaper", category: "ollama")

/// Compact summary of a JSON body for logging — replaces long strings (image
/// base64) with "<n bytes>" markers so we can see the structure without
/// flooding Console.
private func summarizeForLog(_ value: Any, depth: Int = 0) -> Any {
    if let dict = value as? [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict { out[k] = summarizeForLog(v, depth: depth + 1) }
        return out
    }
    if let arr = value as? [Any] {
        return arr.map { summarizeForLog($0, depth: depth + 1) }
    }
    if let s = value as? String {
        if s.count > 200 { return "<string \(s.count) chars: \(s.prefix(60))…>" }
        return s
    }
    return value
}

private func logJSONBody(_ label: String, _ body: [String: Any]) {
    let summary = summarizeForLog(body)
    if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted]),
       let str = String(data: data, encoding: .utf8) {
        ollamaLog.notice("\(label, privacy: .public):\n\(str, privacy: .public)")
    }
}

enum OllamaError: Error, LocalizedError {
    case missingURL
    case http(status: Int, body: String)
    case decoding(Error)
    case transport(Error)
    case emptyResponse
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingURL: return "Set your Ollama Host URL in Connections."
        case .http(let status, let body):
            // Surface the body so 400/422 errors don't read as "magic Ollama
            // rejection" — most are "model does not support tools" or
            // "model not found", which the body explains directly.
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Ollama returned HTTP \(status)." }
            let snippet = trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
            return "Ollama returned HTTP \(status): \(snippet)"
        case .decoding(let error): return "Could not parse Ollama response: \(error.localizedDescription)"
        case .transport(let error): return "Could not reach Ollama: \(error.localizedDescription)"
        case .emptyResponse: return "Ollama returned an empty response."
        case .missingAPIKey: return "Ollama web search requires an API key (ollama.com account)."
        }
    }
}

@MainActor
final class OllamaService {
    static let shared = OllamaService()

    func ping() async -> Bool {
        // OpenAI-compatible: a GET /models with the API key is the cheapest
        // reachability + auth check.
        if AIProvider.current == .openAICompatible {
            guard let base = try? openAIBaseURL() else { return false }
            var req = URLRequest(url: base.appending(path: "/models"))
            if let auth = openAIAuthHeader() {
                req.setValue(auth, forHTTPHeaderField: "Authorization")
            }
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                return false
            }
        }
        guard let base = try? baseURL() else { return false }
        var req = URLRequest(url: base.appending(path: "/api/tags"))
        if let auth = authorizationHeader() {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// List available models. Ollama → /api/tags; OpenAI-compatible → /models.
    func listModels() async throws -> [String] {
        if AIProvider.current == .openAICompatible {
            return try await listOpenAIModels()
        }
        let url = try baseURL().appending(path: "/api/tags")
        var req = URLRequest(url: url)
        if let auth = authorizationHeader() {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw OllamaError.transport(error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct Tags: Decodable { let models: [Model] }
        struct Model: Decodable { let name: String }
        let parsed = try JSONDecoder().decode(Tags.self, from: data)
        return parsed.models.map(\.name).sorted()
    }

    private func listOpenAIModels() async throws -> [String] {
        let url = try openAIBaseURL().appending(path: "/models")
        var req = URLRequest(url: url)
        if let auth = openAIAuthHeader() {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw OllamaError.transport(error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct List: Decodable { let data: [Model] }
        struct Model: Decodable { let id: String }
        let parsed = try JSONDecoder().decode(List.self, from: data)
        return parsed.data.map(\.id).sorted()
    }

    private func baseURL() throws -> URL {
        let raw = UserDefaults.standard.string(forKey: "ollama.url") ?? "http://localhost:11434"
        guard let url = URL(string: raw) else { throw OllamaError.missingURL }
        return url
    }

    private func model() -> String {
        UserDefaults.standard.string(forKey: "ollama.model") ?? "llama3.2"
    }

    private func temperature() -> Double {
        (UserDefaults.standard.object(forKey: "ollama.temperature") as? Double) ?? 0.3
    }

    private func timeoutSeconds() -> TimeInterval {
        (UserDefaults.standard.object(forKey: "ollama.timeoutSeconds") as? Double) ?? 30
    }

    private func apiKey() -> String? {
        KeychainService.shared.get(.ollamaAuthHeader)
    }

    private func authorizationHeader() -> String? {
        guard let key = apiKey(), !key.isEmpty else { return nil }
        if key.lowercased().hasPrefix("bearer ") || key.lowercased().hasPrefix("basic ") {
            return key
        }
        return "Bearer \(key)"
    }
}

// MARK: - Chat / agentic API

/// One message in the Ollama /api/chat conversation. Mirrors the Ollama wire
/// shape so we can encode/decode directly.
struct OllamaChatMessage: Codable, Sendable {
    var role: String                  // "system" | "user" | "assistant" | "tool"
    var content: String               // free text (may be empty when only tool_calls)
    var images: [String]?             // base64 JPEG/PNG strings (no data: prefix)
    var tool_calls: [OllamaToolCall]?
    var tool_name: String?            // role=="tool" — which tool this result is for
    /// OpenAI-compatible only: the `tool_call_id` a tool result answers. Unused
    /// by the Ollama path (which keys results by `tool_name`). Defaulted so
    /// existing call sites don't change.
    var tool_call_id: String? = nil
}

struct OllamaToolCall: Codable, Sendable {
    /// OpenAI-compatible only: the call id used to pair an assistant tool_call
    /// with its tool result. nil on the Ollama path (Ollama omits it).
    var id: String? = nil
    let function: Function
    struct Function: Codable, Sendable {
        let name: String
        /// Arguments as raw JSON. Decoded on demand because the schema
        /// varies per tool. Stored as Data so we can hand it to JSONDecoder.
        let arguments: AnyJSON?
    }
}

/// A minimal "any JSON" wrapper. Ollama returns tool-call arguments as a
/// JSON object whose shape depends on the tool. We carry it as raw JSON bytes
/// so each caller can decode into its own struct.
///
/// Both Codable hooks store and emit the bytes as a real JSON value (object /
/// array / string / number / bool / null). An earlier version stringified the
/// payload on encode, which corrupted any tool spec or tool_call sent through
/// `JSONEncoder` — Ollama rejected the requests with `"Value looks like
/// object, but can't find closing '}' symbol"`. Don't reintroduce that.
struct AnyJSON: Codable, Sendable {
    let raw: Data

    init(raw: Data) { self.raw = raw }

    init(from decoder: Decoder) throws {
        // Read the singleValueContainer's underlying Foundation value via
        // JSONSerialization so nested objects round-trip without us having to
        // re-encode through the Codable graph (which is exactly the path that
        // used to introduce the stringification bug).
        if let c = try? decoder.singleValueContainer() {
            if c.decodeNil() {
                self.raw = "null".data(using: .utf8)!
                return
            }
            if let b = try? c.decode(Bool.self) {
                self.raw = (b ? "true" : "false").data(using: .utf8)!
                return
            }
            if let i = try? c.decode(Int64.self) {
                self.raw = "\(i)".data(using: .utf8)!
                return
            }
            if let d = try? c.decode(Double.self) {
                self.raw = "\(d)".data(using: .utf8)!
                return
            }
            if let s = try? c.decode(String.self) {
                let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])) ?? Data()
                self.raw = data
                return
            }
            if let dict = try? c.decode([String: AnyJSON].self) {
                self.raw = AnyJSON.serialize(dict: dict)
                return
            }
            if let arr = try? c.decode([AnyJSON].self) {
                self.raw = AnyJSON.serialize(array: arr)
                return
            }
        }
        self.raw = "null".data(using: .utf8)!
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let parsed = (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])) ?? NSNull()
        try AnyJSON.encode(value: parsed, into: &container)
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: raw)
    }

    // MARK: - Helpers

    private static func serialize(dict: [String: AnyJSON]) -> Data {
        var foundation: [String: Any] = [:]
        for (k, v) in dict {
            foundation[k] = (try? JSONSerialization.jsonObject(with: v.raw, options: [.fragmentsAllowed])) ?? NSNull()
        }
        return (try? JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed])) ?? Data()
    }

    private static func serialize(array: [AnyJSON]) -> Data {
        let foundation: [Any] = array.map { v in
            (try? JSONSerialization.jsonObject(with: v.raw, options: [.fragmentsAllowed])) ?? NSNull()
        }
        return (try? JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed])) ?? Data()
    }

    /// Recursively encodes a Foundation JSON value through Codable's
    /// singleValueContainer. Order matters: NSNumber-bool must be checked
    /// before NSNumber-numeric since a CFBoolean also bridges to NSNumber.
    private static func encode(value: Any, into container: inout SingleValueEncodingContainer) throws {
        if value is NSNull {
            try container.encodeNil(); return
        }
        if let n = value as? NSNumber {
            // CFBooleanGetTypeID detects __NSCFBoolean specifically; otherwise
            // a true/false value would encode as 1/0.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                try container.encode(n.boolValue); return
            }
            // Distinguish int from float by the Objective-C type encoding.
            let t = String(cString: n.objCType)
            if t == "f" || t == "d" {
                try container.encode(n.doubleValue); return
            }
            try container.encode(n.int64Value); return
        }
        if let s = value as? String {
            try container.encode(s); return
        }
        if let arr = value as? [Any] {
            let wrapped = arr.map { v -> AnyJSON in
                let bytes = (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]))
                    ?? "null".data(using: .utf8)!
                return AnyJSON(raw: bytes)
            }
            try container.encode(wrapped); return
        }
        if let dict = value as? [String: Any] {
            var wrapped: [String: AnyJSON] = [:]
            for (k, v) in dict {
                let bytes = (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]))
                    ?? "null".data(using: .utf8)!
                wrapped[k] = AnyJSON(raw: bytes)
            }
            try container.encode(wrapped); return
        }
        try container.encodeNil()
    }
}

struct OllamaChatResponse: Decodable, Sendable {
    let message: OllamaChatMessage
    let done: Bool?
}

/// Tool definition handed to Ollama.
struct OllamaToolSpec: Codable, Sendable {
    let type: String                  // "function"
    let function: Function

    struct Function: Codable, Sendable {
        let name: String
        let description: String
        let parameters: AnyJSON       // JSON schema for the parameters
    }

    static func function(name: String, description: String, parametersSchema: [String: Any]) -> OllamaToolSpec {
        // Store the JSON bytes directly. We deliberately avoid the
        // JSONDecoder→AnyJSON round-trip here: AnyJSON.encode(to:) writes its
        // raw payload as a JSON string, so decoding `[String: AnyJSON]` and
        // re-encoding it stringifies every nested value. That produced
        //   "required": "[\"query\"]", "properties": "{...}"
        // on the wire, which Ollama rejected with
        //   "Value looks like object, but can't find closing '}' symbol".
        let data = (try? JSONSerialization.data(withJSONObject: parametersSchema)) ?? "{}".data(using: .utf8)!
        return OllamaToolSpec(type: "function", function: .init(name: name, description: description, parameters: AnyJSON(raw: data)))
    }
}

extension OllamaService {
    /// Bridging helpers for ArchitectureAgent's web_search shim — exposes the
    /// private URL/model/auth helpers without leaking them broadly.
    func baseURLForExternal() throws -> URL { try baseURL() }
    func modelForExternal() -> String { model() }
    func authorizationHeaderForExternal() -> String? { authorizationHeader() }

    /// Send a chat completion to whichever provider is configured. Supports
    /// vision input via `images` on user messages and tool calling via `tools`.
    /// Returns the assistant's reply (which may include `tool_calls`).
    /// ArchitectureAgent calls this unchanged regardless of provider.
    func chat(messages: [OllamaChatMessage], tools: [OllamaToolSpec] = [], temperature: Double = 0.2) async throws -> OllamaChatMessage {
        switch AIProvider.current {
        case .ollama:
            return try await chatOllama(messages: messages, tools: tools, temperature: temperature)
        case .openAICompatible:
            return try await chatOpenAI(messages: messages, tools: tools, temperature: temperature)
        }
    }

    /// Send a chat completion through Ollama's /api/chat.
    private func chatOllama(messages: [OllamaChatMessage], tools: [OllamaToolSpec] = [], temperature: Double = 0.2) async throws -> OllamaChatMessage {
        let url = try baseURL().appending(path: "/api/chat")

        var body: [String: Any] = [
            "model": model(),
            "stream": false,
            "options": ["temperature": temperature],
        ]
        // Build messages manually. We deliberately avoid JSONEncoder here for
        // the same reason as `tools` below: AnyJSON.encode(to:) stringifies
        // its raw JSON, so an assistant turn's tool_calls[].function.arguments
        // (an object) ships as a JSON-encoded string. Ollama rejects with
        //   "Value looks like object, but can't find closing '}' symbol"
        var msgArr: [[String: Any]] = []
        for m in messages {
            var d: [String: Any] = ["role": m.role, "content": m.content]
            if let images = m.images { d["images"] = images }
            if let toolCalls = m.tool_calls {
                var tcArr: [[String: Any]] = []
                for tc in toolCalls {
                    var fn: [String: Any] = ["name": tc.function.name]
                    if let args = tc.function.arguments {
                        fn["arguments"] = (try? JSONSerialization.jsonObject(with: args.raw)) ?? [String: Any]()
                    } else {
                        fn["arguments"] = [String: Any]()
                    }
                    tcArr.append(["function": fn])
                }
                d["tool_calls"] = tcArr
            }
            if let tn = m.tool_name { d["tool_name"] = tn }
            msgArr.append(d)
        }
        body["messages"] = msgArr
        if !tools.isEmpty {
            // Build tools manually so `parameters` ships as a JSON object, not
            // a JSON-encoded string. AnyJSON's Codable round-trip stringifies
            // the schema, which Ollama rejects with:
            //   json: cannot unmarshal string into Go struct field
            //   ToolFunction.tools.function.parameters of type api.ToolFunctionParameters
            var toolsArr: [[String: Any]] = []
            for t in tools {
                let params: Any = (try? JSONSerialization.jsonObject(with: t.function.parameters.raw)) ?? [String: Any]()
                let fn: [String: Any] = [
                    "name": t.function.name,
                    "description": t.function.description,
                    "parameters": params,
                ]
                toolsArr.append(["type": t.type, "function": fn])
            }
            body["tools"] = toolsArr
        }

        logJSONBody("chat request body", body)

        let httpBody = try JSONSerialization.data(withJSONObject: body)
        ollamaLog.notice("chat POST \(url.absoluteString, privacy: .public) bytes=\(httpBody.count, privacy: .public) toolCount=\(tools.count, privacy: .public) msgCount=\(messages.count, privacy: .public)")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = httpBody
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = authorizationHeader() {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutSeconds() * 3
        cfg.timeoutIntervalForResource = timeoutSeconds() * 6
        let session = URLSession(configuration: cfg)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            ollamaLog.error("chat transport failed: \(error.localizedDescription, privacy: .public)")
            throw OllamaError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            ollamaLog.error("chat: response was not HTTPURLResponse")
            throw OllamaError.http(status: -1, body: "")
        }
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        ollamaLog.notice("chat response status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")
        guard (200..<300).contains(http.statusCode) else {
            let snippet = bodyString.count > 800 ? String(bodyString.prefix(800)) + "…" : bodyString
            ollamaLog.error("chat HTTP \(http.statusCode, privacy: .public) body=\(snippet, privacy: .public)")
            throw OllamaError.http(status: http.statusCode, body: bodyString)
        }

        do {
            let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            return decoded.message
        } catch {
            let snippet = bodyString.count > 600 ? String(bodyString.prefix(600)) + "…" : bodyString
            ollamaLog.error("chat decode failed: \(error.localizedDescription, privacy: .public) raw=\(snippet, privacy: .public)")
            throw OllamaError.decoding(error)
        }
    }

    // MARK: - OpenAI-compatible provider

    private func openAIBaseURL() throws -> URL {
        let raw = (UserDefaults.standard.string(forKey: AIProvider.Keys.openAIBaseURL) ?? AIProvider.defaultOpenAIBaseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a trailing slash so "…/v1/" and "…/v1" both work.
        let cleaned = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard !cleaned.isEmpty, let url = URL(string: cleaned) else { throw OllamaError.missingURL }
        return url
    }

    private func openAIModel() -> String {
        let m = (UserDefaults.standard.string(forKey: AIProvider.Keys.openAIModel) ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? AIProvider.defaultOpenAIModel : m
    }

    private func openAIAuthHeader() -> String? {
        guard let key = KeychainService.shared.get(.openAIAPIKey), !key.isEmpty else { return nil }
        if key.lowercased().hasPrefix("bearer ") { return key }
        return "Bearer \(key)"
    }

    /// Convert our internal message list into the OpenAI `/chat/completions`
    /// shape. Two structural differences from Ollama are handled here:
    ///   • images ride inside a `content` array as `image_url` data: URLs
    ///     rather than a sibling `images` array of bare base64.
    ///   • tool results must reference the assistant tool_call's `id` via
    ///     `tool_call_id`. The agent keys results by tool *name*, so we pair
    ///     each result with the most recent unmatched call of that name.
    private func openAIMessages(from messages: [OllamaChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        // FIFO of (id, name) from the latest assistant turn awaiting results.
        var pendingCalls: [(id: String, name: String)] = []

        for m in messages {
            switch m.role {
            case "tool":
                var d: [String: Any] = ["role": "tool", "content": m.content]
                // Prefer an explicit id; else match by name; else first pending.
                if let explicit = m.tool_call_id {
                    d["tool_call_id"] = explicit
                } else if let idx = pendingCalls.firstIndex(where: { $0.name == m.tool_name }) {
                    d["tool_call_id"] = pendingCalls[idx].id
                    pendingCalls.remove(at: idx)
                } else if !pendingCalls.isEmpty {
                    d["tool_call_id"] = pendingCalls.removeFirst().id
                }
                out.append(d)

            case "assistant" where (m.tool_calls?.isEmpty == false):
                pendingCalls.removeAll()
                var calls: [[String: Any]] = []
                for (i, tc) in (m.tool_calls ?? []).enumerated() {
                    let id = tc.id ?? "call_\(out.count)_\(i)"
                    let argsString: String
                    if let raw = tc.function.arguments?.raw, !raw.isEmpty {
                        argsString = String(data: raw, encoding: .utf8) ?? "{}"
                    } else {
                        argsString = "{}"
                    }
                    calls.append([
                        "id": id,
                        "type": "function",
                        "function": ["name": tc.function.name, "arguments": argsString],
                    ])
                    pendingCalls.append((id: id, name: tc.function.name))
                }
                // OpenAI accepts null content alongside tool_calls.
                out.append(["role": "assistant", "content": m.content, "tool_calls": calls])

            default:
                if let images = m.images, !images.isEmpty {
                    var parts: [[String: Any]] = [["type": "text", "text": m.content]]
                    for b64 in images {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(b64)"],
                        ])
                    }
                    out.append(["role": m.role, "content": parts])
                } else {
                    out.append(["role": m.role, "content": m.content])
                }
            }
        }
        return out
    }

    /// Send a chat completion through an OpenAI-compatible `/chat/completions`
    /// endpoint. Mirrors `chatOllama`'s contract: returns the assistant message,
    /// possibly carrying `tool_calls`.
    private func chatOpenAI(messages: [OllamaChatMessage], tools: [OllamaToolSpec] = [], temperature: Double = 0.2) async throws -> OllamaChatMessage {
        guard openAIAuthHeader() != nil else { throw OllamaError.missingAPIKey }
        let url = try openAIBaseURL().appending(path: "/chat/completions")

        var body: [String: Any] = [
            "model": openAIModel(),
            "temperature": temperature,
            "messages": openAIMessages(from: messages),
        ]
        if !tools.isEmpty {
            var toolsArr: [[String: Any]] = []
            for t in tools {
                let params: Any = (try? JSONSerialization.jsonObject(with: t.function.parameters.raw)) ?? [String: Any]()
                toolsArr.append([
                    "type": t.type,
                    "function": [
                        "name": t.function.name,
                        "description": t.function.description,
                        "parameters": params,
                    ],
                ])
            }
            body["tools"] = toolsArr
        }

        logJSONBody("openai chat request body", body)
        let httpBody = try JSONSerialization.data(withJSONObject: body)
        ollamaLog.notice("openai chat POST \(url.absoluteString, privacy: .public) bytes=\(httpBody.count, privacy: .public) toolCount=\(tools.count, privacy: .public) msgCount=\(messages.count, privacy: .public)")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = httpBody
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = openAIAuthHeader() {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutSeconds() * 3
        cfg.timeoutIntervalForResource = timeoutSeconds() * 6
        let session = URLSession(configuration: cfg)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            ollamaLog.error("openai chat transport failed: \(error.localizedDescription, privacy: .public)")
            throw OllamaError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.http(status: -1, body: "")
        }
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        ollamaLog.notice("openai chat response status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")
        guard (200..<300).contains(http.statusCode) else {
            let snippet = bodyString.count > 800 ? String(bodyString.prefix(800)) + "…" : bodyString
            ollamaLog.error("openai chat HTTP \(http.statusCode, privacy: .public) body=\(snippet, privacy: .public)")
            throw OllamaError.http(status: http.statusCode, body: bodyString)
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw OllamaError.emptyResponse
        }

        let content = (message["content"] as? String) ?? ""
        var toolCalls: [OllamaToolCall]? = nil
        if let rawCalls = message["tool_calls"] as? [[String: Any]], !rawCalls.isEmpty {
            toolCalls = rawCalls.compactMap { call -> OllamaToolCall? in
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String else { return nil }
                let id = call["id"] as? String
                // OpenAI hands arguments back as a JSON STRING; its bytes are
                // already valid JSON for AnyJSON to carry.
                let argsString = (fn["arguments"] as? String) ?? "{}"
                let argsData = argsString.data(using: .utf8) ?? Data("{}".utf8)
                return OllamaToolCall(id: id, function: .init(name: name, arguments: AnyJSON(raw: argsData)))
            }
        }

        return OllamaChatMessage(role: "assistant", content: content, images: nil, tool_calls: toolCalls, tool_name: nil)
    }

    /// Load an image, downscale to fit within `maxDimension` PIXELS, JPEG-
    /// encode, and base64-encode for vision input. Vision models choke on
    /// multi-MB images and we don't need full resolution to identify a building.
    ///
    /// ImageIO thumbnailing, off the main actor, for two reasons:
    ///   • The old NSImage/lockFocus path measured in POINTS — on a Retina Mac
    ///     "768" produced a 1536-pixel bitmap, quadrupling the vision token
    ///     cost without telling anyone.
    ///   • Decoding + re-encoding a multi-MB wallpaper was running ON the main
    ///     actor (ArchitectureAgent is @MainActor), hitching the UI at the
    ///     start of every enrichment.
    static func imageBase64(from fileURL: URL, maxDimension: CGFloat = 768) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
                return nil
            }
            let jpegOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
            CGImageDestinationAddImage(dest, cg, jpegOptions as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return (out as Data).base64EncodedString()
        }.value
    }
}
