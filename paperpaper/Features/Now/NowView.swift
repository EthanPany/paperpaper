import SwiftUI
import SwiftData

struct NowView: View {
    @Query(sort: \Photo.lastSeenAt, order: .reverse) private var seenPhotos: [Photo]

    private var current: Photo? {
        seenPhotos.first(where: { $0.lastSeenAt != nil })
    }

    var body: some View {
        if let photo = current {
            CurrentPhotoView(photo: photo)
        } else {
            ContentUnavailableView(
                "No wallpaper set yet",
                systemImage: "photo",
                description: Text("Go to Discover, pick an image, and hit 'Set as wallpaper'. Make sure your Unsplash key is saved in Connections first.")
            )
        }
    }
}

private struct CurrentPhotoView: View {
    let photo: Photo
    @State private var applyError: String?

    var body: some View {
        VStack(spacing: 16) {
            AsyncImage(url: photo.regularURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .overlay(ProgressView())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding([.horizontal, .top])

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(photo.enrichment?.buildingName ?? photo.photoDescription ?? "Untitled")
                            .font(.title3.weight(.semibold))
                        if let architect = photo.enrichment?.architect {
                            Text(architect)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(action: toggleFavorite) {
                        Image(systemName: photo.favoritedAt == nil ? "heart" : "heart.fill")
                            .foregroundStyle(photo.favoritedAt == nil ? Color.secondary : Color.pink)
                    }
                    .buttonStyle(.borderless)
                    .help(photo.favoritedAt == nil ? "Favorite" : "Unfavorite")
                }

                if let blurb = photo.enrichment?.oneSentence {
                    Text(blurb)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    if !photo.areaText.isEmpty {
                        Label(photo.areaText, systemImage: "location")
                    }
                    Label(photo.authorName, systemImage: "camera")
                    if let url = photo.authorProfileURL {
                        Link(destination: url) { Text("On Unsplash").font(.caption) }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let exif = photo.exif {
                    HStack(spacing: 16) {
                        if !exif.cameraLine.isEmpty { Label(exif.cameraLine, systemImage: "camera.aperture") }
                        if !exif.lensLine.isEmpty { Label(exif.lensLine, systemImage: "viewfinder") }
                        if !exif.shotLine.isEmpty { Label(exif.shotLine, systemImage: "dial.high") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if exif.hasGPS, let lat = exif.latitude, let lon = exif.longitude {
                        Label(String(format: "GPS %.4f, %.4f", lat, lon), systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let err = applyError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding([.horizontal, .bottom])

            HStack(spacing: 8) {
                Button("Re-apply") { Task { await reapply() } }
                if let url = photo.authorProfileURL {
                    Link("Open on Unsplash", destination: url)
                }
                Spacer()
                Button("Hide", role: .destructive) {
                    Store.shared.hide(photo)
                }
            }
            .padding([.horizontal, .bottom])
        }
    }

    private func toggleFavorite() {
        Store.shared.toggleFavorite(photo)
    }

    private func reapply() async {
        applyError = nil
        do {
            _ = try await WallpaperApplier.shared.reapply(photo: photo)
        } catch {
            applyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

#Preview {
    NowView()
        .modelContainer(Store.shared.container)
        .frame(width: 900, height: 600)
}
