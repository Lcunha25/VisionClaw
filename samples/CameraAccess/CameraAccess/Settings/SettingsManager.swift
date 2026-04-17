import Foundation
import Security

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard
  private let keychain = KeychainStore(
    service: Bundle.main.bundleIdentifier ?? "com.embarcaderolabs.visionclaw"
  )

  private enum Key: String {
    case deviceID
    case workerLoginCode
    case workerEmail
    case geminiAPIKey
    case opsBaseURL
    case adminBaseURL
    case signalBaseURL
    case openClawHost
    case openClawPort
    case openClawBearerToken
    case openClawHookToken
    case openClawGatewayToken
    case geminiSystemPrompt
    case webrtcSignalingURL
    case speakerOutputEnabled
    case videoStreamingEnabled
    case proactiveNotificationsEnabled
    case openClawTailscaleIP
  }

  private init() {}

  // MARK: - Gemini

  var deviceID: String {
    get {
      if let stored = defaults.string(forKey: Key.deviceID.rawValue), !stored.isEmpty {
        return stored
      }

      if !Secrets.deviceID.isEmpty, Secrets.deviceID != "YOUR_DEVICE_UUID" {
        defaults.set(Secrets.deviceID, forKey: Key.deviceID.rawValue)
        return Secrets.deviceID
      }

      let generated = UUID().uuidString
      defaults.set(generated, forKey: Key.deviceID.rawValue)
      return generated
    }
    set { defaults.set(newValue, forKey: Key.deviceID.rawValue) }
  }

  var workerLoginCode: String {
    get { defaults.string(forKey: Key.workerLoginCode.rawValue) ?? Secrets.workerLoginCode }
    set { defaults.set(newValue, forKey: Key.workerLoginCode.rawValue) }
  }

  var workerEmail: String {
    get { defaults.string(forKey: Key.workerEmail.rawValue) ?? Secrets.workerEmail }
    set { defaults.set(newValue, forKey: Key.workerEmail.rawValue) }
  }

  var geminiAPIKey: String {
    get { secureString(for: .geminiAPIKey, fallback: Secrets.geminiAPIKey) }
    set { setSecureString(newValue, for: .geminiAPIKey) }
  }

  var opsBaseURL: String {
    get {
      if let stored = defaults.string(forKey: Key.opsBaseURL.rawValue),
         Self.isUsableRuntimeURL(stored) {
        return stored
      }
      return Secrets.opsBaseURL
    }
    set { defaults.set(newValue, forKey: Key.opsBaseURL.rawValue) }
  }

  var adminBaseURL: String {
    get {
      if let stored = defaults.string(forKey: Key.adminBaseURL.rawValue),
         Self.isUsableRuntimeURL(stored) {
        return stored
      }
      return Secrets.adminBaseURL
    }
    set { defaults.set(newValue, forKey: Key.adminBaseURL.rawValue) }
  }

  var signalBaseURL: String {
    get {
      if let stored = defaults.string(forKey: Key.signalBaseURL.rawValue),
         Self.isUsableRuntimeURL(stored) {
        return stored
      }
      if let legacy = defaults.string(forKey: Key.webrtcSignalingURL.rawValue),
         Self.isUsableRuntimeURL(legacy) {
        return Self.normalizeSignalBaseURL(legacy)
      }
      return Secrets.signalBaseURL
    }
    set { defaults.set(newValue, forKey: Key.signalBaseURL.rawValue) }
  }

  var geminiSystemPrompt: String {
    get { defaults.string(forKey: Key.geminiSystemPrompt.rawValue) ?? GeminiConfig.defaultSystemInstruction }
    set { defaults.set(newValue, forKey: Key.geminiSystemPrompt.rawValue) }
  }

  // MARK: - OpenClaw

  var openClawHost: String {
    get { defaults.string(forKey: Key.openClawHost.rawValue) ?? Secrets.openClawHost }
    set { defaults.set(newValue, forKey: Key.openClawHost.rawValue) }
  }

  var openClawPort: Int {
    get {
      let stored = defaults.integer(forKey: Key.openClawPort.rawValue)
      return stored != 0 ? stored : Secrets.openClawPort
    }
    set { defaults.set(newValue, forKey: Key.openClawPort.rawValue) }
  }

  var openClawHookToken: String {
    get { secureString(for: .openClawHookToken, fallback: Secrets.openClawHookToken) }
    set { setSecureString(newValue, for: .openClawHookToken) }
  }

  var openClawGatewayToken: String {
    get { secureString(for: .openClawGatewayToken, fallback: Secrets.openClawGatewayToken) }
    set { setSecureString(newValue, for: .openClawGatewayToken) }
  }

  var openClawTailscaleIP: String {
    get { defaults.string(forKey: Key.openClawTailscaleIP.rawValue) ?? Secrets.openClawTailscaleIP }
    set { defaults.set(newValue, forKey: Key.openClawTailscaleIP.rawValue) }
  }

  var openClawBearerToken: String {
    get { secureString(for: .openClawBearerToken, fallback: Secrets.openClawBearerToken) }
    set { setSecureString(newValue, for: .openClawBearerToken) }
  }

  // MARK: - WebRTC

  var webrtcSignalingURL: String {
    get { Self.normalizeWebSocketURL(signalBaseURL) }
    set {
      let normalized = Self.normalizeSignalBaseURL(newValue)
      defaults.set(normalized, forKey: Key.signalBaseURL.rawValue)
      defaults.set(normalized, forKey: Key.webrtcSignalingURL.rawValue)
    }
  }

  // MARK: - Audio

  var speakerOutputEnabled: Bool {
    get { defaults.bool(forKey: Key.speakerOutputEnabled.rawValue) }
    set { defaults.set(newValue, forKey: Key.speakerOutputEnabled.rawValue) }
  }

  // MARK: - Video

  var videoStreamingEnabled: Bool {
    get { defaults.object(forKey: Key.videoStreamingEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.videoStreamingEnabled.rawValue) }
  }

  // MARK: - Notifications

  var proactiveNotificationsEnabled: Bool {
    get { defaults.object(forKey: Key.proactiveNotificationsEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.proactiveNotificationsEnabled.rawValue) }
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.geminiSystemPrompt, .workerLoginCode, .workerEmail, .opsBaseURL, .adminBaseURL, .signalBaseURL,
                .openClawHost, .openClawPort, .webrtcSignalingURL, .openClawTailscaleIP,
                .deviceID, .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled] {
      defaults.removeObject(forKey: key.rawValue)
    }
    for key in [Key.geminiAPIKey, .openClawBearerToken, .openClawHookToken, .openClawGatewayToken] {
      defaults.removeObject(forKey: key.rawValue)
      keychain.removeValue(for: key.rawValue)
    }
  }

  private func secureString(for key: Key, fallback: String) -> String {
    if let stored = keychain.string(for: key.rawValue), !stored.isEmpty {
      return stored
    }

    if let legacy = defaults.string(forKey: key.rawValue), !legacy.isEmpty {
      keychain.set(legacy, for: key.rawValue)
      defaults.removeObject(forKey: key.rawValue)
      return legacy
    }

    if !fallback.isEmpty, !fallback.contains("YOUR_") {
      keychain.set(fallback, for: key.rawValue)
      return fallback
    }

    return fallback
  }

  private func setSecureString(_ value: String, for key: Key) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    defaults.removeObject(forKey: key.rawValue)
    if trimmed.isEmpty {
      keychain.removeValue(for: key.rawValue)
    } else {
      keychain.set(trimmed, for: key.rawValue)
    }
  }

  private static func normalizeSignalBaseURL(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed.hasPrefix("wss://") {
      return "https://" + String(trimmed.dropFirst("wss://".count))
    }
    if trimmed.hasPrefix("ws://") {
      return "http://" + String(trimmed.dropFirst("ws://".count))
    }
    if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
      return trimmed
    }
    return "https://\(trimmed)"
  }

  private static func isUsableRuntimeURL(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let blockedMarkers = [
      "YOUR_",
      "YOUR_MAC_IP",
      "example.com",
    ]

    return !blockedMarkers.contains { trimmed.localizedCaseInsensitiveContains($0) }
  }

  private static func normalizeWebSocketURL(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed.hasPrefix("wss://") || trimmed.hasPrefix("ws://") {
      return trimmed
    }
    if trimmed.hasPrefix("https://") {
      return "wss://" + String(trimmed.dropFirst("https://".count))
    }
    if trimmed.hasPrefix("http://") {
      return "ws://" + String(trimmed.dropFirst("http://".count))
    }
    return "wss://\(trimmed)"
  }
}

private struct KeychainStore {
  let service: String

  func string(for key: String) -> String? {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let value = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return value
  }

  func set(_ value: String, for key: String) {
    let data = Data(value.utf8)
    let query = baseQuery(for: key)
    let attributes = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(item as CFDictionary, nil)
    }
  }

  func removeValue(for key: String) {
    SecItemDelete(baseQuery(for: key) as CFDictionary)
  }

  private func baseQuery(for key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }
}
