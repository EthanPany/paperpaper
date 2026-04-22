import SwiftUI

struct ConnectionsView: View {
    @State private var unsplashKey: String = ""
    @State private var ollamaAPIKey: String = ""

    @AppStorage("ollama.url") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("ollama.model") private var ollamaModel: String = "llama3.2"
    @AppStorage("ollama.webSearch") private var ollamaWebSearch: Bool = false
    @AppStorage("ollama.temperature") private var ollamaTemperature: Double = 0.3
    @AppStorage("ollama.timeoutSeconds") private var ollamaTimeoutSeconds: Double = 30

    @State private var unsplashStatus: TestStatus = .idle
    @State private var unsplashMessage: String?
    @State private var ollamaStatus: TestStatus = .idle
    @State private var ollamaMessage: String?

    @State private var availableModels: [String] = []
    @State private var modelsLoading: Bool = false
    @State private var modelsError: String?
    @State private var customModelText: String = ""

    private let customSentinel = "__custom__"

    private var isCustomModelSelected: Bool {
        !availableModels.contains(ollamaModel)
    }

    var body: some View {
        Form {
            Section("Unsplash") {
                SecureField("Access Key", text: $unsplashKey)
                HStack {
                    Button("Save") { saveUnsplash() }
                    Button("Test") { Task { await testUnsplash() } }
                        .disabled(unsplashKey.isEmpty)
                    StatusChip(status: unsplashStatus)
                    if let msg = unsplashMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Text("Paste your Unsplash Access Key (not the Secret). Free developer keys work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ollama") {
                TextField("Host URL", text: $ollamaURL)

                SecureField("API key (for Cloud / web search)", text: $ollamaAPIKey)
                Text("Stored in Keychain. Required only for ollama.com Cloud features and the web search tool. Local models don't need a key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                HStack {
                    Text(modelsLoading ? "Loading local models…" : "\(availableModels.count) local model\(availableModels.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await refreshModels() } }
                        .controlSize(.small)
                }

                if let err = modelsError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("Model", selection: Binding(
                    get: { isCustomModelSelected ? customSentinel : ollamaModel },
                    set: { newValue in
                        if newValue == customSentinel {
                            customModelText = ollamaModel
                        } else {
                            ollamaModel = newValue
                        }
                    }
                )) {
                    ForEach(availableModels, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !availableModels.isEmpty { Divider() }
                    Text("Custom…").tag(customSentinel)
                }

                if isCustomModelSelected {
                    HStack {
                        TextField("Model name (e.g. llama3.2:latest)", text: $customModelText)
                            .onSubmit { ollamaModel = customModelText }
                        Button("Use") { ollamaModel = customModelText }
                            .disabled(customModelText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    LabeledContent("Using", value: ollamaModel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Behavior") {
                Toggle("Use web search tool (requires API key)", isOn: $ollamaWebSearch)
                Text("Sends a web_search tool specification to Ollama's /api/generate. Web search is served by Ollama Cloud — you'll need an account and API key at ollama.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                HStack {
                    Button("Save") { saveOllamaAuth() }
                    Button("Test") { Task { await testOllama() } }
                    StatusChip(status: ollamaStatus)
                    if let msg = ollamaMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadFromKeychain()
            Task { await refreshModels() }
        }
    }

    private func loadFromKeychain() {
        unsplashKey = KeychainService.shared.get(.unsplashAccessKey) ?? ""
        ollamaAPIKey = KeychainService.shared.get(.ollamaAuthHeader) ?? ""
    }

    private func saveUnsplash() {
        if unsplashKey.isEmpty { KeychainService.shared.delete(.unsplashAccessKey) }
        else { KeychainService.shared.set(unsplashKey, for: .unsplashAccessKey) }
    }

    private func saveOllamaAuth() {
        if ollamaAPIKey.isEmpty { KeychainService.shared.delete(.ollamaAuthHeader) }
        else { KeychainService.shared.set(ollamaAPIKey, for: .ollamaAuthHeader) }
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

    private func testOllama() async {
        saveOllamaAuth()
        ollamaStatus = .testing
        ollamaMessage = nil
        let ok = await OllamaService.shared.ping()
        ollamaStatus = ok ? .ok : .failed
        ollamaMessage = ok ? "Reachable at \(ollamaURL)" : "Could not reach Ollama at \(ollamaURL)."
    }

    private func refreshModels() async {
        saveOllamaAuth()
        modelsLoading = true
        modelsError = nil
        do {
            availableModels = try await OllamaService.shared.listModels()
        } catch {
            modelsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            availableModels = []
        }
        modelsLoading = false
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
        .frame(width: 720, height: 600)
}
