import Foundation

enum BuildingDetector {
    struct Candidate: Equatable, Sendable {
        var name: String
        var hint: String?
    }

    private static let stoplist: Set<String> = [
        "architecture", "architectural", "building", "buildings",
        "city", "cities", "cityscape", "urban", "downtown", "skyline",
        "modern", "minimal", "minimalist", "interior", "exterior",
        "design", "designed", "structure", "construction", "facade",
        "skyscraper", "highrise", "tower", "towers",
        "street", "streets", "road", "roads", "alley",
        "night", "day", "sunset", "sunrise", "morning", "evening",
        "winter", "summer", "autumn", "spring",
        "wallpaper", "background", "photo", "image", "picture",
        "abstract", "geometry", "pattern", "symmetry", "perspective",
        "black", "white", "gray", "grey", "red", "blue", "green", "yellow",
        "color", "colour", "monochrome", "gradient", "light", "shadow",
        "concrete", "glass", "steel", "brick", "stone", "wood", "metal",
        "window", "windows", "door", "doors", "roof", "roofs", "ceiling",
        "apartment", "apartments", "office", "offices", "house", "houses",
        "home", "homes", "hotel", "hotels", "store", "shop",
        "business", "commercial", "residential",
        "brutalism", "brutalist", "modernism", "modernist",
        "postmodern", "gothic", "classical", "baroque", "rococo",
        "art", "deco", "nouveau",
    ]

    private static let knownLandmarks: [String] = [
        "Sagrada Familia", "Sagrada Família",
        "Guggenheim Museum", "Guggenheim Bilbao",
        "Pantheon", "Parthenon", "Colosseum",
        "Farnsworth House", "Villa Savoye",
        "Notre Dame", "Notre-Dame",
        "Taj Mahal", "Alhambra", "Hagia Sophia", "Blue Mosque",
        "Barbican", "Trellick Tower", "Unité d'Habitation",
        "Chrysler Building", "Empire State Building", "Flatiron Building",
        "Seagram Building", "Lever House", "Salk Institute",
        "Fallingwater", "Guggenheim Museum",
        "Heydar Aliyev Center", "Walt Disney Concert Hall",
        "Sydney Opera House", "Marina Bay Sands", "Gardens by the Bay",
        "Burj Khalifa", "Burj Al Arab",
        "Habitat 67", "CN Tower",
        "Palais Garnier", "Centre Pompidou", "Louvre Pyramid",
        "Ronchamp", "Notre Dame du Haut",
        "Neuer Zollhof", "Elbphilharmonie",
        "Oriental Pearl Tower", "Shanghai Tower",
        "Petronas Towers", "Taipei 101",
        "Tokyo Tower", "Tokyo Skytree", "Kinkaku-ji", "Ginkaku-ji", "Ryoan-ji",
        "Himeji Castle", "Osaka Castle",
        "Casa Batlló", "Casa Milà", "Park Güell", "La Pedrera",
        "Winchester Mystery House",
    ]

    static func detect(description: String?, altDescription: String?, tags: [String], locationName: String?) -> Candidate? {
        let combined = [description, altDescription, locationName]
            .compactMap { $0 }
            .joined(separator: " ")

        for landmark in knownLandmarks {
            if combined.range(of: landmark, options: .caseInsensitive) != nil {
                return Candidate(name: landmark, hint: locationName)
            }
        }

        for tag in tags {
            if knownLandmarks.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                return Candidate(name: tag, hint: locationName)
            }
        }

        if let description, let phrase = firstNamedPhrase(in: description) {
            return Candidate(name: phrase, hint: locationName)
        }

        if let altDescription, let phrase = firstNamedPhrase(in: altDescription) {
            return Candidate(name: phrase, hint: locationName)
        }

        for tag in tags {
            let words = tag.split(separator: " ").map(String.init)
            if words.count >= 2,
               words.allSatisfy({ $0.first?.isUppercase == true }),
               !isGeneric(tag) {
                return Candidate(name: tag, hint: locationName)
            }
        }

        return nil
    }

    static func isGeneric(_ token: String) -> Bool {
        let normalized = token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return stoplist.contains(normalized)
    }

    static func firstNamedPhrase(in text: String) -> String? {
        let words = text
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0 == "\n" })
            .map(String.init)

        var current: [String] = []
        var best: [String] = []

        for raw in words {
            let cleaned = raw.trimmingCharacters(in: .punctuationCharacters)
            guard let first = cleaned.first else {
                if current.count > best.count { best = current }
                current = []
                continue
            }
            if first.isUppercase,
               !cleaned.allSatisfy({ $0.isUppercase }),
               !isGeneric(cleaned) {
                current.append(cleaned)
            } else {
                if current.count > best.count { best = current }
                current = []
            }
        }
        if current.count > best.count { best = current }

        guard best.count >= 2 else { return nil }
        return best.joined(separator: " ")
    }
}
