import SwiftUI
import SwiftData

struct NowView: View {
    @Query(sort: \Photo.lastSeenAt, order: .reverse) private var seenPhotos: [Photo]
    @State private var engine = RotationEngine.shared
    @State private var applyError: String?

    private var current: Photo? {
        seenPhotos.first(where: { $0.lastSeenAt != nil })
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                metadataBar
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Label("paperpaper", systemImage: "photo.on.rectangle.angled")
                    .labelStyle(.titleAndIcon)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await engine.rotateNow() }
                } label: {
                    Label("Next", systemImage: "forward.end")
                }
                .help("Rotate now")

                if let photo = current {
                    Button {
                        Store.shared.toggleFavorite(photo)
                    } label: {
                        Image(systemName: photo.favoritedAt == nil ? "heart" : "heart.fill")
                    }
                    .help(photo.favoritedAt == nil ? "Favorite" : "Unfavorite")
                }

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open settings")
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let photo = current, let url = photo.regularURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    PlaceholderGradient()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .ignoresSafeArea()
        } else {
            PlaceholderGradient()
                .ignoresSafeArea()
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("No wallpaper yet")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white)
                        Text("Add your Unsplash Access Key in Settings → Connections, then pick a photo in Discover.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        SettingsLink {
                            Label("Open Settings", systemImage: "gearshape")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.accentColor)
                        .controlSize(.large)
                        .padding(.top, 8)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 1)
                }
        }
    }

    @ViewBuilder
    private var metadataBar: some View {
        if let photo = current {
            MetadataBar(photo: photo, applyError: $applyError)
        }
    }
}

private struct MetadataBar: View {
    let photo: Photo
    @Binding var applyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let architect = photo.enrichment?.architect, !architect.isEmpty {
                    Text(architect)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer()
            }

            if let blurb = photo.enrichment?.oneSentence, !blurb.isEmpty {
                Text(blurb)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }

            HStack(spacing: 14) {
                if !photo.areaText.isEmpty {
                    Label(photo.areaText, systemImage: "location")
                }
                if !photo.authorName.isEmpty {
                    Label(photo.authorName, systemImage: "camera")
                }
                if let exif = photo.exif, !exif.shotLine.isEmpty {
                    Label(exif.shotLine, systemImage: "dial.high")
                }
                if let url = photo.authorProfileURL {
                    Link(destination: url) {
                        Label("On Unsplash", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .labelStyle(.titleAndIcon)

            if let err = applyError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.red.opacity(0.7), in: Capsule())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 1)
    }

    private var title: String {
        if let name = photo.enrichment?.buildingName, !name.isEmpty { return name }
        if let desc = photo.photoDescription, !desc.isEmpty { return desc }
        if !photo.areaText.isEmpty { return photo.areaText }
        return "Untitled"
    }
}

struct PlaceholderGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.12, blue: 0.20),
                Color(red: 0.16, green: 0.19, blue: 0.28),
                Color(red: 0.32, green: 0.25, blue: 0.20),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview {
    NowView()
        .modelContainer(Store.shared.container)
        .frame(width: 960, height: 640)
}
