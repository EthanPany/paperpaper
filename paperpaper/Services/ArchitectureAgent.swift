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
        /// 1-sentence intro. Kept under `oneSentence` so existing call sites
        /// (widget payload, NowView card) keep reading what they always read.
        var oneSentence: String?
        /// 2–3 sentence intro for medium widgets / NowView main caption.
        var blurbMedium: String?
        /// 3–5 sentence essay for systemLarge widget / detail panes.
        var blurbLong: String?
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
                content: "Now call the `commit_enrichment` tool with your final answer. Remember: blurb_short (1 sentence), blurb_medium (2–3 sentences), and blurb_long (3–5 sentences) are ALL required. If you can't identify a specific building, set building_name=null and confidence=\"low\" — but still produce all three blurbs describing the place or scene. Do NOT invent architects or years; use null when uncertain.",
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
        calling `commit_enrichment` with your conclusion.

        Tools:
          • mapkit_search(query, latitude?, longitude?, radius_meters?) — Apple Maps POI search.
          • web_search(query) — open-web search (use ONLY when present in the tools list).
          • commit_enrichment(...) — REQUIRED terminal call. Schema below.

        ============================================================
        HARD RULES — read carefully, violations make the output unusable.
        ============================================================

        1) NO HALLUCINATION.
           If you don't *know* a fact, set the field to null. Do NOT guess an architect
           because the building looks "famous-ish." Do NOT guess a year. Famous buildings
           that you confidently recognize are fine; everything else → null.
             • Wrong: "this looks like a 1970s skyscraper" → year: 1973
             • Right: → year: null

        2) building_name VS location ARE DIFFERENT THINGS.
           • building_name = the SPECIFIC subject the viewer is looking at
             ("Brooklyn Bridge", "Sagrada Família", "Half Dome").
             null if no specific subject exists.
           • location = surrounding geographic context, "Anchor, City, Country"
             ("DUMBO, Brooklyn, NY, USA", "Eixample, Barcelona, Spain").
             They MUST be different strings. Never put a city in building_name.

        3) location IS REQUIRED and must reach district granularity when possible.
           Use mapkit_search if the EXIF area is too vague (e.g. just "Spain").
           Last resort fallback: "City, Country". Never just a country alone.

        4) THREE BLURBS, EACH A DIFFERENT LENGTH. All three are required.
           • blurb_short  — exactly 1 sentence, ≤ 18 words. Single neutral
             description. Used in the smallest widget.
           • blurb_medium — 2 to 3 sentences, ≤ 55 words. Reads like a
             magazine caption: subject, era / architect / style, one
             distinguishing detail. If you don't know the architect / year,
             write the medium blurb without naming them — describe what's
             actually visible (materials, height, setting, time of day).
           • blurb_long   — 3 to 5 sentences, ≤ 130 words. Mini-introduction:
             when (only if known), who designed it (only if known), the
             architectural style and a defining feature, optionally one
             notable historical event, and what it is used for today.
             Skip clauses you don't know — DO NOT pad with invented facts.

        5) Tool use: at most 2 lookups before committing. Don't loop.

        ============================================================
        FEW-SHOT EXAMPLES (for the commit_enrichment payload)
        ============================================================

        Example A — famous, fully known landmark:
        {
          "building_name": "Empire State Building",
          "architect": "Shreve, Lamb & Harmon",
          "year": 1931,
          "style": "Art Deco",
          "location": "Midtown Manhattan, New York, NY, USA",
          "blurb_short": "The Empire State Building rises 102 stories above Midtown Manhattan.",
          "blurb_medium": "Completed in 1931 by Shreve, Lamb & Harmon, the Empire State Building is a defining Art Deco skyscraper. Its limestone-and-aluminum tower was the world's tallest building for nearly forty years.",
          "blurb_long": "Completed in 1931 to designs by Shreve, Lamb & Harmon, the Empire State Building is one of the most recognizable Art Deco towers in the world. It rises 102 stories above Midtown Manhattan and held the title of world's tallest building until 1970. The setback massing, polished aluminum spandrels, and chrome-nickel detailing are textbook Art Deco. Survived a B-25 bomber strike on the 79th floor in 1945. Today it remains an office tower with public observation decks on the 86th and 102nd floors.",
          "confidence": "high"
        }

        Example B — recognizable building, architect uncertain → null instead of guessing:
        {
          "building_name": "Lloyd's of London",
          "architect": null,
          "year": null,
          "style": "High-tech",
          "location": "City of London, London, UK",
          "blurb_short": "A high-tech insurance HQ in the City of London with services exposed on its exterior.",
          "blurb_medium": "Lloyd's of London is a landmark of the High-tech architectural movement. Stainless-steel ductwork, lifts, and stairwells run up the outside of the building, leaving the interior column-free.",
          "blurb_long": "Lloyd's of London is a defining example of High-tech architecture, identified by the deliberate exposure of structure and services on the building's exterior. Stainless-steel ducts, glass lifts, and concrete stair towers climb the facade, freeing the interior into one large column-free atrium. The form is industrial-machine rather than monumental, and the building reads as a piece of equipment for the insurance market it houses. Today it remains the headquarters of the Lloyd's insurance market.",
          "confidence": "high"
        }

        Example C — generic scene, no specific subject:
        {
          "building_name": null,
          "architect": null,
          "year": null,
          "style": null,
          "location": "Alfama, Lisbon, Portugal",
          "blurb_short": "A narrow tiled street in the Alfama district of Lisbon at dusk.",
          "blurb_medium": "A residential street in Alfama, Lisbon's oldest neighborhood, photographed at dusk. Pastel-tiled facades, wrought-iron balconies, and laundry lines define the streetscape.",
          "blurb_long": "A residential street in Alfama, the oldest neighborhood of Lisbon, photographed at dusk. The facades are clad in azulejos — Portugal's signature glazed ceramic tiles — and dressed with wrought-iron balconies and lines of drying laundry. Alfama survived the 1755 earthquake that flattened most of the city, which is why its medieval street grid and Moorish-era density are still visible today. The district is residential, with cafés, fado bars, and small shops occupying the ground floors.",
          "confidence": "low"
        }

        ============================================================
        Now produce a commit for the photo the user sent.
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

        // Expose web_search whenever an Ollama API key is present. Ollama's
        // hosted web search (ollama.com account) is what backs this tool —
        // there's no local-only fallback, so the API key gate is sufficient
        // and the user shouldn't need a separate toggle.
        if let apiKey = KeychainService.shared.get(.ollamaAuthHeader), !apiKey.isEmpty {
            tools.append(OllamaToolSpec.function(
                name: "web_search",
                description: "Search the open web via Ollama's hosted search. Use to confirm architect / year / style for a candidate building before committing.",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query string."]
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
                    "architect": ["type": ["string", "null"], "description": "Architect name. Null if unknown. DO NOT GUESS — null is required when uncertain."],
                    "year": ["type": ["integer", "null"], "description": "Year built (or completion year). Null if unknown. DO NOT GUESS."],
                    "style": ["type": ["string", "null"], "description": "Architectural style. Null if not applicable or unknown."],
                    "location": ["type": "string", "description": "REQUIRED. \"Anchor, City, Country\" at neighborhood/district granularity. Different string from building_name. Never just a country."],
                    "blurb_short": ["type": "string", "description": "REQUIRED. Exactly 1 sentence, ≤ 18 words. Single neutral description used by the smallest widget."],
                    "blurb_medium": ["type": "string", "description": "REQUIRED. 2–3 sentences, ≤ 55 words. Magazine caption: subject, era/architect/style, one distinguishing detail. Skip clauses you don't know — never invent."],
                    "blurb_long": ["type": "string", "description": "REQUIRED. 3–5 sentences, ≤ 130 words. Mini-introduction: when, who designed it (only if known), style + defining feature, optionally one historical note, and current use. Omit unknowns rather than fabricating."],
                    "confidence": ["type": "string", "enum": ["high", "medium", "low"], "description": "Self-rated confidence in building_name."]
                ],
                "required": ["location", "blurb_short", "blurb_medium", "blurb_long", "confidence"]
            ]
        ))

        return tools
    }

    // MARK: - Tool execution

    private static func runMapKitSearch(_ args: AnyJSON?, defaultGPS: (lat: Double, lon: Double)?) async -> String {
        // Some models (notably qwen3-vl) return numeric tool args as JSON
        // strings ("800.0" instead of 800.0). Parse leniently.
        struct Args {
            var query: String
            var latitude: Double?
            var longitude: Double?
            var radius_meters: Double?
        }
        guard let raw = args?.raw,
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            return "{\"error\":\"could not parse mapkit_search args\"}"
        }
        func num(_ key: String) -> Double? {
            if let n = obj[key] as? Double { return n }
            if let n = obj[key] as? Int { return Double(n) }
            if let s = obj[key] as? String { return Double(s) }
            return nil
        }
        guard let q = obj["query"] as? String, !q.isEmpty else {
            return "{\"error\":\"could not parse mapkit_search args\"}"
        }
        let parsed = Args(
            query: q,
            latitude: num("latitude"),
            longitude: num("longitude"),
            radius_meters: num("radius_meters")
        )
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

    private struct CommitArgs {
        var building_name: String?
        var architect: String?
        var year: Int?
        var style: String?
        var location: String?
        var blurb_short: String?
        var blurb_medium: String?
        var blurb_long: String?
        /// Legacy field — older prompts asked for `one_sentence`. Treat as a
        /// fallback for blurb_short if the new fields are missing.
        var one_sentence: String?
        var confidence: String?
    }

    /// Lenient parse of a `commit_enrichment` arg dict. Small models routinely
    /// stringify numbers ("2013.0" instead of 2013) or wrap nullable fields in
    /// arrays / NSNull. Decoding via Codable throws on any of those and drops
    /// the whole commit — so we walk the dict by hand and coerce per field.
    private static func parseCommitArgs(_ obj: [String: Any]) -> CommitArgs {
        func str(_ key: String) -> String? {
            if let s = obj[key] as? String { return s }
            if let n = obj[key] as? NSNumber { return n.stringValue }
            return nil
        }
        func int(_ key: String) -> Int? {
            if let n = obj[key] as? Int { return n }
            if let d = obj[key] as? Double { return Int(d) }
            if let s = obj[key] as? String {
                if let i = Int(s) { return i }
                if let d = Double(s) { return Int(d) }
            }
            return nil
        }
        return CommitArgs(
            building_name: str("building_name"),
            architect: str("architect"),
            year: int("year"),
            style: str("style"),
            location: str("location"),
            blurb_short: str("blurb_short"),
            blurb_medium: str("blurb_medium"),
            blurb_long: str("blurb_long"),
            one_sentence: str("one_sentence"),
            confidence: str("confidence")
        )
    }

    private static func decodeCommit(_ args: AnyJSON?) -> Confirmed? {
        guard let raw = args?.raw,
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            return nil
        }
        return makeConfirmed(parseCommitArgs(obj))
    }

    /// Fallback: small models sometimes ignore tools and emit JSON in the
    /// `content` field. Try to find a JSON object and decode commit args.
    private static func decodeCommitFromText(_ text: String) -> Confirmed? {
        guard let jsonRange = text.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) else {
            return nil
        }
        let jsonString = String(text[jsonRange])
        guard let data = jsonString.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return makeConfirmed(parseCommitArgs(obj))
    }

    private static func makeConfirmed(_ args: CommitArgs) -> Confirmed? {
        let trimmed: (String?) -> String? = { s in
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        // blurb_short is the new "one sentence" — fall back to the legacy
        // one_sentence field if a model still emits it.
        let blurbShort = trimmed(args.blurb_short) ?? trimmed(args.one_sentence)
        let blurbMedium = trimmed(args.blurb_medium)
        let blurbLong = trimmed(args.blurb_long)
        let oneSentence = blurbShort
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
                blurbMedium: blurbMedium,
                blurbLong: blurbLong,
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
                blurbMedium: blurbMedium,
                blurbLong: blurbLong,
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

