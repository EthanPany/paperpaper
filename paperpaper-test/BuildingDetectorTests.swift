import Testing
@testable import paperpaper

struct BuildingDetectorTests {
    @Test func detectsKnownLandmarkFromDescription() {
        let out = BuildingDetector.detect(
            description: "An evening shot of the Sagrada Familia in Barcelona.",
            altDescription: nil,
            tags: ["architecture", "barcelona"],
            locationName: "Barcelona"
        )
        #expect(out?.name.contains("Sagrada") == true)
    }

    @Test func ignoresGenericTerms() {
        let out = BuildingDetector.detect(
            description: "Modern architecture.",
            altDescription: "tall building",
            tags: ["architecture", "building", "urban", "modern"],
            locationName: nil
        )
        #expect(out == nil)
    }

    @Test func findsCapitalizedMultiWordPhrase() {
        let out = BuildingDetector.detect(
            description: "A view of the Marina Bay Sands rising above the skyline.",
            altDescription: nil,
            tags: ["architecture", "skyline"],
            locationName: nil
        )
        #expect(out?.name == "Marina Bay Sands")
    }

    @Test func prefersKnownLandmarkOverPhrase() {
        let out = BuildingDetector.detect(
            description: "Shot of the Empire State Building at dusk.",
            altDescription: nil,
            tags: ["architecture"],
            locationName: "New York"
        )
        #expect(out?.name == "Empire State Building")
    }

    @Test func singleCapitalizedWordIsNotEnough() {
        let out = BuildingDetector.detect(
            description: "Barcelona shot.",
            altDescription: nil,
            tags: [],
            locationName: nil
        )
        #expect(out == nil)
    }

    @Test func tagExactMatchOnKnownLandmark() {
        let out = BuildingDetector.detect(
            description: nil,
            altDescription: nil,
            tags: ["Fallingwater", "architecture"],
            locationName: nil
        )
        #expect(out?.name == "Fallingwater")
    }

    @Test func stoplistIsCaseInsensitive() {
        #expect(BuildingDetector.isGeneric("ARCHITECTURE"))
        #expect(BuildingDetector.isGeneric("Building"))
        #expect(!BuildingDetector.isGeneric("Pantheon"))
    }
}
