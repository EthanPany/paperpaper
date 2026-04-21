import Foundation

struct OllamaEnrichment: Decodable, Sendable {
    let name: String?
    let architect: String?
    let year: Int?
    let style: String?
    let one_sentence: String?
}

enum OllamaError: Error, LocalizedError {
    case missingURL
    case http(status: Int, body: String)
    case decoding(Error)
    case transport(Error)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingURL: return "Set your Ollama Host URL in Connections."
        case .http(let status, _): return "Ollama returned HTTP \(status)."
        case .decoding(let error): return "Could not parse Ollama response: \(error.localizedDescription)"
        case .transport(let error): return "Could not reach Ollama: \(error.localizedDescription)"
        case .emptyResponse: return "Ollama returned an empty response."
        }
    }
}

@MainActor
final class OllamaService {
    static let shared = OllamaService()

    func enrich(candidate: BuildingDetector.Candidate, tags: [String], gps: (lat: Double, lon: Double)?) async throws -> OllamaEnrichment {
        let url = try baseURL().appending(path: "/api/generate")
        let prompt = buildPrompt(candidate: candidate, tags: tags, gps: gps)

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
            body["options.tools"] = ["web_search"]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = KeychainService.shared.get(.ollamaAuthHeader), !auth.isEmpty {
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

    func ping() async -> Bool {
        guard let base = try? baseURL() else { return false }
        var req = URLRequest(url: base.appending(path: "/api/tags"))
        req.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
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
