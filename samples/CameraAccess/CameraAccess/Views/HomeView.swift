import MWDATCore
import SwiftUI

private enum WorkerHomeSheet: String, Identifiable {
  case history
  case settings

  var id: String { rawValue }
}

struct HomeView: View {
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesViewModel: WearablesViewModel
  @State private var activeSheet: WorkerHomeSheet?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        statusStrip
        assignmentPanel
        cameraPanel
        notices
      }
      .padding(16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(DesignSystem.colors.adminBackground.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .history:
        NavigationStack {
          HistoryView(viewModel: viewModel)
            .background(DesignSystem.colors.adminBackground.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
        }
      case .settings:
        SettingsView()
      }
    }
    .fullScreenCover(item: $viewModel.activeCaptureSOP) { sop in
      NavigationStack {
        CaptureView(viewModel: viewModel, sop: sop)
      }
    }
    .task {
      await viewModel.handleWorkerHomeEntered()
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      Task {
        await viewModel.handleWorkerAppBecameActive()
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("EMBARCADERO")
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(DesignSystem.colors.brandOrange)
          .clipShape(RoundedRectangle(cornerRadius: 8))

        Text(viewModel.workerDisplayName)
          .font(DesignSystem.fonts.body(size: 28, weight: .semibold))
          .foregroundColor(DesignSystem.colors.adminInk)
          .lineLimit(1)
          .minimumScaleFactor(0.72)

        Text(viewModel.workerRoleText)
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.adminMuted)
      }

      Spacer(minLength: 12)

      HStack(spacing: 8) {
        iconButton(systemName: "arrow.clockwise") {
          Task { await viewModel.refreshWorkerContext() }
        }
        .disabled(viewModel.isSyncingOperations)
        .opacity(viewModel.isSyncingOperations ? 0.55 : 1)

        iconButton(systemName: "clock.arrow.circlepath") {
          activeSheet = .history
        }

        iconButton(systemName: "slider.horizontal.3") {
          activeSheet = .settings
        }
      }
    }
  }

  private var statusStrip: some View {
    HStack(spacing: 8) {
      statusPill(title: viewModel.pendingShiftLabel, color: DesignSystem.colors.adminMuted)
      statusPill(title: viewModel.assignmentQueueSummary, color: DesignSystem.colors.brandOrange)
    }
  }

  private var assignmentPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Text("CURRENT ASSIGNMENT")
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.brandOrange)
        Spacer()
        Text(viewModel.currentPackageProgressText)
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(DesignSystem.colors.adminMuted)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }

      if let sop = viewModel.currentAssignedSOP {
        VStack(alignment: .leading, spacing: 10) {
          Text(sop.name)
            .font(DesignSystem.fonts.body(size: 30, weight: .semibold))
            .foregroundColor(DesignSystem.colors.adminInk)
            .lineLimit(3)
            .minimumScaleFactor(0.72)

          Text(viewModel.currentAssignmentSubtitle)
            .font(DesignSystem.fonts.body(size: 15, weight: .medium))
            .foregroundColor(DesignSystem.colors.adminMuted)
            .lineLimit(2)

          HStack(spacing: 8) {
            assignmentMetric("\(sop.steps.count)", "steps")
            assignmentMetric(sop.validationSummary, "check")
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("No active SOP")
            .font(DesignSystem.fonts.body(size: 28, weight: .semibold))
            .foregroundColor(DesignSystem.colors.adminInk)

          Text("Sync assignments or set the worker login in Settings.")
            .font(DesignSystem.fonts.body(size: 15))
            .foregroundColor(DesignSystem.colors.adminMuted)
        }
      }

      Button {
        viewModel.startCurrentAssignmentFromHome()
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "camera.fill")
            .font(.system(size: 16, weight: .semibold))
          Text(viewModel.currentAssignedSOP == nil ? "NO ASSIGNMENT" : "START CAMERA")
            .font(DesignSystem.fonts.mono(size: 14, weight: .semibold))
        }
        .foregroundColor(DesignSystem.colors.white)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(viewModel.currentAssignedSOP == nil ? DesignSystem.colors.adminSubtle : DesignSystem.colors.adminInk)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .disabled(viewModel.currentAssignedSOP == nil || viewModel.isSyncingOperations)
    }
    .padding(16)
    .background(DesignSystem.colors.adminSurface)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(DesignSystem.colors.adminStroke, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .shadow(color: .black.opacity(0.05), radius: 18, x: 0, y: 10)
  }

  private var cameraPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: viewModel.hasActiveDevice ? "eyeglasses" : "iphone")
          .font(.system(size: 18, weight: .semibold))
          .foregroundColor(viewModel.hasActiveDevice ? DesignSystem.colors.successGreen : DesignSystem.colors.brandOrange)
          .frame(width: 34, height: 34)
          .background(DesignSystem.colors.adminBackground)
          .clipShape(RoundedRectangle(cornerRadius: 8))

        VStack(alignment: .leading, spacing: 3) {
          Text(viewModel.cameraReadinessLabel)
            .font(DesignSystem.fonts.body(size: 16, weight: .semibold))
            .foregroundColor(DesignSystem.colors.adminInk)
          Text(viewModel.cameraReadinessDetail)
            .font(DesignSystem.fonts.body(size: 13))
            .foregroundColor(DesignSystem.colors.adminMuted)
        }

        Spacer()

        Text("AUTO")
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(DesignSystem.colors.brandOrange)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(DesignSystem.colors.brandOrange.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 8))
      }

      if !viewModel.hasActiveDevice {
        Button {
          wearablesViewModel.connectGlasses()
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "eyeglasses")
            Text(wearablesViewModel.registrationState == .registering ? "CONNECTING GLASSES" : "CONNECT GLASSES")
          }
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.adminInk)
          .frame(maxWidth: .infinity)
          .frame(height: 42)
          .background(DesignSystem.colors.adminBackground)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(DesignSystem.colors.adminStroke, lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
        .disabled(wearablesViewModel.registrationState == .registering)
      }
    }
    .padding(14)
    .background(DesignSystem.colors.adminSurface)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(DesignSystem.colors.adminStroke, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var notices: some View {
    if viewModel.isSyncingOperations {
      noticeRow(
        icon: "arrow.triangle.2.circlepath",
        title: "Syncing assignments",
        body: "Loading the current worker queue.",
        color: DesignSystem.colors.brandOrange
      )
    }

    if let warning = viewModel.operationsSyncWarning,
       !warning.isEmpty {
      noticeRow(
        icon: "exclamationmark.triangle.fill",
        title: "Sync warning",
        body: warning,
        color: DesignSystem.colors.adminWarning
      )
    }

    if let error = viewModel.operationsSyncError,
       !error.isEmpty {
      noticeRow(
        icon: "exclamationmark.octagon.fill",
        title: "Assignment issue",
        body: error,
        color: DesignSystem.colors.dangerRed
      )
    }
  }

  private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(DesignSystem.colors.adminInk)
        .frame(width: 40, height: 40)
        .background(DesignSystem.colors.adminSurface)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(DesignSystem.colors.adminStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }

  private func statusPill(title: String, color: Color) -> some View {
    Text(title.uppercased())
      .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
      .foregroundColor(color)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(DesignSystem.colors.adminSurface)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(DesignSystem.colors.adminStroke, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func assignmentMetric(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value.uppercased())
        .font(DesignSystem.fonts.mono(size: 13, weight: .semibold))
        .foregroundColor(DesignSystem.colors.adminInk)
        .lineLimit(1)
        .minimumScaleFactor(0.7)

      Text(label.uppercased())
        .font(DesignSystem.fonts.mono(size: 10, weight: .semibold))
        .foregroundColor(DesignSystem.colors.adminMuted)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(DesignSystem.colors.adminBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func noticeRow(icon: String, title: String, body: String, color: Color) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(color)
        .frame(width: 24, height: 24)

      VStack(alignment: .leading, spacing: 4) {
        Text(title.uppercased())
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(color)

        Text(body)
          .font(DesignSystem.fonts.body(size: 13))
          .foregroundColor(DesignSystem.colors.adminMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(DesignSystem.colors.adminSurface)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(color.opacity(0.35), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}
