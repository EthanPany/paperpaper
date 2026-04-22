import SwiftUI

struct ExifLayout: View {
    let payload: WidgetPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Spacer(minLength: 0)

            Text(payload.buildingName ?? payload.area.nilIfEmpty ?? "paperpaper")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            if let camera = payload.cameraLine, !camera.isEmpty {
                Label(camera, systemImage: "camera")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            if let lens = payload.lensLine, !lens.isEmpty {
                Label(lens, systemImage: "viewfinder")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            if let shot = payload.shotLine, !shot.isEmpty {
                Label(shot, systemImage: "dial.high")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }

            if let lat = payload.latitude, let lon = payload.longitude {
                Label(String(format: "%.3f, %.3f", lat, lon), systemImage: "mappin.and.ellipse")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 1)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
