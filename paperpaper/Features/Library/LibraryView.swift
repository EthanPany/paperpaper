import SwiftUI

struct LibraryView: View {
    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<0, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .aspectRatio(3.0 / 2.0, contentMode: .fit)
                }
            }
            .padding()

            if true {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "square.grid.2x2",
                    description: Text("Photos you've seen as wallpaper will show up here.")
                )
                .frame(maxWidth: .infinity, minHeight: 400)
            }
        }
    }
}

#Preview {
    LibraryView()
        .frame(width: 900, height: 600)
}
