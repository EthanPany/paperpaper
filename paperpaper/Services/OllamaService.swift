import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

private let ollamaLog = Logger(subsystem: "ep.paperpaper", category: "ollama")

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

struct OllamaEnrichment: Decodable, Sendable {
    let name: String?
    let architect: String?
    let year: Int?
    let style: String?
    let one_sentence: String?
}

/// Result of the architecture confirm step. `confidence` is the model's own
/// self-rating ("high" / "medium" / "low"); ArchitectureAgent uses it to
/// decide whether to commit fields or leave them blank.
struct OllamaArchitectureConfirmation: Decodable, Sendable {
    let name: String?
    let architect: String?
    let year: Int?
    let style: String?
    let one_sentence: String?
    let confidence: String?
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

    func enrich(candidate: BuildingDetector.Candidate, tags: [String], gps: (lat: Double, lon: Double)?) async throws -> OllamaEnrichment {
        let url = try baseURL().appending(path: "/api/generate")
        let prompt = buildPrompt(candidate: candidate, tags: tags, gps: gps)

        if webSearch() && (apiKey() ?? "").isEmpty {
            throw OllamaError.missingAPIKey
        }

        var body: [String: Any] = [
            "model": model(),
            "prompt": prompt,
            "format": "json",
            "stream": false,
            "options": [
                "temperature": temperature(),
            ],
        ]
        if webSearch() {
            body["tools"] = [["type": "web_search"]]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = authorizationHeader() {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutSeconds()
        cfg.timeoutIntervalForResource = timeoutSeconds() * 2
        let session = URLSession(configuration: cfg)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OllamaError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.http(status: -1, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct OllamaResponse: Decodable { let response: String }
        let outer: OllamaResponse
        do {
            outer = try JSONDecoder().decode(OllamaResponse.self, from: data)
        } catch {
            throw OllamaError.decoding(error)
        }

        guard let innerData = outer.response.data(using: .utf8), !outer.response.isEmpty else {
            throw OllamaError.emptyResponse
        }
        do {
            return try JSONDecoder().decode(OllamaEnrichment.self, from: innerData)
        } catch {
            throw OllamaError.decoding(error)
        }
    }

    /// Architecture-confirm step. Hands the model a candidate name *and* a
    /// list of nearby POIs from MapKit, asks it to pick the best match (or
    /// none) and self-rate confidence as high / medium / low.
    func confirmArchitecture(
        candidate: BuildingDetector.Candidate?,
        photoDescription: String?,
        tags: [String],
        area: String?,
        gps: (lat: Double, lon: Double)?,
        nearby: [ArchitectureAgent.NearbyPOI]
    ) async throws -> OllamaArchitectureConfirmation {
        let url = try baseURL().appending(path: "/api/generate")
        let prompt = buildConfirmPrompt(
            candidate: candidate,
            photoDescription: photoDescription,
            tags: tags,
            area: area,
            gps: gps,
            nearby: nearby
        )

        if webSearch() && (apiKey() ?? "").isEmpty {
            throw OllamaError.missingAPIKey
        }

        var body: [String: Any] = [
            "model": model(),
            "prompt": prompt,
            "format": "json",
            "stream": false,
            "options": [
                "temperature": 0.1,
            ],
        ]
        if webSearch() {
            body["tools"] = [["type": "web_search"]]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = authorizationHeader() {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutSeconds()
        cfg.timeoutIntervalForResource = timeoutSeconds() * 2
        let session = URLSession(configuration: cfg)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OllamaError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.http(status: -1, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct OllamaResponse: Decodable { let response: String }
        let outer = try JSONDecoder().decode(OllamaResponse.self, from: data)
        guard let innerData = outer.response.data(using: .utf8), !outer.response.isEmpty else {
            throw OllamaError.emptyResponse
        }
        return try JSONDecoder().decode(OllamaArchitectureConfirmation.self, from: innerData)
    }

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

    private func webSearch() -> Bool {
        UserDefaults.standard.bool(forKey: "ollama.webSearch")
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

    private func buildConfirmPrompt(
        candidate: BuildingDetector.Candidate?,
        photoDescription: String?,
        tags: [String],
        area: String?,
        gps: (lat: Double, lon: Double)?,
        nearby: [ArchitectureAgent.NearbyPOI]
    ) -> String {
        var lines: [String] = [
            "You are an architecture and place identification assistant.",
            "Given metadata about an Unsplash photo, do BOTH of these:",
            "",
            "1. Try to identify a specific building. Only commit if you are highly",
            "   confident based on candidate name + nearby landmarks + location.",
            "2. ALWAYS write one short factual sentence (under 25 words) describing",
            "   the place or scene — even when no specific building can be named.",
            "   Use the area / city / country / nearby landmarks as fallback.",
            "",
            "Return ONLY a JSON object with these keys (no prose, no markdown):",
            "  name (string|null) — specific building name, null if not confident",
            "  architect (string|null) — null unless certain",
            "  year (int|null) — null unless certain",
            "  style (string|null) — architectural style if applicable",
            "  one_sentence (string) — REQUIRED, never null. Describes the place.",
            "  confidence (\"high\"|\"medium\"|\"low\") — your confidence in `name`",
            "",
            "Rules:",
            "- one_sentence must be populated even when you cannot identify a building.",
            "  In that case, describe the location (\"A street view in Lisbon, Portugal\")",
            "  or scene type (\"Brutalist concrete facade in mid-day light\").",
            "- If the candidate is generic (\"white building\", \"church\") and nearby",
            "  landmarks don't match strongly, confidence=\"low\" and name=null.",
            "- Never invent an architect or a year. Use null when unsure.",
            "- No marketing language; neutral and factual only.",
            "",
        ]

        if let candidate {
            lines.append("Candidate name: \(candidate.name)")
            if let hint = candidate.hint, !hint.isEmpty {
                lines.append("Candidate hint: \(hint)")
            }
        } else {
            lines.append("Candidate name: (none — only generic visual hints)")
        }

        if let desc = photoDescription, !desc.isEmpty {
            lines.append("Photo description: \(desc)")
        }
        if !tags.isEmpty {
            lines.append("Tags: \(tags.prefix(12).joined(separator: ", "))")
        }
        if let area, !area.isEmpty {
            lines.append("Area / city: \(area)")
        }
        if let gps {
            lines.append("GPS: \(String(format: "%.4f, %.4f", gps.lat, gps.lon))")
        } else {
            lines.append("GPS: unknown")
        }

        if nearby.isEmpty {
            lines.append("Nearby landmarks: (none returned by map search)")
        } else {
            lines.append("Nearby landmarks within ~800m:")
            for poi in nearby {
                let dist = poi.distanceMeters.map { String(format: "%.0fm", $0) } ?? "?"
                let cat = poi.category ?? "poi"
                lines.append("  - \(poi.name) [\(cat)] \(dist)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func buildPrompt(candidate: BuildingDetector.Candidate, tags: [String], gps: (lat: Double, lon: Double)?) -> String {
        var lines = [
            "You are an architecture expert. Given a candidate building name and contextual tags,",
            "return a JSON object with EXACTLY these keys: name, architect, year, style, one_sentence.",
            "If you are not confident about any field, use null for that field (not a guess).",
            "one_sentence must be a single sentence, under 25 words, factual and neutral.",
            "Do not include any text outside the JSON.",
            "",
            "Candidate: \(candidate.name)",
        ]
        if let hint = candidate.hint, !hint.isEmpty {
            lines.append("Location hint: \(hint)")
        }
        if !tags.isEmpty {
            lines.append("Tags: \(tags.prefix(12).joined(separator: ", "))")
        }
        if let gps {
            lines.append("GPS: \(String(format: "%.4f, %.4f", gps.lat, gps.lon))")
        }
        return lines.joined(separator: "\n")
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
/// JSON object whose shape depends on the tool. We carry it as Data so each
/// caller can decode into its own struct.
struct AnyJSON: Codable, Sendable {
    let raw: Data
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Re-encode whatever was decoded back to JSON Data.
        if let dict = try? container.decode([String: AnyJSON].self) {
            self.raw = try JSONEncoder().encode(dict)
        } else if let arr = try? container.decode([AnyJSON].self) {
            self.raw = try JSONEncoder().encode(arr)
        } else if let s = try? container.decode(String.self) {
            // Some models return arguments as a JSON-encoded string.
            self.raw = s.data(using: .utf8) ?? Data()
        } else if let n = try? container.decode(Double.self) {
            self.raw = "\(n)".data(using: .utf8) ?? Data()
        } else if let b = try? container.decode(Bool.self) {
            self.raw = (b ? "true" : "false").data(using: .utf8) ?? Data()
        } else {
            self.raw = Data()
        }
    }
    func encode(to encoder: Encoder) throws {
        // Best-effort: write the raw bytes through.
        var container = encoder.singleValueContainer()
        if let obj = try? JSONSerialization.jsonObject(with: raw) {
            let data = try JSONSerialization.data(withJSONObject: obj)
            try container.encode(String(data: data, encoding: .utf8) ?? "")
        } else {
            try container.encode(String(data: raw, encoding: .utf8) ?? "")
        }
    }
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: raw)
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

extension AnyJSON {
    static let empty: AnyJSON = {
        let data = "{}".data(using: .utf8)!
        return (try? JSONDecoder().decode(AnyJSON.self, from: data)) ?? Self(raw: data)
    }()
    init(raw: Data) { self.raw = raw }
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
