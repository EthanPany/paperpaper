import Foundation

/// Which backend the enrichment agent talks to. "Ollama" is the local default;
/// "OpenAI-compatible" covers any server speaking the OpenAI `/chat/completions`
/// shape — OpenAI itself, OpenRouter, Together, LM Studio, llama.cpp's server,
/// vLLM, Groq, etc.
enum AIProvider: String, CaseIterable, Sendable {
    case ollama
    case openAICompatible = "openai"

    var displayName: String {
        switch self {
        case .ollama: return "Local (Ollama)"
        case .openAICompatible: return "Cloud API"
        }
    }

    /// Short label for status lines (menu bar, schedule debug).
    var shortName: String {
        switch self {
        case .ollama: return "Ollama"
        case .openAICompatible: return "Cloud API"
        }
    }

    /// The provider currently selected in Settings. Defaults to Ollama so
    /// existing installs keep their behavior.
    static var current: AIProvider {
        let raw = UserDefaults.standard.string(forKey: Keys.provider) ?? AIProvider.ollama.rawValue
        return AIProvider(rawValue: raw) ?? .ollama
    }

    /// UserDefaults / config keys shared by the service and the settings UI.
    enum Keys {
        static let provider = "ai.provider"
        static let openAIBaseURL = "openai.baseURL"
        static let openAIModel = "openai.model"
    }

    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"
    static let defaultOpenAIModel = "gpt-4o-mini"
}
