import SwiftUI
#if os(macOS)
import AppKit
#endif

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
                Link(destination: URL(string: "https://unsplash.com/oauth/applications")!) {
                    Label("Get an Unsplash Access Key →", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
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
    @AppStorage("ollama.temperature") private var ollamaTemperature: Double = 0.3
    @AppStorage("ollama.timeoutSeconds") private var ollamaTimeoutSeconds: Double = 30

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

    /// Show the install-help block when Ollama is unreachable, when no
    /// models are installed at all, OR when the user's currently-selected
    /// model isn't in the local list (likely "I configured the default but
    /// haven't pulled it"). Hide only once the configured model is present.
    private var needsInstallHelp: Bool {
        if modelsError != nil { return true }
        if availableModels.isEmpty { return true }
        let trimmed = ollamaModel.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !availableModels.contains(trimmed)
    }

    private var installHelpHeadline: String {
        if modelsError != nil { return "Ollama isn't running." }
        if availableModels.isEmpty { return "No models installed yet." }
        return "The model \"\(ollamaModel)\" isn't pulled yet."
    }

    /// Pull command tailored to the currently-selected model so the user
    /// can copy-paste it directly. Falls back to the default model name when
    /// the field is blank.
    private var pullCommand: String {
        let trimmed = ollamaModel.trimmingCharacters(in: .whitespaces)
        let model = trimmed.isEmpty ? "qwen3-vl:2b-instruct" : trimmed
        return "ollama pull \(model)"
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

            // Show install help when we couldn't reach Ollama OR the configured
            // model isn't installed. Minimal: short paragraph + two
            // copy-to-clipboard commands + the docs link. Hidden once the user
            // has at least one model the app could pick from.
            if needsInstallHelp {
                Section("Get started") {
                    Text(installHelpHeadline)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text("paperpaper uses Ollama running locally for vision + place identification. Install it once, pull the default model, and you're done — everything stays on your machine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HelpCommandRow(
                        label: "1. Install Ollama",
                        command: "brew install ollama && ollama serve"
                    )
                    HelpCommandRow(
                        label: "2. Pull the vision model",
                        command: pullCommand
                    )

                    HStack(spacing: 12) {
                        Link(destination: URL(string: "https://ollama.com/download")!) {
                            Label("Ollama download page", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        Link(destination: URL(string: "https://ollama.com/library/qwen3-vl")!) {
                            Label("qwen3-vl models", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }

                    Button {
                        Task { await refreshModels() }
                    } label: {
                        Label("Re-check for installed models", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            // Search Agent section temporarily hidden — LLM-powered Discover
            // search is feature-flagged off until the agent flow is stable.

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

/// One install step: a label, a monospaced command in a tinted pill, and a
/// copy button. Clicking the pill copies too. Used in the Connections
/// onboarding block so users can paste a setup command into Terminal in two
/// clicks.
private struct HelpCommandRow: View {
    let label: String
    let command: String
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(copied ? "Copied" : "Copy command")
            }
        }
    }

    private func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        #endif
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}

/// Connections — Unsplash (image source) + Ollama (intelligence) on a single page.
struct ConnectionsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SourceView()
                IntelligenceView()
            }
        }
    }
}

#Preview("Source") { SourceView().frame(width: 720, height: 500) }
#Preview("Intelligence") { IntelligenceView().frame(width: 720, height: 600) }
