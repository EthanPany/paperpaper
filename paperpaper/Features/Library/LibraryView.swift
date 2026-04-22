import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \Photo.firstSeenAt, order: .reverse) private var photos: [Photo]
    @State private var showFavoritesOnly: Bool = false

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
                        PhotoTile(photo: photo)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
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

#Preview {
    LibraryView()
        .modelContainer(Store.shared.container)
        .frame(width: 900, height: 600)
}
