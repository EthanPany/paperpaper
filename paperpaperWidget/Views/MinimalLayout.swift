import SwiftUI

struct MinimalLayout: View {
    let payload: WidgetPayload

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text(payload.buildingName ?? payload.area.nilIfEmpty ?? "paperpaper")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
        }
        .padding(14)
        .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 1)
    }
}
