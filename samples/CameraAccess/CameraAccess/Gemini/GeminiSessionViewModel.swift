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
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var heartbeatTimeoutTask: Task<Void, Never>?
  private var currentSopSessionId: String?
  private var isSopSessionTerminated: Bool = true
  private var isFinalizingSession: Bool = false

  var streamingMode: StreamingMode = .glasses

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open Settings and add your key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        // iPhone mode: mute mic while model speaks to prevent echo feedback
        // (loudspeaker + co-located mic overwhelms iOS echo cancellation)
        if self.streamingMode == .iPhone && self.geminiService.isModelSpeaking { return }
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
        // Clear user transcript when AI finishes responding
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

    // Handle unexpected disconnection
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

    // Check OpenClaw connectivity and start fresh session
    await openClawBridge.checkConnection()
    openClawBridge.resetSession()

    // Wire tool call handling
    toolCallRouter = ToolCallRouter(bridge: openClawBridge)

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

    // Observe service state
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        self.openClawConnectionState = self.openClawBridge.connectionState
      }
    }

    // Setup audio
    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isGeminiActive = false
      return
    }

    // Connect to Gemini and wait for setupComplete
    let setupOk = await geminiService.connect()

    if !setupOk {
      let msg: String
      if case .error(let err) = geminiService.connectionState {
        msg = err
      } else {
        msg = "Failed to connect to Gemini"
      }
      errorMessage = msg
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Start mic capture
    do {
      try audioManager.startCapture()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }
  }

  func stopSession() {
    finalizeSessionWithReceipt(status: "terminated")
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
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
    geminiService.onDisconnected = nil
    geminiService.onSocketClosed = nil
    geminiService.onSocketOpened = nil

    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
    errorMessage = receiptMessage

    currentSopSessionId = nil
    isSopSessionTerminated = true
    isFinalizingSession = false
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
