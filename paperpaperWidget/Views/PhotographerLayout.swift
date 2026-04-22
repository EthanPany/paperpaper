import SwiftUI

struct PhotographerLayout: View {
    let payload: WidgetPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Spacer(minLength: 0)

            Label(payload.authorName.isEmpty ? "Unknown photographer" : payload.authorName, systemImage: "camera")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            if !payload.area.isEmpty {
                Label(payload.area, systemImage: "location")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }

            if let name = payload.buildingName, !name.isEmpty {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }

            Text("Free to use under the Unsplash License")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .padding(12)
        .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 1)
    }
}
