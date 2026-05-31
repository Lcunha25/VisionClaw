import Foundation

struct GeminiLiveCredential: Equatable {
  let token: String
  let queryParameterName: String
  let websocketBaseURL: String
  let model: String

  static func apiKey(_ apiKey: String = GeminiConfig.apiKey) -> GeminiLiveCredential? {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != "YOUR_GEMINI_API_KEY", !trimmed.isEmpty else { return nil }
    return GeminiLiveCredential(
      token: trimmed,
      queryParameterName: "key",
      websocketBaseURL: GeminiConfig.websocketBaseURL,
      model: GeminiConfig.model
    )
  }
}

enum GeminiConfig {
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  static let ephemeralTokenWebsocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"
  // Use a model that exists for this API key and supports native audio interactions.
  static let model = "models/gemini-live-2.5-flash-native-audio"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let videoFrameInterval: TimeInterval = 1.0
  static let videoJPEGQuality: CGFloat = 0.5

  static var systemInstruction: String { SettingsManager.shared.geminiSystemPrompt }

  static let defaultSystemInstruction = """
    You are a live frontline worker copilot for SOP execution sessions.

    Your job is to converse naturally with the worker, guide the current task step by step, and use connected tools when they help move the job forward.

    Rules:
    - Ground answers in the live camera feed, the current SOP context, and the worker's request.
    - If visual evidence is insufficient, say what you need to see next.
    - Keep spoken responses short, clear, and useful for hands-free work.
    - Offer direct next actions instead of long explanations.
    - Use available tools for task execution, logging, and memory when appropriate.
    - Never pretend you verified something you could not actually observe or infer.
    """

  // User-configurable values (Settings screen overrides, falling back to Secrets.swift)
  static var deviceID: String { SettingsManager.shared.deviceID }
  static var workerLoginCode: String { SettingsManager.shared.workerLoginCode }
  static var workerEmail: String { SettingsManager.shared.workerEmail }
  static var apiKey: String { SettingsManager.shared.geminiAPIKey }
  static var opsBaseURL: String { SettingsManager.shared.opsBaseURL }
  static var adminBaseURL: String { SettingsManager.shared.adminBaseURL }
  static var signalBaseURL: String { SettingsManager.shared.signalBaseURL }
  static var openClawHost: String { SettingsManager.shared.openClawHost }
  static var openClawPort: Int { SettingsManager.shared.openClawPort }
  static var openClawTailscaleIP: String { SettingsManager.shared.openClawTailscaleIP }
  static var openClawBearerToken: String { SettingsManager.shared.openClawBearerToken }
  static var openClawHookToken: String { SettingsManager.shared.openClawHookToken }
  static var openClawGatewayToken: String { SettingsManager.shared.openClawGatewayToken }

  static func websocketURL(credential: GeminiLiveCredential) -> URL? {
    guard var components = URLComponents(string: credential.websocketBaseURL) else { return nil }
    var queryItems = components.queryItems ?? []
    queryItems.append(
      URLQueryItem(name: credential.queryParameterName, value: credential.token)
    )
    components.queryItems = queryItems
    return components.url
  }

  static var isConfigured: Bool {
    return apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
  }

  static var isOpsConfigured: Bool {
    let trimmed = opsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.contains("YOUR_")
  }

  static var isAdminConfigured: Bool {
    let trimmed = adminBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.contains("YOUR_")
  }

  static var isOpenClawConfigured: Bool {
    return openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
      && !openClawGatewayToken.isEmpty
      && openClawHost != "http://YOUR_MAC_HOSTNAME.local"
  }
}
