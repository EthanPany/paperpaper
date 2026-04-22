import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \Photo.firstSeenAt, order: .reverse) private var photos: [Photo]
    @State private var showFavoritesOnly: Bool = false
    @State private var selected: Photo?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

    private var visible: [Photo] {
        showFavoritesOnly ? photos.filter { $0.favoritedAt != nil } : photos
    }

    var body: some View {
        ScrollView {
            HStack {
                Toggle("Favorites only", isOn: $showFavoritesOnly)
                    .toggleStyle(.switch)
                Spacer()
                Text("\(visible.count) photo\(visible.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .padding()

            if visible.isEmpty {
                ContentUnavailableView(
                    showFavoritesOnly ? "No favorites yet" : "No history yet",
                    systemImage: "square.grid.2x2",
                    description: Text(showFavoritesOnly ? "Favorite a photo from the main window to see it here." : "Photos you've seen as wallpaper will show up here.")
                )
                .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(visible) { photo in
                        Button {
                            selected = photo
                        } label: {
                            PhotoTile(photo: photo)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .sheet(item: $selected) { photo in
            LibraryDetail(photo: photo)
        }
    }
}

private struct PhotoTile: View {
    let photo: Photo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let url = photo.regularURL ?? photo.thumbURL {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        case .failure:
                            Color.gray.opacity(0.15)
                        case .empty:
                            Color.gray.opacity(0.1).overlay(ProgressView().controlSize(.small))
                        @unknown default:
                            Color.gray.opacity(0.1)
                        }
                    }
                } else {
                    Color.gray.opacity(0.15)
                }
            }
            .aspectRatio(CGFloat(photo.aspect > 0 ? photo.aspect : 1.5), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if photo.favoritedAt != nil {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                }
            }

            Text(photo.enrichment?.buildingName ?? photo.photoDescription ?? "Untitled")
                .font(.subheadline)
                .lineLimit(1)
            Text(photo.areaText.isEmpty ? photo.authorName : photo.areaText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct LibraryDetail: View {
    let photo: Photo
    @Environment(\.dismiss) private var dismiss
    @State private var applyError: String?
    @State private var isApplying = false

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    AsyncImage(url: photo.regularURL) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFit()
                        default: Color.gray.opacity(0.1).overlay(ProgressView())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 6)
                    .padding(.horizontal, 40)
                    .padding(.top, 64)

                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(photo.enrichment?.buildingName ?? photo.photoDescription ?? "Untitled")
                                .font(.system(.largeTitle, design: .serif).weight(.medium))
                            if !photo.areaText.isEmpty {
                                Text(photo.areaText)
                                    .font(.callout)
                                    .textCase(.uppercase)
                                    .tracking(1.3)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let blurb = photo.enrichment?.oneSentence, !blurb.isEmpty {
                            Text(blurb)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        DetailRow(label: "Photographer", value: photo.authorName, link: photo.authorProfileURL)
                        if let exif = photo.exif {
                            if !exif.cameraLine.isEmpty {
                                DetailRow(label: "Camera", value: exif.cameraLine)
                            }
                            if !exif.lensLine.isEmpty {
                                DetailRow(label: "Lens", value: exif.lensLine)
                            }
                            if !exif.shotLine.isEmpty {
                                DetailRow(label: "Exposure", value: exif.shotLine, mono: true)
                            }
                            if let lat = exif.latitude, let lon = exif.longitude {
                                DetailRow(label: "GPS", value: String(format: "%.4f, %.4f", lat, lon), mono: true)
                            }
                        }
                        DetailRow(label: "Dimensions", value: "\(photo.width) × \(photo.height)", mono: true)
                        if let color = photo.hexColor {
                            DetailRow(label: "Color", value: color.uppercased(), mono: true)
                        }
                        DetailRow(label: "Unsplash ID", value: photo.unsplashID, mono: true)

                        if let err = applyError {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
                .frame(maxWidth: .infinity)
            }

            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Button {
                            Task { await setAsWallpaper() }
                        } label: {
                            Label(isApplying ? "Setting…" : "Set as wallpaper", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.accentColor)
                        .disabled(isApplying)

                        Button {
                            Store.shared.toggleFavorite(photo)
                        } label: {
                            Image(systemName: photo.favoritedAt == nil ? "heart" : "heart.fill")
                        }
                        .buttonStyle(.glass)

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(18)
                }
                Spacer()
            }
        }
        .frame(minWidth: 860, minHeight: 720)
    }

    private func setAsWallpaper() async {
        isApplying = true
        applyError = nil
        do {
            _ = try await WallpaperApplier.shared.reapply(photo: photo)
            dismiss()
        } catch {
            applyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isApplying = false
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var link: URL? = nil
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Group {
                if let link {
                    Link(destination: link) {
                        HStack(spacing: 4) {
                            Text(value)
                            Image(systemName: "arrow.up.right").font(.caption2)
                        }
                    }
                } else {
                    Text(value)
                }
            }
            .font(mono ? .system(.callout, design: .monospaced) : .callout)
            Spacer()
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(Store.shared.container)
        .frame(width: 900, height: 600)
}
