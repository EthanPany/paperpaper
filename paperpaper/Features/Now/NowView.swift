import SwiftUI
import SwiftData

struct NowView: View {
    @Query(sort: \Photo.lastSeenAt, order: .reverse) private var seenPhotos: [Photo]
    @State private var engine = RotationEngine.shared

    private var current: Photo? {
        seenPhotos.first(where: { $0.lastSeenAt != nil })
    }

    var body: some View {
        ZStack {
            background
            if let photo = current {
                VStack {
                    Spacer()
                    HStack {
                        PhotoMetadataCard(photo: photo)
                            .padding(24)
                        Spacer(minLength: 80)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await engine.rotateNow() }
                } label: {
                    Image(systemName: "forward.end")
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
                    Image(systemName: "gearshape")
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
                    VStack(spacing: 16) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 52, weight: .ultraLight))
                            .foregroundStyle(.white.opacity(0.8))
                        VStack(spacing: 4) {
                            Text("No wallpaper yet")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.white)
                            Text("Add your Unsplash Access Key in Settings → Connections,\nthen pick a photo in Discover.")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                        }
                        SettingsLink {
                            Label("Open Settings", systemImage: "gearshape")
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .padding(.top, 8)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 2)
                }
        }
    }
}

private struct PhotoMetadataCard: View {
    let photo: Photo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(Color(white: 0.96))
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.85))
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .lineLimit(1)
                }
            }

            if let blurb = photo.enrichment?.oneSentence, !blurb.isEmpty {
                Text(blurb)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    .lineLimit(3)
                    .frame(maxWidth: 520, alignment: .leading)
            }

            if let metaLine, !metaLine.isEmpty {
                Text(metaLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Label(photo.authorName.isEmpty ? "Unknown" : photo.authorName, systemImage: "camera")
                if let url = photo.authorProfileURL {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .glassEffect(.regular.tint(.black.opacity(0.12)), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 6)
    }

    private var title: String {
        if let name = photo.enrichment?.buildingName, !name.isEmpty { return name }
        if let desc = photo.photoDescription, !desc.isEmpty { return desc }
        if !photo.areaText.isEmpty { return photo.areaText }
        return "Untitled"
    }

    private var subtitle: String {
        let parts = [photo.enrichment?.architect, photo.areaText.isEmpty ? nil : photo.areaText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private var metaLine: String? {
        guard let exif = photo.exif else { return nil }
        var bits: [String] = []
        if !exif.cameraLine.isEmpty { bits.append(exif.cameraLine) }
        if !exif.shotLine.isEmpty { bits.append(exif.shotLine) }
        let line = bits.joined(separator: "  ·  ")
        return line.isEmpty ? nil : line
    }
}

struct PlaceholderGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.07, blue: 0.12),
                Color(red: 0.14, green: 0.16, blue: 0.22),
                Color(red: 0.30, green: 0.22, blue: 0.18),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview {
    NowView()
        .modelContainer(Store.shared.container)
        .frame(width: 1100, height: 720)
}
