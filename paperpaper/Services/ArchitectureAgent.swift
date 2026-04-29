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
///        - `web_search`     → Ollama-hosted web search. Enabled whenever an
///                              Ollama API key is present in the keychain.
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
                        // Small models routinely fabricate tool names ("The
                        // Landmark Tavern") instead of calling commit_enrichment.
                        // If the args themselves contain commit-like fields,
                        // treat the call as if the model meant commit_enrichment.
                        // This pattern (tool name = building name) was the
                        // dominant failure mode on qwen3-vl:2b.
                        if let confirmed = decodeCommit(call.function.arguments) {
                            log.info("agent: rescued commit from unknown tool '\(name, privacy: .public)' — name=\(confirmed.name, privacy: .public)")
                            return confirmed
                        }
                        log.error("agent: unknown tool \(name, privacy: .public)")
                        messages.append(toolResultMessage(name: name, json: "{\"error\":\"unknown tool — call commit_enrichment instead\"}"))
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
                content: "Now call the `commit_enrichment` tool with your final answer. Required fields: location, blurb_short (1 sentence), blurb_medium (2–3 sentences), blurb_long (3–5 sentences). Optional: building_name (null if no specific subject). If you don't know an architect or year, just don't mention it in the blurb — never invent.",
                images: nil, tool_calls: nil, tool_name: nil
            ))
        }

        // Final commit-forcing pass. Drop tools entirely and ask for a JSON
        // object in the content directly — this gets us past small models
        // that are stuck in a tool-call loop without ever calling
        // commit_enrichment. We strip the multimodal turns to reduce token
        // cost and keep the system prompt + the original user prompt.
        log.info("agent: loop ended without commit, attempting forced text-JSON commit")
        let forcedPrompt = """
        STOP using tools. You have failed to commit \(maxIterations) times in a row.

        Reply with ONLY a single JSON object — no prose, no markdown fences, no
        tool calls. The object MUST contain these 5 keys exactly:

        {
          "building_name": <string or null>,
          "location": <string, REQUIRED, "Anchor, City, Country">,
          "blurb_short": <string, REQUIRED, 1 sentence ≤ 18 words>,
          "blurb_medium": <string, REQUIRED, 2–3 sentences ≤ 55 words>,
          "blurb_long": <string, REQUIRED, 3–5 sentences ≤ 130 words>
        }

        Architect / year / style do NOT have their own fields. Weave them into
        blurb_medium and blurb_long when you know them; omit when you don't —
        never invent.
        """
        messages.append(OllamaChatMessage(
            role: "user",
            content: forcedPrompt,
            images: nil, tool_calls: nil, tool_name: nil
        ))
        do {
            let final = try await OllamaService.shared.chat(messages: messages, tools: [], temperature: 0.1)
            if let confirmed = decodeCommitFromText(final.content) {
                log.info("agent: commit via forced text-JSON pass — name=\(confirmed.name, privacy: .public)")
                return confirmed
            }
            log.info("agent: forced text-JSON pass yielded no parsable commit (content=\(final.content.prefix(120), privacy: .public))")
        } catch {
            log.error("agent: forced text-JSON commit failed: \(error.localizedDescription, privacy: .public)")
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

        0) READ THE SIGNS IN THE IMAGE FIRST.
           Before anything else, scan the photo for visible text: marquees,
           banner ads, theatre signs, awnings, station boards, building
           inscriptions, neon letters, store fronts, bus destination boards,
           street-sign blades. These are the strongest possible identification
           anchors and most images that look "generic" actually contain a
           dozen of them.

           Examples of high-signal text:
             • Theatre marquees ("AMSTERDAM", "NEW VICTORY", "MADAME TUSSAUDS")
               → identify the block on 42nd Street, NYC.
             • Tube/metro station boards ("BAKER STREET", "Châtelet")
               → identify the city + neighborhood.
             • Bus destination boards ("MANHATTAN", "AÉROPORT CDG")
               → identify the city.
             • Inscribed building names on facades / cornerstones.

           When you see meaningful text:
             • Use it verbatim as your `mapkit_search` query first
               (`mapkit_search(query: "New Amsterdam Theatre")`), and/or
             • Use it as part of a `web_search` query
               (`web_search(query: "Madame Tussauds 42nd Street New York")`).
           Do NOT ignore signs and fall back to "generic city street" — that
           wastes the strongest signal in the photo.

        1) NO HALLUCINATION.
           If you don't *know* a fact, don't write it. Don't claim an architect
           or a year inside a blurb because the building looks "famous-ish."
           Drop the clause instead. A clear sign that names the venue
           ("MADAME TUSSAUDS") IS knowing the venue — that's not a guess.

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
           • blurb_medium — 2 to 3 sentences, ≤ 55 words. Reads like a magazine
             caption. When known, weave architect / year / style into the
             prose ("Designed by X in YYYY, this Art Deco tower…"). If you
             don't know those, describe what's actually visible (materials,
             height, setting, time of day) — never invent.
           • blurb_long   — 3 to 5 sentences, ≤ 130 words. Mini-introduction:
             era + designer + style as natural prose, a defining feature,
             optionally one historical note, and current use. Omit clauses
             you don't know — DO NOT pad with invented facts.

        5) Tool use: at most 2 lookups before committing. Don't loop.

        ============================================================
        FEW-SHOT EXAMPLES (commit_enrichment payload — exactly these 5 keys)
        ============================================================

        Example A — famous, fully known landmark. Architect / year / style
        appear ONLY inside the blurb prose, never as separate fields.
        {
          "building_name": "Empire State Building",
          "location": "Midtown Manhattan, New York, NY, USA",
          "blurb_short": "The Empire State Building rises 102 stories above Midtown Manhattan.",
          "blurb_medium": "Completed in 1931 by Shreve, Lamb & Harmon, the Empire State Building is a defining Art Deco skyscraper. Its limestone-and-aluminum tower was the world's tallest building for nearly forty years.",
          "blurb_long": "Completed in 1931 to designs by Shreve, Lamb & Harmon, the Empire State Building is one of the most recognizable Art Deco towers in the world. It rises 102 stories above Midtown Manhattan and held the title of world's tallest building until 1970. The setback massing, polished aluminum spandrels, and chrome-nickel detailing are textbook Art Deco. Survived a B-25 bomber strike on the 79th floor in 1945. Today it remains an office tower with public observation decks on the 86th and 102nd floors."
        }

        Example B — recognizable building, architect uncertain. Just don't
        mention the architect.
        {
          "building_name": "Lloyd's of London",
          "location": "City of London, London, UK",
          "blurb_short": "A high-tech insurance HQ in the City of London with services exposed on its exterior.",
          "blurb_medium": "Lloyd's of London is a landmark of the High-tech architectural movement. Stainless-steel ductwork, lifts, and stairwells run up the outside of the building, leaving the interior column-free.",
          "blurb_long": "Lloyd's of London is a defining example of High-tech architecture, identified by the deliberate exposure of structure and services on the building's exterior. Stainless-steel ducts, glass lifts, and concrete stair towers climb the facade, freeing the interior into one large column-free atrium. The form is industrial-machine rather than monumental, and the building reads as a piece of equipment for the insurance market it houses. Today it remains the headquarters of the Lloyd's insurance market."
        }

        Example C — generic scene, no specific subject.
        {
          "building_name": null,
          "location": "Alfama, Lisbon, Portugal",
          "blurb_short": "A narrow tiled street in the Alfama district of Lisbon at dusk.",
          "blurb_medium": "A residential street in Alfama, Lisbon's oldest neighborhood, photographed at dusk. Pastel-tiled facades, wrought-iron balconies, and laundry lines define the streetscape.",
          "blurb_long": "A residential street in Alfama, the oldest neighborhood of Lisbon, photographed at dusk. The facades are clad in azulejos — Portugal's signature glazed ceramic tiles — and dressed with wrought-iron balconies and lines of drying laundry. Alfama survived the 1755 earthquake that flattened most of the city, which is why its medieval street grid and Moorish-era density are still visible today. The district is residential, with cafés, fado bars, and small shops occupying the ground floors."
        }

        ============================================================
        Now produce a commit for the photo the user sent.
        """
    }

    private static func userPrompt(photo: Photo, area: String?, gps: (lat: Double, lon: Double)?, initialNearby: [NearbyPOI]) -> String {
        var lines: [String] = [
            "Identify the place / building in the attached photo.",
            "",
            "Step 1 — scan the image for visible text: theatre marquees, building",
            "inscriptions, station boards, bus destination signs, awnings,",
            "shopfronts, billboards. List the most distinctive 1–3 strings of",
            "text you can read. These are your strongest identification anchors.",
            "",
            "Step 2 — use those strings as queries to mapkit_search and/or",
            "web_search before guessing. Example: a sign reading \"MADAME",
            "TUSSAUDS\" + \"NEW AMSTERDAM\" is enough to pin the photo to 42nd",
            "Street, Manhattan with high confidence.",
            "",
            "Step 3 — commit_enrichment with what you've confirmed.",
            ""
        ]
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
                description: "Search the open web via Ollama's hosted search. Use to confirm a candidate building name and gather facts to weave into the blurbs.",
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
            description: "REQUIRED terminal tool. Commit your final enrichment for the photo with EXACTLY these 5 keys. Architect / year / style are NOT separate fields — weave them into blurb_medium and blurb_long when known.",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "building_name": ["type": ["string", "null"], "description": "The SPECIFIC named subject of the photo: a building, bridge, monument, park, plaza, or natural landmark. NOT a city or neighborhood — those go in `location`. Null if no specific subject can be confidently named."],
                    "location": ["type": "string", "description": "REQUIRED. \"Anchor, City, Country\" at neighborhood/district granularity. Different string from building_name. Never just a country."],
                    "blurb_short": ["type": "string", "description": "REQUIRED. Exactly 1 sentence, ≤ 18 words. Single neutral description."],
                    "blurb_medium": ["type": "string", "description": "REQUIRED. 2–3 sentences, ≤ 55 words. Weave architect/year/style into prose when known; describe what's visible when not. Never invent."],
                    "blurb_long": ["type": "string", "description": "REQUIRED. 3–5 sentences, ≤ 130 words. Era + designer + style as prose, defining feature, optionally one historical note, current use. Omit unknowns."]
                ],
                "required": ["location", "blurb_short", "blurb_medium", "blurb_long"]
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
        var location: String?
        var blurb_short: String?
        var blurb_medium: String?
        var blurb_long: String?
        /// Legacy alias — older prompts asked for `one_sentence`. Treat as a
        /// fallback for blurb_short if the new fields are missing.
        var one_sentence: String?
    }

    /// Lenient parse of a `commit_enrichment` arg dict. Small models routinely
    /// stringify numbers ("2013.0" instead of 2013), wrap nullable fields in
    /// arrays / NSNull, and (the qwen3-vl 2B model especially) invent their
    /// own field names: building_address, building_description,
    /// short_description, etc. We walk by hand and coerce per field, with
    /// alias fall-throughs so a "wrong shape but right info" commit still
    /// lands instead of flat-failing.
    private static func parseCommitArgs(_ obj: [String: Any]) -> CommitArgs {
        func str(_ keys: String...) -> String? {
            for key in keys {
                if let s = obj[key] as? String { return s }
                if let n = obj[key] as? NSNumber { return n.stringValue }
            }
            return nil
        }

        // "Unknown" / "null" / "n/a" are the model saying "I don't know" but
        // disobeying our null contract. Treat them as null so they don't get
        // surfaced verbatim in the widget.
        func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let low = t.lowercased()
            if t.isEmpty { return nil }
            if ["unknown", "n/a", "null", "none", "not applicable", "tbd"].contains(low) { return nil }
            return t
        }

        // blurb_* fall-throughs accept the most common alias names we've
        // observed the model invent (building_description, description,
        // short_description, etc).
        let descAlias = str("building_description", "description", "summary")
        let shortAlias = str("blurb_short", "short_description", "one_sentence")
            ?? descAlias.flatMap(firstSentence(of:))
        let mediumAlias = str("blurb_medium", "medium_description", "caption") ?? descAlias
        let longAlias = str("blurb_long", "long_description", "long") ?? descAlias

        // location fall-through accepts building_address as a last resort —
        // it's wrong granularity but better than nothing for "agent loop ended
        // without commit" cases.
        let location = str("location") ?? str("area") ?? str("building_address", "address")

        return CommitArgs(
            building_name: clean(str("building_name", "building")),
            location: location,
            blurb_short: shortAlias,
            blurb_medium: mediumAlias,
            blurb_long: longAlias,
            one_sentence: shortAlias
        )
    }

    /// Best-effort first-sentence extractor for synthesizing a blurb_short
    /// from a longer description.
    private static func firstSentence(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let end = trimmed.firstIndex(where: { ".!?".contains($0) }) {
            return String(trimmed[..<trimmed.index(after: end)])
        }
        return trimmed
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
        // With a name → full enrichment. Without → use the placeholder; the
        // applier's hasName check downstream will treat that as "scene only".
        if let name = bldg {
            return Confirmed(
                name: name,
                oneSentence: oneSentence,
                blurbMedium: blurbMedium,
                blurbLong: blurbLong,
                location: location
            )
        }
        if let oneSentence {
            return Confirmed(
                name: "—",
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

