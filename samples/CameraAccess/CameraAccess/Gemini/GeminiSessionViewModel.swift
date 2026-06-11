import Foundation
import SwiftUI
import UIKit

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var isAudioReady: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""

  private struct LiveSessionConfig {
    let credential: GeminiLiveCredential
    let systemInstruction: String
    let diagnosticsID: String?
    let provider: String?
  }

  private let geminiService = GeminiLiveService()
  private let audioManager = AudioManager()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private weak var workerAdminAPI: WorkerAdminAPI?
  private var adminExecutionSessionID: String?
  private var currentLiveCredential: GeminiLiveCredential?
  private var currentSessionInstruction: String?
  private var lastDiagnosticsID: String?
  private var isStoppingSession = false

  var streamingMode: StreamingMode = .glasses
  var onInputCommand: ((String) -> Void)?
  var onInputAudioChunk: ((Data) -> Void)?
  var onOutputAudioChunk: ((Data) -> Void)?

  func configureWorkerAdminAPI(_ api: WorkerAdminAPI?, sessionID: String? = nil) {
    workerAdminAPI = api
    adminExecutionSessionID = sessionID
  }

  func startSession(systemInstruction: String? = nil) async {
    guard !isGeminiActive else {
      await refreshSessionInstruction(systemInstruction)
      return
    }

    errorMessage = nil
    userTranscript = ""
    aiTranscript = ""
    isStoppingSession = false

    guard let liveConfig = await resolveLiveSessionConfig(fallbackInstruction: systemInstruction) else {
      errorMessage = "Gemini Live token unavailable. Check Admin AI Settings and the worker backend connection."
      return
    }
    currentLiveCredential = liveConfig.credential
    currentSessionInstruction = liveConfig.systemInstruction
    lastDiagnosticsID = liveConfig.diagnosticsID

    isAudioReady = false
    configureRealtimeCallbacks()
    startStateObservation()

    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      await resetToIdle(message: "Audio setup failed: \(error.localizedDescription)")
      return
    }

    let setupOk = await geminiService.connect(
      systemInstruction: liveConfig.systemInstruction,
      credential: liveConfig.credential
    )

    if !setupOk {
      let message = liveConnectionError(
        fallback: "Failed to connect to Gemini",
        diagnosticsID: liveConfig.diagnosticsID
      )
      await resetToIdle(message: message)
      await recordTelemetry(
        "gemini_live_connect_failed",
        stage: "failed",
        payload: [
          "diagnostics_id": liveConfig.diagnosticsID ?? NSNull(),
          "error": message
        ]
      )
      return
    }

    do {
      try audioManager.startCapture()
    } catch {
      await resetToIdle(message: "Mic capture failed: \(error.localizedDescription)")
      return
    }

    isGeminiActive = true
    isAudioReady = true
    await recordTelemetry(
      "gemini_live_session_started",
      stage: "ready",
      payload: [
        "model": liveConfig.credential.model,
        "provider": liveConfig.provider ?? "gemini",
        "diagnostics_id": liveConfig.diagnosticsID ?? NSNull()
      ]
    )
  }

  func stopSession() async {
    await resetToIdle(message: nil)
  }

  func refreshSessionInstruction(_ systemInstruction: String?) async {
    guard isGeminiActive else { return }
    guard let liveConfig = await resolveLiveSessionConfig(fallbackInstruction: systemInstruction) else {
      await resetToIdle(message: "Gemini Live token refresh failed. Check Admin AI Settings and try again.")
      return
    }

    guard liveConfig.systemInstruction != currentSessionInstruction ||
      liveConfig.credential.model != currentLiveCredential?.model else {
      return
    }

    await reconnectTransport(with: liveConfig)
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  private func configureRealtimeCallbacks() {
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
        self.onInputAudioChunk?(data)
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      self?.onOutputAudioChunk?(data)
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
        self.onInputCommand?(self.userTranscript)
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
        guard self.isGeminiActive, !self.isStoppingSession else { return }
        await self.resetToIdle(message: "Gemini connection lost: \(reason ?? "Unknown error")")
      }
    }

    geminiService.onSocketClosed = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive, !self.isStoppingSession else { return }
        await self.resetToIdle(message: "Gemini socket closed: \(reason ?? "Unknown error")")
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
      }
    }
  }

  private func reconnectTransport(with liveConfig: LiveSessionConfig) async {
    let wasActive = isGeminiActive
    isGeminiActive = false
    isAudioReady = false
    isStoppingSession = true
    await audioManager.stopCapture()
    await Task.yield()
    clearGeminiCallbacks()
    await geminiService.disconnectAndWaitForClose(timeout: 1.0)
    stateObservation?.cancel()
    stateObservation = nil
    isStoppingSession = false

    guard wasActive else { return }

    errorMessage = nil
    userTranscript = ""
    aiTranscript = ""
    currentLiveCredential = liveConfig.credential
    currentSessionInstruction = liveConfig.systemInstruction
    lastDiagnosticsID = liveConfig.diagnosticsID

    configureRealtimeCallbacks()
    startStateObservation()

    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      await resetToIdle(message: "Audio setup failed: \(error.localizedDescription)")
      return
    }

    let setupOk = await geminiService.connect(
      systemInstruction: liveConfig.systemInstruction,
      credential: liveConfig.credential
    )
    guard setupOk else {
      await resetToIdle(message: liveConnectionError(
        fallback: "Failed to reconnect to Gemini",
        diagnosticsID: liveConfig.diagnosticsID
      ))
      return
    }

    do {
      try audioManager.startCapture()
    } catch {
      await resetToIdle(message: "Mic capture failed: \(error.localizedDescription)")
      return
    }

    isGeminiActive = true
    isAudioReady = true
  }

  private func resolveLiveSessionConfig(fallbackInstruction: String?) async -> LiveSessionConfig? {
    guard let workerAdminAPI, GeminiConfig.isAdminConfigured else {
      await recordTelemetry(
        "gemini_live_token_failed",
        stage: "not_configured",
        payload: ["reason": "admin_api_unavailable"]
      )
      return nil
    }

    do {
      let token = try await workerAdminAPI.requestGeminiLiveToken(
        model: nil,
        sessionID: adminExecutionSessionID
      )
      let instruction = resolvedInstruction(
        serverInstruction: token.systemInstruction,
        fallbackInstruction: fallbackInstruction
      )
      await recordTelemetry(
        "gemini_live_token_received",
        stage: "ready",
        payload: [
          "model": token.credential.model,
          "provider": token.provider ?? "gemini",
          "expires_at": token.expiresAt,
          "diagnostics_id": token.diagnosticsID ?? NSNull()
        ]
      )
      return LiveSessionConfig(
        credential: token.credential,
        systemInstruction: instruction,
        diagnosticsID: token.diagnosticsID,
        provider: token.provider
      )
    } catch {
      let message = error.localizedDescription
      await recordTelemetry(
        "gemini_live_token_failed",
        stage: "failed",
        payload: ["error": message]
      )
      errorMessage = "Gemini token request failed: \(message)"
      return nil
    }
  }

  private func normalizedSystemInstruction(_ instruction: String?) -> String? {
    let trimmed = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func resolvedInstruction(
    serverInstruction: String?,
    fallbackInstruction: String?
  ) -> String {
    let server = normalizedSystemInstruction(serverInstruction)
    let fallback = normalizedSystemInstruction(fallbackInstruction)

    switch (server, fallback) {
    case let (server?, fallback?) where !server.contains(fallback):
      return """
      \(server)

      Local active-step context from the phone UI:
      \(fallback)
      """
    case let (server?, _):
      return server
    case let (nil, fallback?):
      return fallback
    default:
      return GeminiConfig.defaultSystemInstruction
    }
  }

  private func liveConnectionError(fallback: String, diagnosticsID: String?) -> String {
    let base: String
    if case .error(let err) = geminiService.connectionState {
      base = err
    } else {
      base = fallback
    }
    if let diagnosticsID, !diagnosticsID.isEmpty {
      return "\(base). Diagnostics: \(diagnosticsID)."
    }
    return base
  }

  private func resetToIdle(message: String?) async {
    isStoppingSession = true
    stateObservation?.cancel()
    stateObservation = nil
    // This is the Gemini-to-WebRTC hardware barrier: the engine graph and
    // accumulator finish before the socket is allowed to close.
    await audioManager.stopCapture()
    await Task.yield()
    audioManager.stopPlayback()
    clearGeminiCallbacks()
    await geminiService.disconnectAndWaitForClose(timeout: 1.0)

    isGeminiActive = false
    isAudioReady = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    currentSessionInstruction = nil
    currentLiveCredential = nil
    errorMessage = normalizedSystemInstruction(message)
    isStoppingSession = false
  }

  private func clearGeminiCallbacks() {
    geminiService.onDisconnected = nil
    geminiService.onSocketClosed = nil
    geminiService.onSocketOpened = nil
    geminiService.onAudioReceived = nil
    geminiService.onInterrupted = nil
    geminiService.onTurnComplete = nil
    geminiService.onInputTranscription = nil
    geminiService.onOutputTranscription = nil
  }

  private func recordTelemetry(
    _ name: String,
    stage: String,
    payload: [String: Any] = [:]
  ) async {
    await WorkerTelemetry.shared.record(
      name,
      source: "gemini_live",
      stage: stage,
      payload: payload
    )
  }
}
