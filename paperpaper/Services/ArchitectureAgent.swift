import Foundation
import os
#if canImport(MapKit)
import MapKit
#endif

/// Vision + tool-using agent that enriches a Photo with building / place info.
///
/// Pipeline:
///   1. Load the image, downscale, and feed it to the vision model along
///      with everything we know about the photo (description, tags, EXIF GPS,
///      area string, nearby landmarks from a first-pass MapKit search).
///   2. Hand the model three tools:
///        - `mapkit_search`  → live MapKit local-search (queries can target
///                              other coordinates, useful when the photographer
///                              shot a landmark from a distance).
///        - `web_search`     → Ollama-hosted web search. Only enabled if the
///                              user has configured `ollama.webSearch=true`
///                              AND has an API key in keychain.
///        - `commit_enrichment` (TERMINAL) → final write of the enrichment
///                              fields. Loop exits when this fires.
///   3. Iterate up to 4 turns. If the model never calls `commit_enrichment`,
///      try to parse a JSON commit from the last text response as a fallback.
///
/// Returns nil only when nothing usable could be produced (Ollama unreachable,
/// model unable to commit). Caller treats nil as "leave fields blank".
@MainActor
enum ArchitectureAgent {
    private static let log = Logger(subsystem: "ep.paperpaper", category: "arch-agent")
    private static let maxIterations = 4

    struct Confirmed: Sendable {
        var name: String
        var architect: String?
        var year: Int?
        var style: String?
        var oneSentence: String?
        /// More-specific place description (e.g. "Brooklyn Bridge Park,
        /// Brooklyn, NY") that the agent committed via `commit_enrichment`'s
        /// `location` field. Backfills photo.locationName when Unsplash gave
        /// us only a country.
        var location: String?
    }

    struct NearbyPOI: Sendable {
        var name: String
        var category: String?
        var distanceMeters: Double?
        var address: String?
    }

    /// Top-level entry. Pass the original image URL so the model can SEE it.
    static func confirm(for photo: Photo, imageFileURL: URL?) async -> Confirmed? {
        let gps: (lat: Double, lon: Double)?
        if let lat = photo.exif?.latitude, let lon = photo.exif?.longitude {
            gps = (lat, lon)
        } else {
            gps = nil
        }

        let initialNearby = await mapkitSearch(query: "landmark", at: gps, radius: 800)
        let area = photo.areaText.isEmpty ? nil : photo.areaText

        log.info("agent start: gps=\(gps == nil ? "no" : "yes", privacy: .public) area=\(area ?? "-", privacy: .public) initialNearby=\(initialNearby.count, privacy: .public) image=\(imageFileURL?.path ?? "-", privacy: .public)")

        let imageB64: String?
        if let imageFileURL {
            imageB64 = OllamaService.imageBase64(from: imageFileURL, maxDimension: 768)
            if imageB64 == nil {
                log.error("agent: failed to load image from \(imageFileURL.path, privacy: .public)")
            }
        } else {
            imageB64 = nil
        }

        // Build the initial conversation.
        var messages: [OllamaChatMessage] = []
        messages.append(OllamaChatMessage(
            role: "system",
            content: systemPrompt(),
            images: nil,
            tool_calls: nil,
            tool_name: nil
        ))
        messages.append(OllamaChatMessage(
            role: "user",
            content: userPrompt(photo: photo, area: area, gps: gps, initialNearby: initialNearby),
            images: imageB64.map { [$0] },
            tool_calls: nil,
            tool_name: nil
        ))

        let tools = activeTools()

        // Agentic loop.
        for iteration in 0..<maxIterations {
            let assistant: OllamaChatMessage
            do {
                assistant = try await OllamaService.shared.chat(messages: messages, tools: tools, temperature: 0.2)
            } catch {
                log.error("agent: chat failed iter=\(iteration, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
                return nil
            }

            // Append the assistant turn so subsequent tool messages have context.
            messages.append(assistant)

            // 1) Did the assistant request tool calls?
            if let calls = assistant.tool_calls, !calls.isEmpty {
                log.info("agent iter=\(iteration, privacy: .public): \(calls.count, privacy: .public) tool call(s)")
                for call in calls {
                    let name = call.function.name
                    if name == "commit_enrichment" {
                        if let confirmed = decodeCommit(call.function.arguments) {
                            log.info("agent: commit via tool — name=\(confirmed.name, privacy: .public)")
                            return confirmed
                        } else {
                            log.error("agent: commit args could not be decoded")
                        }
                    } else if name == "mapkit_search" {
                        let result = await runMapKitSearch(call.function.arguments, defaultGPS: gps)
                        messages.append(toolResultMessage(name: name, json: result))
                    } else if name == "web_search" {
                        let result = await runWebSearch(call.function.arguments)
                        messages.append(toolResultMessage(name: name, json: result))
                    } else {
                        log.error("agent: unknown tool \(name, privacy: .public)")
                        messages.append(toolResultMessage(name: name, json: "{\"error\":\"unknown tool\"}"))
                    }
                }
                continue
            }

            // 2) No tool call — is the text a JSON commit fallback?
            if let confirmed = decodeCommitFromText(assistant.content) {
                log.info("agent: commit via text-JSON fallback — name=\(confirmed.name, privacy: .public)")
                return confirmed
            }

            // 3) Plain text. Nudge the model to commit on the next turn.
            log.info("agent iter=\(iteration, privacy: .public): no tool / no JSON, prompting commit")
            messages.append(OllamaChatMessage(
                role: "user",
                content: "Now call the `commit_enrichment` tool with your final answer. If you can't identify a specific building, set building_name=null and confidence=\"low\", but still produce a one_sentence describing the place or scene.",
                images: nil, tool_calls: nil, tool_name: nil
            ))
        }

        log.info("agent: loop ended without commit")
        return nil
    }

    // MARK: - Prompts

    private static func systemPrompt() -> String {
        """
        You are an architecture and place-identification agent. The user gives you a photo
        plus metadata. You may call tools to gather more context, then you MUST finish by
        calling the `commit_enrichment` tool with your conclusion.

        Tools available:
          • mapkit_search(query, latitude?, longitude?, radius_meters?) — search Apple Maps
            for landmarks/POIs. Use when you suspect a different location than the EXIF
            GPS, or to look up a specific candidate building name.
          • web_search(query) — open-web search (only available when configured).
          • commit_enrichment(building_name?, architect?, year?, style?, location,
            one_sentence, confidence) — REQUIRED terminal call. `location` and
            `one_sentence` are REQUIRED (never null). Use null for building_name /
            architect / year / style only when uncertain. confidence ∈
            {"high","medium","low"} reflects your certainty in the building
            identification.

        Rules:
          • `building_name` and `location` MUST be distinct fields with different
            granularity. They are NOT synonyms.
              - `building_name` = the SPECIFIC subject of the photo: a named
                building, bridge, monument, park, plaza, or natural landmark
                ("Brooklyn Bridge", "Sagrada Família", "Empire State Building",
                "Yosemite Half Dome", "Trafalgar Square Fountain"). It is what
                a viewer would point at and name.
              - `location` = the SURROUNDING geographic context where that
                subject sits — neighborhood / district + city + country
                ("DUMBO, Brooklyn, NY, USA", "Eixample, Barcelona, Spain").
              - building_name and location must NEVER repeat the same string.
                If the photo is "Brooklyn Bridge", building_name="Brooklyn
                Bridge" and location="DUMBO, Brooklyn, NY, USA" — not
                building_name="Brooklyn, NYC" and location="Brooklyn, NYC,
                USA" (those are both location strings; there's no anchor).
              - If you cannot identify a specific subject (generic street,
                sky, water, flowers): set building_name=null. Don't fill
                building_name with a city — that's what location is for.
          • Don't invent architects or dates. Use null when unsure.
          • `location` MUST be at street / building / district granularity — never
            just the country, never just the city if a more specific anchor is
            available. Format "Anchor, City, Country" where Anchor is a named
            neighborhood / district / public park / plaza or named street.
              - Good: "DUMBO, Brooklyn, NY, USA"
              - Good: "Las Ramblas, Barcelona, Spain"
              - Good: "Roppongi, Tokyo, Japan"
              - Bad: "United States", "Spain", "Tokyo" alone
              - Bad: same string as building_name
            If the EXIF GPS or your tool results don't pin the photo to a specific
            anchor, use `mapkit_search` first — find the nearest neighborhood,
            park, or named area and base `location` on that. Only fall back to
            "City, Country" when nothing more specific can be confidently named,
            and never fabricate.
          • If the photo is generic (street, sky, flowers) or the building can't be
            confidently named, still commit with one_sentence describing the place
            ("A street view in Lisbon, Portugal") and confidence="low" — but
            `location` still must reach district level when possible.
          • Keep tool use short — at most 2 lookups before committing.
        """
    }

    private static func userPrompt(photo: Photo, area: String?, gps: (lat: Double, lon: Double)?, initialNearby: [NearbyPOI]) -> String {
        var lines: [String] = ["Identify the place / building in the attached photo."]
        if let desc = photo.photoDescription ?? photo.altDescription, !desc.isEmpty {
            lines.append("Photo description (Unsplash): \(desc)")
        }
        if !photo.tags.isEmpty {
            lines.append("Tags: \(photo.tags.prefix(12).joined(separator: ", "))")
        }
        if let area {
            lines.append("Area / city (Unsplash location string): \(area)")
        }
        if let gps {
            lines.append("EXIF GPS: \(String(format: "%.4f, %.4f", gps.lat, gps.lon))")
        } else {
            lines.append("EXIF GPS: unknown")
        }
        if !initialNearby.isEmpty {
            lines.append("Nearby landmarks (Apple Maps, ~800m radius around EXIF):")
            for poi in initialNearby.prefix(8) {
                let dist = poi.distanceMeters.map { String(format: "%.0fm", $0) } ?? "?"
                let cat = poi.category ?? "poi"
                lines.append("  - \(poi.name) [\(cat)] \(dist)")
            }
        }
        lines.append("")
        lines.append("Use the tools if you need more info, then call commit_enrichment.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Tool definitions

    private static func activeTools() -> [OllamaToolSpec] {
        var tools: [OllamaToolSpec] = []

        tools.append(OllamaToolSpec.function(
            name: "mapkit_search",
            description: "Search Apple Maps for landmarks/POIs. Use to look up specific buildings or to search around different coordinates than the EXIF GPS.",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Free-text search query, e.g. \"Sagrada Família\" or \"museum\""],
                    "latitude": ["type": "number", "description": "Optional. Defaults to EXIF GPS latitude."],
                    "longitude": ["type": "number", "description": "Optional. Defaults to EXIF GPS longitude."],
                    "radius_meters": ["type": "number", "description": "Optional. Search radius in meters. Default 800."]
                ],
                "required": ["query"]
            ]
        ))

        // Only expose web_search when the user has configured it AND has an API key.
        if UserDefaults.standard.bool(forKey: "ollama.webSearch"),
           let apiKey = KeychainService.shared.get(.ollamaAuthHeader),
           !apiKey.isEmpty {
            tools.append(OllamaToolSpec.function(
                name: "web_search",
                description: "Search the open web via Ollama. Use to look up architects, year built, style for a candidate building name.",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query string"]
                    ],
                    "required": ["query"]
                ]
            ))
        }

        tools.append(OllamaToolSpec.function(
            name: "commit_enrichment",
            description: "REQUIRED terminal tool. Commit your final enrichment for the photo. building_name (the SPECIFIC subject) and location (the SURROUNDING area) must be distinct strings with different granularity.",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "building_name": ["type": ["string", "null"], "description": "The SPECIFIC named subject of the photo: a building, bridge, monument, park, plaza, or natural landmark (e.g. \"Brooklyn Bridge\", \"Sagrada Família\", \"Half Dome\"). NOT a city or neighborhood — those go in `location`. Null if no specific subject can be confidently named."],
                    "architect": ["type": ["string", "null"], "description": "Architect name. Null if unknown."],
                    "year": ["type": ["integer", "null"], "description": "Year built (or completion year). Null if unknown."],
                    "style": ["type": ["string", "null"], "description": "Architectural style. Null if not applicable."],
                    "location": ["type": "string", "description": "REQUIRED. The SURROUNDING area at neighborhood/district granularity + city + country, formatted \"Neighborhood, City, Country\" (e.g. \"DUMBO, Brooklyn, NY, USA\", \"Eixample, Barcelona, Spain\"). MUST be different from building_name — if building_name is \"Brooklyn Bridge\", location is \"DUMBO, Brooklyn, NY, USA\", NOT \"Brooklyn, NYC\". Never just a country."],
                    "one_sentence": ["type": "string", "description": "REQUIRED. Single neutral sentence under 25 words describing the place/scene."],
                    "confidence": ["type": "string", "enum": ["high", "medium", "low"], "description": "Self-rated confidence in building_name."]
                ],
                "required": ["location", "one_sentence", "confidence"]
            ]
        ))

        return tools
    }

    // MARK: - Tool execution

    private static func runMapKitSearch(_ args: AnyJSON?, defaultGPS: (lat: Double, lon: Double)?) async -> String {
        struct Args: Decodable {
            var query: String
            var latitude: Double?
            var longitude: Double?
            var radius_meters: Double?
        }
        guard let parsed = args?.decode(Args.self) else {
            return "{\"error\":\"could not parse mapkit_search args\"}"
        }
        let lat = parsed.latitude ?? defaultGPS?.lat
        let lon = parsed.longitude ?? defaultGPS?.lon
        let radius = parsed.radius_meters ?? 800

        let pois = await mapkitSearch(query: parsed.query,
                                       at: lat.flatMap { la in lon.map { lo in (la, lo) } },
                                       radius: radius)

        // Encode result as JSON the model can parse.
        let payload: [String: Any] = [
            "query": parsed.query,
            "results": pois.prefix(8).map { poi -> [String: Any] in
                var dict: [String: Any] = ["name": poi.name]
                if let cat = poi.category { dict["category"] = cat }
                if let dist = poi.distanceMeters { dict["distance_meters"] = Int(dist) }
                if let addr = poi.address { dict["address"] = addr }
                return dict
            }
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        log.info("agent tool mapkit_search query=\(parsed.query, privacy: .public) results=\(pois.count, privacy: .public)")
        return json
    }

    private static func runWebSearch(_ args: AnyJSON?) async -> String {
        struct Args: Decodable { var query: String }
        guard let parsed = args?.decode(Args.self) else {
            return "{\"error\":\"could not parse web_search args\"}"
        }
        // Delegate to Ollama's hosted web search via a single-message chat
        // call with `tools: [web_search]`. The model should return search
        // results in its content. Simpler than implementing a separate
        // search endpoint.
        do {
            // Use the generate API with web_search tool — same as the legacy path.
            let url = try OllamaService.shared.baseURLForExternal().appending(path: "/api/generate")
            let body: [String: Any] = [
                "model": OllamaService.shared.modelForExternal(),
                "prompt": "Search the web for: \(parsed.query). Return a brief factual summary.",
                "stream": false,
                "tools": [["type": "web_search"]],
                "options": ["temperature": 0.1]
            ]
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let auth = OllamaService.shared.authorizationHeaderForExternal() {
                req.setValue(auth, forHTTPHeaderField: "Authorization")
            }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 45
            let (data, _) = try await URLSession(configuration: cfg).data(for: req)
            struct R: Decodable { let response: String }
            let r = try JSONDecoder().decode(R.self, from: data)
            log.info("agent tool web_search query=\(parsed.query, privacy: .public)")
            return "{\"summary\": \(jsonString(r.response))}"
        } catch {
            log.error("agent tool web_search failed: \(error.localizedDescription, privacy: .public)")
            return "{\"error\":\"web_search failed: \(error.localizedDescription)\"}"
        }
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let trimmed = String(data: data, encoding: .utf8) ?? "\"\""
        return String(trimmed.dropFirst().dropLast())
    }

    private static func toolResultMessage(name: String, json: String) -> OllamaChatMessage {
        OllamaChatMessage(role: "tool", content: json, images: nil, tool_calls: nil, tool_name: name)
    }

    // MARK: - Commit decoding

    private struct CommitArgs: Decodable {
        var building_name: String?
        var architect: String?
        var year: Int?
        var style: String?
        var location: String?
        var one_sentence: String?
        var confidence: String?
    }

    private static func decodeCommit(_ args: AnyJSON?) -> Confirmed? {
        guard let parsed = args?.decode(CommitArgs.self) else { return nil }
        return makeConfirmed(parsed)
    }

    /// Fallback: small models sometimes ignore tools and emit JSON in the
    /// `content` field. Try to find a JSON object and decode commit args.
    private static func decodeCommitFromText(_ text: String) -> Confirmed? {
        guard let jsonRange = text.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) else {
            return nil
        }
        let jsonString = String(text[jsonRange])
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(CommitArgs.self, from: data) else {
            return nil
        }
        return makeConfirmed(parsed)
    }

    private static func makeConfirmed(_ args: CommitArgs) -> Confirmed? {
        let trimmed: (String?) -> String? = { s in
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        let oneSentence = trimmed(args.one_sentence)
        var bldg = trimmed(args.building_name)
        let location = trimmed(args.location)
        // Defensive: even with the schema saying "building_name and location
        // must differ," small models occasionally return the same string in
        // both — or stuff a city name into building_name. Reject any bldg
        // that's a prefix-equal/contained-in match against location, since
        // that's a tell that the model fell back to "this is just a place,
        // not a specific subject." Drops bldg → nil → bestPlaceTitle falls
        // back to location, no double-printing in the UI.
        if let b = bldg, let l = location {
            let bLow = b.lowercased()
            let lLow = l.lowercased()
            if bLow == lLow || lLow.hasPrefix(bLow) || bLow.hasPrefix(lLow.split(separator: ",").first.map(String.init)?.lowercased() ?? "") {
                log.info("agent: dropping building_name=\(b, privacy: .public) (overlaps location=\(l, privacy: .public))")
                bldg = nil
            }
        }
        let conf = (args.confidence ?? "low").lowercased()
        let isHighOrMedium = conf == "high" || conf == "medium"

        // High/medium with name → full building enrichment.
        if isHighOrMedium, let name = bldg {
            return Confirmed(
                name: name,
                architect: trimmed(args.architect),
                year: args.year,
                style: trimmed(args.style),
                oneSentence: oneSentence,
                location: location
            )
        }
        // Otherwise keep the sentence (always required) and use building name
        // if provided, else fall back to whatever description we have.
        if let oneSentence {
            return Confirmed(
                name: bldg ?? "—",
                architect: nil,
                year: nil,
                style: nil,
                oneSentence: oneSentence,
                location: location
            )
        }
        return nil
    }

    // MARK: - MapKit

    private static func mapkitSearch(query: String, at gps: (lat: Double, lon: Double)?, radius: Double) async -> [NearbyPOI] {
        #if canImport(MapKit) && os(macOS)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let gps {
            let center = CLLocationCoordinate2D(latitude: gps.lat, longitude: gps.lon)
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: radius, longitudinalMeters: radius)
            request.resultTypes = .pointOfInterest
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            let here: CLLocation? = gps.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
            return response.mapItems.prefix(10).compactMap { item -> NearbyPOI? in
                guard let name = item.name else { return nil }
                let dist = here?.distance(from: item.location)
                let address = item.address?.shortAddress ?? item.address?.fullAddress
                return NearbyPOI(name: name,
                                 category: item.pointOfInterestCategory?.rawValue,
                                 distanceMeters: dist,
                                 address: address)
            }
        } catch {
            return []
        }
        #else
        return []
        #endif
    }
}

