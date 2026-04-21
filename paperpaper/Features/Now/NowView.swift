import SwiftUI

struct NowView: View {
    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .overlay {
                    ContentUnavailableView(
                        "No wallpaper yet",
                        systemImage: "photo",
                        description: Text("Set up your Unsplash key in Connections, then start rotation.")
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("—")
                        .font(.headline)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Area")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("—")
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Photographer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("—")
                }
                Spacer()
            }
            .padding(.horizontal)

            HStack {
                Button("Next") {}
                Button("Keep") {}
                Button("Favorite") {}
                Button("Download") {}
                Spacer()
                Button("Open on Unsplash") {}
            }
            .padding([.horizontal, .bottom])
        }
    }
}

#Preview {
    NowView()
        .frame(width: 900, height: 600)
}
