import SwiftUI

struct CacheView: View {
    @State private var maxSizeMB: Double = 500
    @State private var prefetchCount: Double = 3
    @State private var keepOnlyReferences: Bool = true

    var body: some View {
        Form {
            Section("Storage") {
                HStack {
                    Text("Max size")
                    Slider(value: $maxSizeMB, in: 50...5000, step: 50)
                    Text("\(Int(maxSizeMB)) MB")
                        .monospacedDigit()
                        .frame(width: 90, alignment: .trailing)
                }
                HStack {
                    Text("Pre-fetch next")
                    Slider(value: $prefetchCount, in: 0...10, step: 1)
                    Text("\(Int(prefetchCount))")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle("Keep only references after rotation", isOn: $keepOnlyReferences)
            }

            Section("Stats") {
                LabeledContent("Current size", value: "0 MB")
                LabeledContent("Images cached", value: "0")
                LabeledContent("Hit rate", value: "—")
            }

            Section {
                Button("Clear image cache", role: .destructive) {}
                Button("Clear enrichment cache", role: .destructive) {}
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    CacheView()
        .frame(width: 900, height: 600)
}
