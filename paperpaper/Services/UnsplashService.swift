import Foundation

struct UnsplashPhoto: Decodable, Sendable, Identifiable {
    let id: String
    let description: String?
    let alt_description: String?
    let width: Int
    let height: Int
    let color: String?
    let likes: Int?
    let urls: URLs
    let user: User
    let location: Location?
    let tags: [Tag]?
    let exif: Exif?
    /// Unsplash returns `links.download_location` for every photo. Per the
    /// Unsplash API guidelines this URL must be hit (with the access key) any
    /// time we "trigger a download" — applying as a wallpaper counts. We use
    /// it from `UnsplashService.trackDownload`.
    let links: PhotoLinks?

    struct PhotoLinks: Decodable, Sendable {
        let html: URL?
        let download: URL?
        let download_location: URL?
    }

    struct URLs: Decodable, Sendable {
        let raw: URL
        let full: URL
        let regular: URL
        let small: URL
        let thumb: URL
    }

    struct User: Decodable, Sendable {
        let name: String
        let username: String
        let links: Links?

        struct Links: Decodable, Sendable {
            let html: URL?
        }
    }

    struct Location: Decodable, Sendable {
        let name: String?
        let city: String?
        let country: String?
        let position: Position?

        struct Position: Decodable, Sendable {
            let latitude: Double?
            let longitude: Double?
        }
    }

    struct Tag: Decodable, Sendable {
        let title: String
    }

    struct Exif: Decodable, Sendable {
        let make: String?
        let model: String?
        let name: String?
        let exposure_time: String?
        let aperture: String?
        let focal_length: String?
        let iso: Int?
    }
}

struct UnsplashSearchResult: Decodable, Sendable {
    let total: Int
    let total_pages: Int
    let results: [UnsplashPhoto]
}

enum UnsplashError: Error, LocalizedError {
    case missingAccessKey
    case http(status: Int, body: String)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .missingAccessKey: return "Add your Unsplash Access Key in Connections."
        case .http(let status, _): return "Unsplash returned HTTP \(status)."
        case .decoding(let error): return "Could not read Unsplash response: \(error.localizedDescription)"
        case .transport(let error): return "Network error: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class UnsplashService {
    static let shared = UnsplashService()

    private let base = URL(string: "https://api.unsplash.com")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, page: Int = 1, perPage: Int = 20, orientation: Orientation = .landscape) async throws -> UnsplashSearchResult {
        var comps = URLComponents(url: base.appending(path: "/search/photos"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "orientation", value: orientation.rawValue),
            URLQueryItem(name: "content_filter", value: "high"),
        ]
        return try await get(comps.url!)
    }

    func photo(id: String) async throws -> UnsplashPhoto {
        try await get(base.appending(path: "/photos/\(id)"))
    }

    func randomArchitecture(count: Int = 1) async throws -> [UnsplashPhoto] {
        try await random(query: "architecture", count: count)
    }

    func random(query: String, count: Int = 1) async throws -> [UnsplashPhoto] {
        var comps = URLComponents(url: base.appending(path: "/photos/random"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "orientation", value: "landscape"),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "content_filter", value: "high"),
        ]
        return try await get(comps.url!)
    }

    /// Tells Unsplash that a photo was "downloaded" (in our case: applied as
    /// wallpaper). Required by the Unsplash API guidelines whenever the user
    /// triggers a download — without it, our app key gets rate-limited and
    /// can be revoked. The endpoint is the value of `photo.links.download_location`
    /// and must be called with our standard auth header. We don't care about
    /// the response body; failure is logged but swallowed so a transient
    /// network blip never blocks a wallpaper apply.
    func trackDownload(_ photo: UnsplashPhoto) async {
        guard let location = photo.links?.download_location else { return }
        guard let key = KeychainService.shared.get(.unsplashAccessKey), !key.isEmpty else { return }
        var req = URLRequest(url: location)
        req.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("v1", forHTTPHeaderField: "Accept-Version")
        _ = try? await session.data(for: req)
    }

    func download(_ url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw UnsplashError.http(status: status, body: "")
            }
            return data
        } catch let err as UnsplashError {
            throw err
        } catch {
            throw UnsplashError.transport(error)
        }
    }

    enum Orientation: String {
        case landscape
        case portrait
        case squarish
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        guard let key = KeychainService.shared.get(.unsplashAccessKey), !key.isEmpty else {
            throw UnsplashError.missingAccessKey
        }
        var req = URLRequest(url: url)
        req.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("v1", forHTTPHeaderField: "Accept-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw UnsplashError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UnsplashError.http(status: -1, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UnsplashError.http(status: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw UnsplashError.decoding(error)
        }
    }
}

extension Photo {
    convenience init(unsplash: UnsplashPhoto) {
        self.init(
            unsplashID: unsplash.id,
            thumbURL: unsplash.urls.thumb,
            regularURL: unsplash.urls.regular,
            fullURL: unsplash.urls.full,
            rawURL: unsplash.urls.raw,
            authorName: unsplash.user.name,
            authorUsername: unsplash.user.username,
            authorProfileURL: unsplash.user.links?.html,
            photoDescription: unsplash.description,
            altDescription: unsplash.alt_description,
            tags: unsplash.tags?.map(\.title) ?? [],
            locationName: unsplash.location?.name,
            locationCity: unsplash.location?.city,
            locationCountry: unsplash.location?.country,
            width: unsplash.width,
            height: unsplash.height,
            hexColor: unsplash.color,
            likes: unsplash.likes ?? 0
        )
    }
}
