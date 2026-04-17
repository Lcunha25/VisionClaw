import SwiftUI

struct GeminiStatusBar: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    HStack(spacing: 8) {
      // Gemini connection pill
      StatusPill(color: geminiStatusColor, text: geminiStatusText)

      // Video AI Analyst bridge connection pill
      StatusPill(color: openClawStatusColor, text: openClawStatusText)
    }
  }

  private var geminiStatusColor: Color {
    switch geminiVM.connectionState {
    case .ready: return .green
    case .connecting, .settingUp: return .yellow
    case .error: return .red
    case .disconnected: return .gray
    }
  }

  private var geminiStatusText: String {
    switch geminiVM.connectionState {
    case .ready: return "Gemini"
    case .connecting, .settingUp: return "Gemini..."
    case .error: return "Gemini Error"
    case .disconnected: return "Gemini Off"
    }
  }

  private var openClawStatusColor: Color {
    switch geminiVM.openClawConnectionState {
    case .connected: return .green
    case .checking: return .yellow
    case .unreachable: return .red
    case .notConfigured: return .gray
    }
  }

  private var openClawStatusText: String {
    switch geminiVM.openClawConnectionState {
    case .connected: return "Video AI Analyst"
    case .checking: return "Video AI Analyst..."
    case .unreachable: return "Analyst Off"
    case .notConfigured: return "No Analyst"
    }
  }
}

struct StatusPill: View {
  let color: Color
  let text: String

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(text)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.black.opacity(0.6))
    .cornerRadius(16)
  }
}

struct TranscriptView: View {
  let userText: String
  let aiText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !userText.isEmpty {
        Text(userText)
          .font(.system(size: 14))
          .foregroundColor(.white.opacity(0.7))
      }
      if !aiText.isEmpty {
        Text(aiText)
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(.white)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color.black.opacity(0.6))
    .cornerRadius(12)
  }
}

struct ToolCallStatusView: View {
  let status: ToolCallStatus

  var body: some View {
    if status != .idle {
      HStack(spacing: 8) {
        statusIcon
        Text(status.displayText)
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(.white)
          .lineLimit(1)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(statusBackground)
      .cornerRadius(16)
    }
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch status {
    case .executing:
      ProgressView()
        .scaleEffect(0.7)
        .tint(.white)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.green)
        .font(.system(size: 14))
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundColor(.red)
        .font(.system(size: 14))
    case .cancelled:
      Image(systemName: "xmark.circle.fill")
        .foregroundColor(.yellow)
        .font(.system(size: 14))
    case .idle:
      EmptyView()
    }
  }

  private var statusBackground: Color {
    switch status {
    case .executing: return Color.black.opacity(0.7)
    case .completed: return Color.black.opacity(0.6)
    case .failed: return Color.red.opacity(0.3)
    case .cancelled: return Color.black.opacity(0.6)
    case .idle: return Color.clear
    }
  }
}

struct SpeakingIndicator: View {
  @State private var animating = false

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<4, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color.white)
          .frame(width: 3, height: animating ? CGFloat.random(in: 8...20) : 6)
          .animation(
            .easeInOut(duration: 0.3)
              .repeatForever(autoreverses: true)
              .delay(Double(index) * 0.1),
            value: animating
          )
      }
    }
    .onAppear { animating = true }
    .onDisappear { animating = false }
  }
}

struct GeminiAssistantOverlay: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel
  let onToggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 10) {
        GeminiStatusBar(geminiVM: geminiVM)
        Spacer(minLength: 0)
        Button(action: onToggle) {
          Text(geminiVM.isGeminiActive ? "STOP AI" : "START AI")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.68))
            .overlay(
              RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
      }

      if !geminiVM.userTranscript.isEmpty || !geminiVM.aiTranscript.isEmpty {
        TranscriptView(userText: geminiVM.userTranscript, aiText: geminiVM.aiTranscript)
      }

      HStack(spacing: 10) {
        ToolCallStatusView(status: geminiVM.toolCallStatus)
        if geminiVM.isModelSpeaking {
          SpeakingIndicator()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.55))
            .cornerRadius(16)
        }
        Spacer(minLength: 0)
      }

      if let errorMessage = geminiVM.errorMessage, !errorMessage.isEmpty {
        Text(errorMessage)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.white)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(Color.red.opacity(0.28))
          .cornerRadius(12)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 18)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
