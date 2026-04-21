import SwiftUI

struct DiscoverView: View {
    @State private var query: String = "architecture"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search Unsplash topics or tags", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Search") {}
            }
            .padding([.top, .horizontal])

            ContentUnavailableView(
                "Connect Unsplash first",
                systemImage: "key",
                description: Text("Add your API key in Connections to browse photos here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    DiscoverView()
        .frame(width: 900, height: 600)
}
