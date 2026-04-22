import Foundation

/// A progressive, tool-driven search agent.
///
/// Tools exposed to the agent:
///   1. unsplash — `search(query:)` over Unsplash results.
///   2. web_search — optional, via Ollama's built-in web_search tool when a
///      user-provided Ollama API key is configured. Used for research/context.
///   3. writing — `compose(facts:)` using the local Ollama model to produce a
///      short paragraph.
///
/// The agent widens its Unsplash query progressively when the initial prompt
/// + location returns zero results: specific → area → city → country → global.
@MainActor
final class SearchAgent {
    static let shared = SearchAgent()

    struct Request: Sendable {
        var prompt: String
        var location: String?
        var includeWebResearch: Bool
        var includeParagraph: Bool
    }

    struct Result: Sendable {
        var photo: UnsplashPhoto
        var usedQuery: String
        var paragraph: String?
        var researchNotes: String?
        var broadeningSteps: [String]
    }

    enum SearchError: Error, LocalizedError {
        case noResults
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .noResults: return "No results, even after broadening the search."
            case .underlying(let error): return error.localizedDescription
            }
        }
    }

    func run(_ request: Request) async throws -> Result {
        var steps: [String] = []
        let ladder = buildQueryLadder(prompt: request.prompt, location: request.location)

        var found: (query: String, photo: UnsplashPhoto)?
        for query in ladder {
            steps.append("try: \(query)")
            do {
                let page = try await UnsplashService.shared.search(query: query, page: 1, perPage: 8)
                if let first = page.results.first {
                    found = (query, first)
                    steps.append("hit: \(first.description ?? first.alt_description ?? "photo \(first.id)")")
                    break
                }
                steps.append("miss")
            } catch {
                steps.append("err: \(error.localizedDescription)")
            }
        }

        guard let hit = found else { throw SearchError.noResults }

        var research: String?
        if request.includeWebResearch {
            research = await runWebResearch(for: hit.photo)
            if research != nil { steps.append("research: done") }
        }

        var paragraph: String?
        if request.includeParagraph {
            do {
                paragraph = try await writeParagraph(for: hit.photo, research: research)
                steps.append("writing: done")
            } catch {
                steps.append("writing: \(error.localizedDescription)")
            }
        }

        return Result(
            photo: hit.photo,
            usedQuery: hit.query,
            paragraph: paragraph,
            researchNotes: research,
            broadeningSteps: steps
        )
    }

    // MARK: - Tools

    /// Tool #1: Unsplash search. Stays identical to the normal UnsplashService.
    private func unsplashSearch(query: String) async throws -> [UnsplashPhoto] {
        try await UnsplashService.shared.search(query: query, page: 1, perPage: 8).results
    }

    /// Tool #2: Web research via Ollama's web_search tool. Returns a short notes
    /// string the model decided to emit. Silently returns nil on any failure.
    private func runWebResearch(for photo: UnsplashPhoto) async -> String? {
        let subject = photo.description ?? photo.alt_description ?? photo.location?.name ?? "this architecture photo"
        let candidate = BuildingDetector.Candidate(name: subject, hint: photo.location?.city ?? photo.location?.country)
        do {
            let result = try await OllamaService.shared.enrich(
                candidate: candidate,
                tags: photo.tags?.map(\.title) ?? [],
                gps: photo.location?.position.flatMap { pos in
                    guard let lat = pos.latitude, let lon = pos.longitude else { return nil }
                    return (lat: lat, lon: lon)
                }
            )
            return [result.name, result.architect.map { "by \($0)" }, result.year.map(String.init), result.style]
                .compactMap { $0 }
                .joined(separator: " · ")
        } catch {
            return nil
        }
    }

    /// Tool #3: Writing. Compose a short neutral paragraph from the facts we have.
    private func writeParagraph(for photo: UnsplashPhoto, research: String?) async throws -> String {
        let subject = photo.description ?? photo.alt_description ?? "this architecture photo"
        let candidate = BuildingDetector.Candidate(name: subject, hint: photo.location?.city ?? photo.location?.country)
        let enrichment = try await OllamaService.shared.enrich(
            candidate: candidate,
            tags: photo.tags?.map(\.title) ?? [],
            gps: nil
        )
        return enrichment.one_sentence ?? research ?? subject
    }

    // MARK: - Query ladder

    /// Builds a broadening list of queries from most-specific to most-general.
    private func buildQueryLadder(prompt: String, location: String?) -> [String] {
        var steps: [String] = []
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if let location, !location.isEmpty {
            steps.append("\(trimmed) \(location)")
            // Split location by commas and progressively use less specific pieces
            let parts = location.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for dropCount in 1..<parts.count {
                let broader = parts.dropFirst(dropCount).joined(separator: ", ")
                if !broader.isEmpty {
                    steps.append("\(trimmed) \(broader)")
                }
            }
        }

        if !trimmed.isEmpty { steps.append(trimmed) }
        if trimmed.contains(" ") {
            if let lastWord = trimmed.split(separator: " ").last {
                steps.append(String(lastWord))
            }
        }
        if !steps.contains("architecture") { steps.append("architecture") }
        return Array(NSOrderedSet(array: steps)) as? [String] ?? steps
    }
}
