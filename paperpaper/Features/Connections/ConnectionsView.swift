import SwiftUI

struct ConnectionsView: View {
    @State private var unsplashKey: String = ""
    @State private var ollamaURL: String = "http://localhost:11434"
    @State private var ollamaModel: String = "llama3.2"
    @State private var ollamaAuth: String = ""
    @State private var ollamaWebSearch: Bool = false
    @State private var ollamaTemperature: Double = 0.3
    @State private var ollamaTimeoutSeconds: Double = 30

    var body: some View {
        Form {
            Section("Unsplash") {
                SecureField("API key", text: $unsplashKey)
                Button("Test") {}
                Text("Free developer keys are fine. Paste the Access Key, not the Secret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ollama") {
                TextField("Host URL", text: $ollamaURL)
                TextField("Model", text: $ollamaModel)
                SecureField("Auth header (optional)", text: $ollamaAuth)
                Toggle("Use web search tool (if available)", isOn: $ollamaWebSearch)
                HStack {
                    Text("Temperature")
                    Slider(value: $ollamaTemperature, in: 0...1, step: 0.05)
                    Text(String(format: "%.2f", ollamaTemperature))
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Text("Timeout")
                    Slider(value: $ollamaTimeoutSeconds, in: 5...120, step: 1)
                    Text("\(Int(ollamaTimeoutSeconds)) s")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                Button("Test") {}
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    ConnectionsView()
        .frame(width: 900, height: 600)
}
