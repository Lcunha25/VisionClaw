import Foundation
import SwiftUI

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured

  private let geminiService = GeminiLiveService()
  private let sopRelayClient = SopRelayClient()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var heartbeatTimeoutTask: Task<Void, Never>?
  private var currentSopSessionId: String?
  private var isSopSessionTerminated: Bool = true
  private var isFinalizingSession: Bool = false
  private var pendingSystemInstruction: String?
  private var currentSessionInstruction: String?

  var streamingMode: StreamingMode = .glasses

  func startSession(systemInstruction: String? = nil) async {
    pendingSystemInstruction = normalizedSystemInstruction(systemInstruction)
    guard !isGeminiActive else {
      await refreshSessionInstruction(systemInstruction)
      return
    }
    errorMessage = nil
    userTranscript = ""
    aiTranscript = ""

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open Settings and add your key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true
    configureRealtimeCallbacks()

    await openClawBridge.checkConnection()
    openClawBridge.resetSession()
    toolCallRouter = ToolCallRouter(bridge: openClawBridge)
    startStateObservation()

    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      resetToIdle(receiptMessage: "Audio setup failed: \(error.localizedDescription)")
      return
    }

    let resolvedInstruction = resolvedSystemInstruction()
    let setupOk = await geminiService.connect(systemInstruction: resolvedInstruction)

    if !setupOk {
      let message: String
      if case .error(let err) = geminiService.connectionState {
        message = err
      } else {
        message = "Failed to connect to Gemini"
      }
      resetToIdle(receiptMessage: message)
      return
    }

    do {
      try audioManager.startCapture()
    } catch {
      resetToIdle(receiptMessage: "Mic capture failed: \(error.localizedDescription)")
      return
    }

    connectEventStreamIfNeeded()
    currentSessionInstruction = resolvedInstruction
  }

  func stopSession() {
    finalizeSessionWithReceipt(status: "terminated")
  }

  func refreshSessionInstruction(_ systemInstruction: String?) async {
    pendingSystemInstruction = normalizedSystemInstruction(systemInstruction)
    guard isGeminiActive else { return }

    let resolvedInstruction = resolvedSystemInstruction()
    guard resolvedInstruction != currentSessionInstruction else { return }

    await reconnectTransport(with: resolvedInstruction)
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  private func handleSopLogToolCall(_ call: GeminiFunctionCall) {
    let stepName = (call.args["step_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !stepName.isEmpty else {
      geminiService.sendToolResponse(buildToolResponse(
        callId: call.id,
        name: call.name,
        result: .failure("Missing required argument: step_name")
      ))
      return
    }

    let sessionId: String
    if let existing = currentSopSessionId {
      sessionId = existing
    } else {
      let created = UUID().uuidString
      currentSopSessionId = created
      isSopSessionTerminated = false
      sessionId = created
    }

    let imageBase64 = (call.args["frame_data"] as? String)?.isEmpty == false
      ? (call.args["frame_data"] as? String ?? "")
      : ((call.args["image_base64"] as? String)?.isEmpty == false
      ? (call.args["image_base64"] as? String ?? "")
      : (geminiService.lastVideoFrameBase64 ?? ""))

    sopRelayClient.postSopLog(
      tailscaleIP: GeminiConfig.openClawTailscaleIP,
      sessionID: sessionId,
      stepName: stepName,
      timestampISO8601: ISO8601DateFormatter().string(from: Date()),
      imageBase64: imageBase64
    )

    geminiService.sendToolResponse(buildToolResponse(
      callId: call.id,
      name: call.name,
      result: .success("SOP step forwarded")
    ))
  }

  private func connectEventStreamIfNeeded() {
    eventClient.disconnect()
    guard SettingsManager.shared.proactiveNotificationsEnabled else { return }

    eventClient.onNotification = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive, self.connectionState == .ready else { return }
        self.geminiService.sendTextMessage(text)
      }
    }
    eventClient.connect()
  }

  private func startSopHeartbeatSession() {
    if currentSopSessionId != nil && !isSopSessionTerminated { return }

    let sessionId = UUID().uuidString
    currentSopSessionId = sessionId
    isSopSessionTerminated = false

    heartbeatTask?.cancel()
    heartbeatTimeoutTask?.cancel()

    heartbeatTask = Task { [weak self] in
      guard let self else { return }

      self.sopRelayClient.postHeartbeat(
        tailscaleIP: GeminiConfig.openClawTailscaleIP,
        sessionID: sessionId,
        status: "active"
      )

      while !Task.isCancelled && !self.isSopSessionTerminated {
        self.sopRelayClient.postHeartbeat(
          tailscaleIP: GeminiConfig.openClawTailscaleIP,
          sessionID: sessionId,
          status: "active"
        )
        try? await Task.sleep(nanoseconds: 3_000_000_000)
      }
    }

    heartbeatTimeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 60_000_000_000)
      await MainActor.run {
        self?.finalizeSessionWithReceipt(status: "terminated")
      }
    }
  }

  private func finalizeSessionWithReceipt(status: String) {
    if isFinalizingSession { return }

    guard let sessionId = currentSopSessionId, !isSopSessionTerminated else {
      resetToIdle(receiptMessage: nil)
      return
    }

    isFinalizingSession = true
    isSopSessionTerminated = true
    heartbeatTask?.cancel()
    heartbeatTask = nil
    heartbeatTimeoutTask?.cancel()
    heartbeatTimeoutTask = nil

    Task { [weak self] in
      guard let self else { return }

      let receiptMessage = await self.sopRelayClient.postHeartbeatForReceipt(
        tailscaleIP: GeminiConfig.openClawTailscaleIP,
        sessionID: sessionId,
        status: status
      )

      await MainActor.run {
        self.resetToIdle(receiptMessage: receiptMessage)
      }
    }
  }

  private func resetToIdle(receiptMessage: String?) {
    eventClient.disconnect()
    geminiService.onDisconnected = nil
    geminiService.onSocketClosed = nil
    geminiService.onSocketOpened = nil

    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    heartbeatTask?.cancel()
    heartbeatTask = nil
    heartbeatTimeoutTask?.cancel()
    heartbeatTimeoutTask = nil

    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
    errorMessage = normalizedReceiptMessage(receiptMessage)
    currentSessionInstruction = nil

    currentSopSessionId = nil
    isSopSessionTerminated = true
    isFinalizingSession = false
  }

  private func normalizedSystemInstruction(_ instruction: String?) -> String? {
    let trimmed = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func resolvedSystemInstruction() -> String {
    if let pendingSystemInstruction {
      return pendingSystemInstruction
    }

    let configured = GeminiConfig.systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    if !configured.isEmpty {
      return configured
    }

    return GeminiConfig.defaultSystemInstruction
  }

  private func configureRealtimeCallbacks() {
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      self?.audioManager.playAudio(data: data)
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript = ""
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
      }
    }

    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive, !self.isFinalizingSession else { return }
        self.resetToIdle(receiptMessage: "Connection lost: \(reason ?? "Unknown error")")
      }
    }

    geminiService.onSocketOpened = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.startSopHeartbeatSession()
      }
    }

    geminiService.onSocketClosed = { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive, !self.isFinalizingSession else { return }
        self.finalizeSessionWithReceipt(status: "terminated")
      }
    }

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          if call.name == "log_sop_step" {
            self.handleSopLogToolCall(call)
            continue
          }

          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            self?.geminiService.sendToolResponse(response)
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }
  }

  private func startStateObservation() {
    stateObservation?.cancel()
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        self.openClawConnectionState = self.openClawBridge.connectionState
      }
    }
  }

  private func reconnectTransport(with systemInstruction: String) async {
    eventClient.disconnect()
    audioManager.stopCapture()
    geminiService.onDisconnected = nil
    geminiService.onSocketClosed = nil
    geminiService.onSocketOpened = nil
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    errorMessage = nil
    userTranscript = ""
    aiTranscript = ""

    await openClawBridge.checkConnection()
    if toolCallRouter == nil {
      toolCallRouter = ToolCallRouter(bridge: openClawBridge)
    }
    configureRealtimeCallbacks()
    startStateObservation()

    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      resetToIdle(receiptMessage: "Audio setup failed: \(error.localizedDescription)")
      return
    }

    let setupOk = await geminiService.connect(systemInstruction: systemInstruction)
    if !setupOk {
      let message: String
      if case .error(let err) = geminiService.connectionState {
        message = err
      } else {
        message = "Failed to reconnect to Gemini"
      }
      resetToIdle(receiptMessage: message)
      return
    }

    do {
      try audioManager.startCapture()
    } catch {
      resetToIdle(receiptMessage: "Mic capture failed: \(error.localizedDescription)")
      return
    }

    connectEventStreamIfNeeded()
    currentSessionInstruction = systemInstruction
  }

  private func normalizedReceiptMessage(_ receiptMessage: String?) -> String? {
    let trimmed = receiptMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    if trimmed.localizedCaseInsensitiveContains("legacy sop relay disabled") {
      return nil
    }
    return trimmed
  }

  private func buildToolResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    return [
      "toolResponse": [
        "functionResponses": [
          [
            "id": callId,
            "name": name,
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }
}
