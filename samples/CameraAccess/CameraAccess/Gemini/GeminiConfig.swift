import Foundation

enum GeminiConfig {
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  // Use a model that exists for this API key and supports native audio interactions.
  static let model = "models/gemini-2.5-flash-native-audio-latest"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let videoFrameInterval: TimeInterval = 1.0
  static let videoJPEGQuality: CGFloat = 0.5

  static var systemInstruction: String { SettingsManager.shared.geminiSystemPrompt }

  static let defaultSystemInstruction = """
    You are a visual SOP auditing model for smart glasses sessions.

    Your job is to analyze incoming camera frames and provide concise audit observations about the current SOP step.

    Rules:
    - Focus only on visual evidence in the frame.
    - Do not claim actions were completed unless visually supported.
    - If evidence is insufficient, state uncertainty clearly.
    - Keep responses short, factual, and audit-oriented.
    - Do not provide general assistant/task-execution behavior.
    """

  // User-configurable values (Settings screen overrides, falling back to Secrets.swift)
  static var deviceID: String { SettingsManager.shared.deviceID }
  static var workerLoginCode: String { SettingsManager.shared.workerLoginCode }
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

  static func websocketURL() -> URL? {
    guard apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty else { return nil }
    return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
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
