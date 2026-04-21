import SwiftUI

struct DiscoverView: View {
    @State private var query: String = "architecture"
    @State private var results: [UnsplashPhoto] = []
    @State private var isLoading: Bool = false
    @State private var error: String?
    @State private var selected: UnsplashPhoto?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Search Unsplash", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(query.isEmpty)
                Button("Shuffle Architecture") { Task { await shuffle() } }
            }
            .padding()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if isLoading && results.isEmpty {
                ContentUnavailableView {
                    Label("Searching Unsplash…", systemImage: "sparkles")
                } description: {
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView(
                    "Try a search",
                    systemImage: "magnifyingglass",
                    description: Text("Results from Unsplash will appear here. Set your key in Connections first.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(results) { photo in
                            DiscoverTile(photo: photo) {
                                selected = photo
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $selected) { photo in
            DiscoverDetail(photo: photo)
                .frame(minWidth: 600, minHeight: 500)
        }
    }

    private func search() async {
        isLoading = true
        error = nil
        do {
            let result = try await UnsplashService.shared.search(query: query, page: 1, perPage: 24)
            results = result.results
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            results = []
        }
        isLoading = false
    }

    private func shuffle() async {
        isLoading = true
        error = nil
        do {
            results = try await UnsplashService.shared.randomArchitecture(count: 24)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            results = []
        }
        isLoading = false
    }
}

private struct DiscoverTile: View {
    let photo: UnsplashPhoto
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: photo.urls.small) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        Color.gray.opacity(0.2)
                    case .empty:
                        Color.gray.opacity(0.1)
                            .overlay(ProgressView())
                    @unknown default:
                        Color.gray.opacity(0.1)
                    }
                }
                .aspectRatio(CGFloat(photo.width) / CGFloat(photo.height), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(photo.description ?? photo.alt_description ?? "Untitled")
                    .font(.subheadline)
                    .lineLimit(1)
                Text(photo.user.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DiscoverDetail: View {
    let photo: UnsplashPhoto
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(photo.description ?? photo.alt_description ?? "Photo")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()

            AsyncImage(url: photo.urls.regular) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: Color.gray.opacity(0.2)
                }
            }
            .frame(maxHeight: 360)
            .padding(.horizontal)

            Form {
                Section("Photo") {
                    LabeledContent("ID", value: photo.id)
                    LabeledContent("Size", value: "\(photo.width) × \(photo.height)")
                    if let color = photo.color {
                        LabeledContent("Color", value: color)
                    }
                }
                Section("Photographer") {
                    LabeledContent("Name", value: photo.user.name)
                    if let url = photo.user.links?.html {
                        Link(destination: url) { Text("Open on Unsplash") }
                    }
                }
                if let location = photo.location {
                    Section("Location") {
                        if let name = location.name { LabeledContent("Name", value: name) }
                        if let city = location.city { LabeledContent("City", value: city) }
                        if let country = location.country { LabeledContent("Country", value: country) }
                        if let lat = location.position?.latitude, let lon = location.position?.longitude {
                            LabeledContent("GPS", value: String(format: "%.4f, %.4f", lat, lon))
                        }
                    }
                }
                if let tags = photo.tags, !tags.isEmpty {
                    Section("Tags") {
                        Text(tags.prefix(20).map(\.title).joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                if let exif = photo.exif {
                    Section("EXIF (from Unsplash)") {
                        if let m = exif.make { LabeledContent("Make", value: m) }
                        if let m = exif.model { LabeledContent("Model", value: m) }
                        if let f = exif.focal_length { LabeledContent("Focal length", value: "\(f)mm") }
                        if let a = exif.aperture { LabeledContent("Aperture", value: "f/\(a)") }
                        if let s = exif.exposure_time { LabeledContent("Shutter", value: "\(s)s") }
                        if let iso = exif.iso { LabeledContent("ISO", value: "\(iso)") }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

#Preview {
    DiscoverView()
        .frame(width: 900, height: 600)
}
