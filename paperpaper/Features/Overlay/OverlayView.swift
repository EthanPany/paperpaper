import SwiftUI

struct OverlayView: View {
    @State private var enabled: Bool = false
    @State private var corner: OverlayCorner = .bottomRight
    @State private var margin: Double = 48
    @State private var fontSize: Double = 18

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Text") {
                    Toggle("Burn in text on wallpaper", isOn: $enabled)
                    Picker("Corner", selection: $corner) {
                        Text("Top left").tag(OverlayCorner.topLeft)
                        Text("Top right").tag(OverlayCorner.topRight)
                        Text("Bottom left").tag(OverlayCorner.bottomLeft)
                        Text("Bottom right").tag(OverlayCorner.bottomRight)
                    }
                    HStack {
                        Text("Margin")
                        Slider(value: $margin, in: 0...200)
                        Text("\(Int(margin)) px")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                    HStack {
                        Text("Size")
                        Slider(value: $fontSize, in: 8...72)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 360)

            Divider()

            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .overlay {
                    ContentUnavailableView(
                        "Preview will appear here",
                        systemImage: "textformat",
                        description: Text("Composited at 120ms debounce.")
                    )
                }
                .padding()
        }
    }
}

enum OverlayCorner: Hashable {
    case topLeft, topRight, bottomLeft, bottomRight
}

#Preview {
    OverlayView()
        .frame(width: 900, height: 600)
}
