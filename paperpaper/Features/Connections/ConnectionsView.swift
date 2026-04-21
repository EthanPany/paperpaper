import SwiftUI

struct ConnectionsView: View {
    @State private var unsplashKey: String = ""
    @State private var ollamaURL: String = "http://localhost:11434"
    @State private var ollamaModel: String = "llama3.2"
    @State private var ollamaAuth: String = ""
    @State private var ollamaWebSearch: Bool = false
    @State private var ollamaTemperature: Double = 0.3
    @State private var ollamaTimeoutSeconds: Double = 30

    @State private var unsplashStatus: TestStatus = .idle
    @State private var unsplashMessage: String?

    var body: some View {
        Form {
            Section("Unsplash") {
                SecureField("Access Key", text: $unsplashKey)
                HStack {
                    Button("Save") { saveUnsplash() }
                    Button("Test") {
                        Task { await testUnsplash() }
                    }
                    .disabled(unsplashKey.isEmpty)
                    StatusChip(status: unsplashStatus)
                    if let msg = unsplashMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text("Paste your Unsplash Access Key (not the Secret). Free developer keys work.")
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
                Button("Save") { saveOllamaAuth() }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadFromKeychain)
    }

    private func loadFromKeychain() {
        unsplashKey = KeychainService.shared.get(.unsplashAccessKey) ?? ""
        ollamaAuth = KeychainService.shared.get(.ollamaAuthHeader) ?? ""
    }

    private func saveUnsplash() {
        if unsplashKey.isEmpty {
            KeychainService.shared.delete(.unsplashAccessKey)
        } else {
            KeychainService.shared.set(unsplashKey, for: .unsplashAccessKey)
        }
    }

    private func saveOllamaAuth() {
        if ollamaAuth.isEmpty {
            KeychainService.shared.delete(.ollamaAuthHeader)
        } else {
            KeychainService.shared.set(ollamaAuth, for: .ollamaAuthHeader)
        }
    }

    private func testUnsplash() async {
        saveUnsplash()
        unsplashStatus = .testing
        unsplashMessage = nil
        do {
            let result = try await UnsplashService.shared.search(query: "architecture", page: 1, perPage: 1)
            unsplashStatus = .ok
            unsplashMessage = "OK (\(result.total) photos match 'architecture')"
        } catch {
            unsplashStatus = .failed
            unsplashMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

enum TestStatus {
    case idle, testing, ok, failed
}

private struct StatusChip: View {
    let status: TestStatus

    var body: some View {
        Group {
            switch status {
            case .idle: Color.clear.frame(width: 0, height: 0)
            case .testing:
                ProgressView().controlSize(.small)
            case .ok:
                Label("OK", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
            case .failed:
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .labelStyle(.iconOnly)
            }
        }
    }
}

#Preview {
    ConnectionsView()
        .frame(width: 900, height: 600)
}
