import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var workerLoginCode: String = ""
  @State private var workerEmail: String = ""
  @State private var geminiAPIKey: String = ""
  @State private var opsBaseURL: String = ""
  @State private var adminBaseURL: String = ""
  @State private var signalBaseURL: String = ""
  @State private var openClawHost: String = ""
  @State private var openClawPort: String = ""
  @State private var openClawTailscaleIP: String = ""
  @State private var openClawHookToken: String = ""
  @State private var openClawGatewayToken: String = ""
  @State private var geminiSystemPrompt: String = ""
  @State private var webrtcSignalingURL: String = ""
  @State private var speakerOutputEnabled: Bool = false
  @State private var videoStreamingEnabled: Bool = true
  @State private var proactiveNotificationsEnabled: Bool = true
  @State private var showResetConfirmation = false

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Worker")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Worker Email")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("worker@company.com", text: $workerEmail)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.emailAddress)
              .textInputAutocapitalization(.never)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Login Code")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("EMBC-0001", text: $workerLoginCode)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Operations Backend"), footer: Text("Ops Base URL handles worker bootstrap, sessions, events, interventions, and evidence uploads. Admin Base URL handles the /api/worker live ingest endpoints used for live frames, heartbeats, and final video replay sync.")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Ops Base URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("https://admin.embarcaderolabs.cloud", text: $opsBaseURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Admin Base URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("https://admin.embarcaderolabs.cloud", text: $adminBaseURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Signal Base URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("https://signal.embarcaderolabs.cloud", text: $signalBaseURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Gemini API")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
              .font(.caption)
              .foregroundColor(.secondary)
            SecureField("Enter Gemini API key", text: $geminiAPIKey)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("System Prompt"), footer: Text("Customize the AI assistant's behavior and personality. Changes take effect on the next Gemini session.")) {
          TextEditor(text: $geminiSystemPrompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 200)
        }

        Section(header: Text("Video AI Analyst"), footer: Text("Private analyst connectivity stays separate from ops-api so memory links and agent-style actions can evolve independently.")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Host")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("http://your-mac.local", text: $openClawHost)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Port")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("18789", text: $openClawPort)
              .keyboardType(.numberPad)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Tailscale Host")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("srv1338555", text: $openClawTailscaleIP)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.numbersAndPunctuation)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Hook Token")
              .font(.caption)
              .foregroundColor(.secondary)
            SecureField("Hook token", text: $openClawHookToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Gateway Token")
              .font(.caption)
              .foregroundColor(.secondary)
            SecureField("Gateway auth token", text: $openClawGatewayToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("WebRTC")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Signaling URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("wss://your-server.example.com", text: $webrtcSignalingURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Audio"), footer: Text("Route audio output to the iPhone speaker instead of glasses. Useful for demos where others need to hear.")) {
          Toggle("Speaker Output", isOn: $speakerOutputEnabled)
        }

        Section(header: Text("Video"), footer: Text("Disable video streaming to save battery. Audio remains active for voice-only interaction.")) {
          Toggle("Video Streaming", isOn: $videoStreamingEnabled)
        }

        Section(header: Text("Notifications"), footer: Text("Receive proactive updates from Video AI Analyst (heartbeat, scheduled tasks) spoken through the glasses.")) {
          Toggle("Proactive Notifications", isOn: $proactiveNotificationsEnabled)
        }

        Section {
          Button("Reset to Defaults") {
            showResetConfirmation = true
          }
          .foregroundColor(.red)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Save") {
            save()
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .alert("Reset Settings", isPresented: $showResetConfirmation) {
        Button("Reset", role: .destructive) {
          settings.resetAll()
          loadCurrentValues()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will reset all settings to the values built into the app.")
      }
      .onAppear {
        loadCurrentValues()
      }
    }
  }

  private func loadCurrentValues() {
    workerLoginCode = settings.workerLoginCode
    workerEmail = settings.workerEmail
    geminiAPIKey = settings.geminiAPIKey
    opsBaseURL = settings.opsBaseURL
    adminBaseURL = settings.adminBaseURL
    signalBaseURL = settings.signalBaseURL
    geminiSystemPrompt = settings.geminiSystemPrompt
    openClawHost = settings.openClawHost
    openClawPort = String(settings.openClawPort)
    openClawTailscaleIP = settings.openClawTailscaleIP
    openClawHookToken = settings.openClawHookToken
    openClawGatewayToken = settings.openClawGatewayToken
    webrtcSignalingURL = settings.webrtcSignalingURL
    speakerOutputEnabled = settings.speakerOutputEnabled
    videoStreamingEnabled = settings.videoStreamingEnabled
    proactiveNotificationsEnabled = settings.proactiveNotificationsEnabled
  }

  private func save() {
    settings.workerLoginCode = workerLoginCode.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.workerEmail = workerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.geminiAPIKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.opsBaseURL = opsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.adminBaseURL = adminBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.signalBaseURL = signalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.geminiSystemPrompt = geminiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawHost = openClawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    if let port = Int(openClawPort.trimmingCharacters(in: .whitespacesAndNewlines)) {
      settings.openClawPort = port
    }
    settings.openClawTailscaleIP = openClawTailscaleIP.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawHookToken = openClawHookToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawGatewayToken = openClawGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.webrtcSignalingURL = webrtcSignalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.speakerOutputEnabled = speakerOutputEnabled
    settings.videoStreamingEnabled = videoStreamingEnabled
    settings.proactiveNotificationsEnabled = proactiveNotificationsEnabled
  }
}
