import SwiftUI

struct BlurbLayout: View {
    let payload: WidgetPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)

            if let name = payload.buildingName, !name.isEmpty {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else if !payload.area.isEmpty {
                Text(payload.area)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                Text("paperpaper")
                    .font(.headline)
                    .foregroundStyle(.white)
            }

            if let architect = payload.architect, !architect.isEmpty {
                Text(architect)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }

            if let sentence = payload.oneSentence, !sentence.isEmpty {
                Text(sentence)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
            }

            if !payload.area.isEmpty, payload.buildingName != nil {
                Label(payload.area, systemImage: "location")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 1)
    }
}
