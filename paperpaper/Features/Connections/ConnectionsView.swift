import SwiftUI

/// Source — Unsplash credentials (the image input side).
struct SourceView: View {
    @State private var unsplashKey: String = ""
    @State private var status: TestStatus = .idle
    @State private var message: String?
    @State private var showAdvanced: Bool = false

    var body: some View {
        Form {
            Section("Unsplash") {
                SecureField("Access Key", text: $unsplashKey)
                HStack {
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                    Button("Test") { Task { await test() } }
                        .buttonStyle(.glass)
                        .disabled(unsplashKey.isEmpty)
                    StatusChip(status: status)
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Text("Paste your Unsplash Access Key (not the Secret). Free developer keys work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                Text("Nothing advanced here yet. Unsplash authentication is a single API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Advanced", systemImage: "ellipsis.circle")
            }
        }
        .formStyle(.grouped)
        .onAppear { unsplashKey = KeychainService.shared.get(.unsplashAccessKey) ?? "" }
    }

    private func save() {
        if unsplashKey.isEmpty { KeychainService.shared.delete(.unsplashAccessKey) }
        else { KeychainService.shared.set(unsplashKey, for: .unsplashAccessKey) }
    }

    private func test() async {
        save()
        status = .testing
        message = nil
        do {
            let result = try await UnsplashService.shared.search(query: "architecture", page: 1, perPage: 1)
            status = .ok
            message = "OK · \(result.total) photos match 'architecture'"
        } catch {
            status = .failed
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Intelligence — Ollama + Search Agent. All AI-related settings.
struct IntelligenceView: View {
    @State private var ollamaAPIKey: String = ""
    @AppStorage("ollama.url") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("ollama.model") private var ollamaModel: String = "llama3.2"
    @AppStorage("ollama.webSearch") private var ollamaWebSearch: Bool = false
    @AppStorage("ollama.temperature") private var ollamaTemperature: Double = 0.3
    @AppStorage("ollama.timeoutSeconds") private var ollamaTimeoutSeconds: Double = 30
    @AppStorage("agent.enabled") private var agentEnabled: Bool = false

    @State private var availableModels: [String] = []
    @State private var modelsLoading: Bool = false
    @State private var modelsError: String?
    @State private var customModelText: String = ""
    @State private var status: TestStatus = .idle
    @State private var message: String?
    @State private var showAdvanced: Bool = false

    private let customSentinel = "__custom__"

    private var isCustomModelSelected: Bool {
        !availableModels.contains(ollamaModel) && !availableModels.isEmpty
    }

    var body: some View {
        Form {
            Section("Ollama") {
                TextField("Host URL", text: $ollamaURL)
                SecureField("API key (for Cloud / web search)", text: $ollamaAPIKey)
                HStack {
                    Picker("Model", selection: Binding(
                        get: { isCustomModelSelected ? customSentinel : ollamaModel },
                        set: { newValue in
                            if newValue == customSentinel { customModelText = ollamaModel }
                            else { ollamaModel = newValue }
                        }
                    )) {
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                        if !availableModels.isEmpty { Divider() }
                        Text("Custom…").tag(customSentinel)
                    }
                    Button {
                        Task { await refreshModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .help("Refresh local models")
                }
                if isCustomModelSelected {
                    HStack {
                        TextField("Model name (e.g. llama3.2:latest)", text: $customModelText)
                        Button("Use") { ollamaModel = customModelText }
                            .disabled(customModelText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                HStack {
                    Button("Save") { saveOllamaKey() }
                        .buttonStyle(.glassProminent)
                    Button("Test") { Task { await test() } }
                        .buttonStyle(.glass)
                    StatusChip(status: status)
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if let modelsError {
                    Label(modelsError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Search Agent") {
                Toggle("Enable LLM-powered search (in Discover)", isOn: $agentEnabled)
                Text("When on, Discover shows a 'Smart Search' field that uses your Ollama model to progressively widen keywords, optionally verify with web search, and write a short description. Requires a local model via Ollama.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use web search tool (requires Ollama API key)", isOn: $ollamaWebSearch)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                HStack {
                    Text("Temperature")
                    Slider(value: $ollamaTemperature, in: 0...1)
                    Text(String(format: "%.2f", ollamaTemperature))
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Text("Timeout")
                    Slider(value: $ollamaTimeoutSeconds, in: 5...120)
                    Text("\(Int(ollamaTimeoutSeconds)) s")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
            } label: {
                Label("Advanced", systemImage: "ellipsis.circle")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ollamaAPIKey = KeychainService.shared.get(.ollamaAuthHeader) ?? ""
            Task { await refreshModels() }
        }
    }

    private func saveOllamaKey() {
        if ollamaAPIKey.isEmpty { KeychainService.shared.delete(.ollamaAuthHeader) }
        else { KeychainService.shared.set(ollamaAPIKey, for: .ollamaAuthHeader) }
    }

    private func test() async {
        saveOllamaKey()
        status = .testing
        message = nil
        let ok = await OllamaService.shared.ping()
        status = ok ? .ok : .failed
        message = ok ? "Reachable at \(ollamaURL)" : "Could not reach Ollama at \(ollamaURL)."
    }

    private func refreshModels() async {
        saveOllamaKey()
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

struct StatusChip: View {
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

/// Kept for backward-compat references from old callers — not in the tab list anymore.
struct ConnectionsView: View {
    var body: some View {
        TabView {
            SourceView()
                .tabItem { Label("Source", systemImage: "link") }
            IntelligenceView()
                .tabItem { Label("Intelligence", systemImage: "brain") }
        }
    }
}

#Preview("Source") { SourceView().frame(width: 720, height: 500) }
#Preview("Intelligence") { IntelligenceView().frame(width: 720, height: 600) }
