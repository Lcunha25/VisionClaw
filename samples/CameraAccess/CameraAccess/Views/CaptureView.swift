import SwiftUI

struct CaptureView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var viewModel: StreamSessionViewModel
  let sop: SOPTemplate
  @State private var highlightedChecklistItemID: UUID?
  @State private var isFinishingSOP: Bool = false
  @State private var finishButtonPulse: Bool = false

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        DesignSystem.colors.deepNavy
          .ignoresSafeArea()

        if let frame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
          Image(uiImage: frame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .ignoresSafeArea()
        } else {
          ProgressView()
            .progressViewStyle(.circular)
            .tint(DesignSystem.colors.vibrantTeal)
        }

        VStack {
          checklistOverlay(maxHeight: geometry.size.height * 0.2)
            .padding(.top, 12)
            .padding(.horizontal, 12)

          if !viewModel.dossierPipelineStatusMessage.isEmpty || viewModel.isDossierUploading {
            pipelineStatusBadge
              .padding(.top, 8)
              .padding(.horizontal, 12)
          }

          if viewModel.canRequestHelp || viewModel.webrtcViewModel.isActive || !viewModel.helpStatusMessage.isEmpty {
            supportStatusBar
              .padding(.top, 8)
              .padding(.horizontal, 12)
          }

          Spacer()

          bottomBar
            .padding(12)
        }
      }
    }
    .navigationTitle(sop.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .task {
      await viewModel.beginLiveCapture(for: sop)
    }
    .onChange(of: viewModel.shouldDismissCapture) { _, shouldDismiss in
      guard shouldDismiss else { return }
      viewModel.clearCaptureDismissFlag()
      dismiss()
    }
    .onDisappear {
      viewModel.stopHoldToTalk()
      if viewModel.isSopAuditRunning {
        viewModel.userTappedEndAndShip()
      }
    }
  }

  private func checklistOverlay(maxHeight: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("CHECKLIST")
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.blueGrey)
        Spacer()
        Text(viewModel.progressText)
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
      }

      ScrollView(showsIndicators: true) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(viewModel.checklistItems) { item in
            let isHighlighted = highlightedChecklistItemID == item.id

            Button {
              withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                viewModel.toggleChecklistItem(itemID: item.id, viaVoice: false)
              }
              animateChecklistSelection(item.id)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                  Image(systemName: item.isChecked ? "checkmark" : "minus")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(item.isChecked ? DesignSystem.colors.vibrantTeal : DesignSystem.colors.blueGrey)
                    .symbolEffect(.bounce, value: item.isChecked)

                  Text(item.name)
                    .font(DesignSystem.fonts.mono(size: 14, weight: .semibold))
                    .foregroundColor(item.isChecked ? DesignSystem.colors.white : DesignSystem.colors.blueGrey)
                    .strikethrough(item.isChecked, color: DesignSystem.colors.vibrantTeal)
                    .multilineTextAlignment(.leading)

                  Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                  if !item.duration.isEmpty {
                    Text(item.duration.uppercased())
                      .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
                      .foregroundColor(DesignSystem.colors.blueGrey)
                  }

                  Text(item.validation.uppercased())
                    .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
                    .foregroundColor(DesignSystem.colors.vibrantTeal)

                  if item.critical {
                    Text("CRITICAL")
                      .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
                      .foregroundColor(.red)
                  }

                  if !item.allowManualComplete && !item.isChecked {
                    Text("VISION")
                      .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
                      .foregroundColor(.orange)
                  }
                }
              }
              .padding(.vertical, 4)
              .padding(.horizontal, 6)
              .background(DesignSystem.colors.vibrantTeal.opacity(isHighlighted ? 0.16 : 0.0))
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .stroke(DesignSystem.colors.vibrantTeal.opacity(isHighlighted ? 0.85 : 0.0), lineWidth: 1)
              )
              .clipShape(RoundedRectangle(cornerRadius: 6))
              .scaleEffect(isHighlighted ? 1.015 : 1.0)
              .animation(.easeInOut(duration: 0.22), value: isHighlighted)
            }
            .disabled(!item.allowManualComplete && !item.isChecked)
            .opacity((!item.allowManualComplete && !item.isChecked) ? 0.75 : 1)
          }
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
    .background(DesignSystem.colors.deepNavy.opacity(0.62))
    .overlay(Rectangle().stroke(DesignSystem.colors.blueGrey.opacity(0.5), lineWidth: 1))
  }

  private var bottomBar: some View {
    HStack(spacing: 12) {
      holdToTalkButton
      Button {
        animateFinishSOPPress()
        viewModel.userTappedEndAndShip()
      } label: {
        HStack(spacing: 8) {
          if isFinishingSOP {
            Image(systemName: "checkmark.circle.fill")
              .transition(.scale.combined(with: .opacity))
          }
          Text(isFinishingSOP ? "FINISHING..." : "FINISH SOP")
        }
      }
      .brutalistDangerButton()
      .scaleEffect(finishButtonPulse ? 1.04 : 1.0)
      .opacity(isFinishingSOP ? 0.92 : 1.0)
      .animation(.spring(response: 0.25, dampingFraction: 0.65), value: finishButtonPulse)
      .animation(.easeInOut(duration: 0.2), value: isFinishingSOP)
      .disabled(isFinishingSOP)
    }
  }

  private var pipelineStatusBadge: some View {
    let accentColor: Color = {
      switch viewModel.dossierPipelineStatusKind {
      case .info:
        return DesignSystem.colors.blueGrey
      case .active:
        return DesignSystem.colors.vibrantTeal
      case .success:
        return DesignSystem.colors.deepGreen
      case .error:
        return .red
      }
    }()

    let statusIconName: String = {
      switch viewModel.dossierPipelineStatusKind {
      case .info:
        return "info.circle.fill"
      case .active:
        return "dot.radiowaves.left.and.right"
      case .success:
        return "checkmark.seal.fill"
      case .error:
        return "exclamationmark.triangle.fill"
      }
    }()

    return HStack(spacing: 8) {
      if viewModel.isDossierUploading {
        ProgressView()
          .tint(accentColor)
          .scaleEffect(0.8)
      } else {
        Image(systemName: statusIconName)
          .foregroundColor(accentColor)
          .font(.system(size: 12, weight: .semibold))
      }

      HStack(spacing: 6) {
        if !viewModel.dossierPipelineStatusTimestamp.isEmpty {
          Text("[\(viewModel.dossierPipelineStatusTimestamp)]")
            .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
            .foregroundColor(accentColor)
            .lineLimit(1)
        }

        Text(viewModel.dossierPipelineStatusMessage)
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
          .lineLimit(2)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(DesignSystem.colors.deepNavy.opacity(0.78))
    .background(accentColor.opacity(0.12))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(accentColor.opacity(0.9), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .transition(.move(edge: .top).combined(with: .opacity))
    .animation(.easeInOut(duration: 0.2), value: viewModel.dossierPipelineStatusMessage)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isDossierUploading)
    .animation(.easeInOut(duration: 0.2), value: viewModel.dossierPipelineStatusKind)
    .animation(.easeInOut(duration: 0.2), value: viewModel.dossierPipelineStatusTimestamp)
  }

  private var supportStatusBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if viewModel.webrtcViewModel.isActive {
          WebRTCStatusBar(webrtcVM: viewModel.webrtcViewModel)
        } else {
          Text("SUPPORT")
            .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
            .foregroundColor(DesignSystem.colors.vibrantTeal)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DesignSystem.colors.deepNavy.opacity(0.6))
            .overlay(
              RoundedRectangle(cornerRadius: 16)
                .stroke(DesignSystem.colors.vibrantTeal.opacity(0.8), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }

        Spacer(minLength: 0)

        Button(viewModel.isRequestingHelp ? "REQUESTING..." : "REQUEST HELP") {
          viewModel.requestSupervisorHelp()
        }
        .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
        .foregroundColor(DesignSystem.colors.deepNavy)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DesignSystem.colors.vibrantTeal)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(DesignSystem.colors.white, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .disabled(!viewModel.canRequestHelp || viewModel.isRequestingHelp)
        .opacity(viewModel.canRequestHelp ? 1 : 0.5)
      }

      if !viewModel.helpStatusMessage.isEmpty {
        Text(viewModel.helpStatusMessage)
          .font(DesignSystem.fonts.body(size: 12))
          .foregroundColor(DesignSystem.colors.white)
          .multilineTextAlignment(.leading)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(DesignSystem.colors.deepNavy.opacity(0.78))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(DesignSystem.colors.vibrantTeal.opacity(0.8), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var holdToTalkButton: some View {
    let listening = viewModel.isListeningForVoice
    return Text(listening ? "LISTENING..." : "HOLD TO TALK")
      .font(DesignSystem.fonts.mono(size: 15, weight: .semibold))
      .foregroundColor(listening ? DesignSystem.colors.deepNavy : DesignSystem.colors.white)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity)
      .background(listening ? DesignSystem.colors.vibrantTeal : DesignSystem.colors.deepNavy)
      .overlay(Rectangle().stroke(DesignSystem.colors.white, lineWidth: 1))
      .scaleEffect(listening ? 1.03 : 1.0)
      .animation(.easeInOut(duration: 0.18), value: listening)
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if !viewModel.isListeningForVoice {
              viewModel.startHoldToTalk()
            }
          }
          .onEnded { _ in
            viewModel.stopHoldToTalk()
          }
      )
  }

  private func animateChecklistSelection(_ itemID: UUID) {
    withAnimation(.easeInOut(duration: 0.18)) {
      highlightedChecklistItemID = itemID
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
      withAnimation(.easeOut(duration: 0.22)) {
        if highlightedChecklistItemID == itemID {
          highlightedChecklistItemID = nil
        }
      }
    }
  }

  private func animateFinishSOPPress() {
    guard !isFinishingSOP else { return }

    withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
      isFinishingSOP = true
      finishButtonPulse = true
    }

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 450_000_000)
      withAnimation(.easeOut(duration: 0.2)) {
        finishButtonPulse = false
      }

      try? await Task.sleep(nanoseconds: 700_000_000)
      withAnimation(.easeInOut(duration: 0.2)) {
        isFinishingSOP = false
      }
    }
  }
}
