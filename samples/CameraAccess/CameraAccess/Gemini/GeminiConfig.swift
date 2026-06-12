import Foundation

struct GeminiLiveCredential: Equatable {
  let token: String
  let queryParameterName: String
  let websocketBaseURL: String
  let model: String
}

enum GeminiConfig {
  static let ephemeralTokenWebsocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"
  static let model = "models/gemini-live-2.5-flash-native-audio"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let videoFrameInterval: TimeInterval = 3.0
  static let videoJPEGQuality: CGFloat = 0.5

  static let defaultSystemInstruction = """
    You are Embarcadero's PD home-training nurse assistant for voice-guided SOP support.

    Act like a kind, calm nurse coaching a nervous peritoneal dialysis patient or caregiver at home during their first 6 months of PD.

    Rules:
    - Use direct, plain-language answers. Avoid chatty filler, long explanations, jokes, or overly conversational reassurance.
    - Give one clear next action at a time, then pause so the patient can act.
    - If you are unsure what the patient means or what the camera shows, ask one focused clarification question instead of guessing.
    - Ground answers in the live camera feed, the current PD SOP context, and the patient's request.
    - Use provider-approved checklist language. Do not invent steps, shortcuts, or clinical instructions.
    - Keep guidance operational and checklist-focused. Do not diagnose, prescribe, or make clinical treatment decisions.
    - When visual evidence is unclear or safety may be at risk, tell the patient or caregiver to pause and request human support.
    - Never pretend you verified something you could not actually observe or infer.
    """

  // User-configurable values (Settings screen overrides, falling back to Secrets.swift)
  static var deviceID: String { SettingsManager.shared.deviceID }
  static var workerLoginCode: String { SettingsManager.shared.workerLoginCode }
  static var workerEmail: String { SettingsManager.shared.workerEmail }
  static var opsBaseURL: String { SettingsManager.shared.opsBaseURL }
  static var adminBaseURL: String { SettingsManager.shared.adminBaseURL }
  static var signalBaseURL: String { SettingsManager.shared.signalBaseURL }
  static var workerAPIBearerToken: String { SettingsManager.shared.workerAPIBearerToken }

  static func websocketURL(credential: GeminiLiveCredential) -> URL? {
    guard var components = URLComponents(string: credential.websocketBaseURL) else { return nil }
    var queryItems = components.queryItems ?? []
    queryItems.append(
      URLQueryItem(name: credential.queryParameterName, value: credential.token)
    )
    components.queryItems = queryItems
    return components.url
  }

  static var isOpsConfigured: Bool {
    let trimmed = opsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.contains("YOUR_")
  }

  static var isAdminConfigured: Bool {
    let trimmed = adminBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.contains("YOUR_")
  }
}
