import Foundation
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

    /// List local models via /api/tags.
    func listModels() async throws -> [String] {
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
}

struct OllamaToolCall: Codable, Sendable {
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

    /// Send a chat completion through /api/chat. Supports vision input via
    /// `images` on user messages and tool calling via `tools`. Returns the
    /// assistant's reply (which may include `tool_calls`).
    func chat(messages: [OllamaChatMessage], tools: [OllamaToolSpec] = [], temperature: Double = 0.2) async throws -> OllamaChatMessage {
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

    /// Load an image, downscale to fit within `maxDimension`, JPEG-encode,
    /// and base64-encode for vision input. Vision models choke on multi-MB
    /// images and we don't need full resolution to identify a building.
    static func imageBase64(from fileURL: URL, maxDimension: CGFloat = 768) -> String? {
        #if canImport(AppKit)
        guard let nsImage = NSImage(contentsOf: fileURL) else { return nil }
        let originalSize = nsImage.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }

        let scale = min(1.0, maxDimension / max(originalSize.width, originalSize.height))
        let newSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: newSize),
                     from: NSRect(origin: .zero, size: originalSize),
                     operation: .copy,
                     fraction: 1.0)
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }
        return jpeg.base64EncodedString()
        #else
        return nil
        #endif
    }
}
