import SwiftUI

private enum WorkerHomeSheet: String, Identifiable {
  case history
  case settings

  var id: String { rawValue }
}

struct HomeView: View {
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var viewModel: StreamSessionViewModel
  @State private var activeSheet: WorkerHomeSheet?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      actionControls
      captureModeControls
      pendingTasksSection
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(DesignSystem.colors.deepNavy.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .history:
        NavigationStack {
          HistoryView(viewModel: viewModel)
            .background(DesignSystem.colors.deepNavy.ignoresSafeArea())
            .navigationTitle("HISTORY")
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
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text(viewModel.workerDisplayName.uppercased())
          .font(DesignSystem.fonts.mono(size: 24, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)

        Text("\(viewModel.workerRoleText) · \(viewModel.pendingShiftLabel)")
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(DesignSystem.colors.blueGrey)

        Text(viewModel.pendingTaskHeaderSummary)
          .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
          .foregroundColor(DesignSystem.colors.vibrantTeal)
      }

      Spacer()

      Button {
        activeSheet = .settings
      } label: {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(DesignSystem.colors.vibrantTeal)
          .frame(width: 42, height: 42)
          .background(DesignSystem.colors.deepNavy)
          .overlay(Rectangle().stroke(DesignSystem.colors.white, lineWidth: 1))
      }
      .buttonStyle(.plain)
    }
  }

  private var actionControls: some View {
    HStack(spacing: 0) {
      actionButton(title: "SYNC TASKS") {
        Task {
          await viewModel.refreshWorkerContext()
        }
      }

      actionButton(title: "HISTORY") {
        activeSheet = .history
      }
    }
    .frame(height: 44)
    .background(DesignSystem.colors.deepNavy)
    .overlay(Rectangle().stroke(DesignSystem.colors.white, lineWidth: 1))
  }

  private var captureModeControls: some View {
    HStack(spacing: 0) {
      modeButton(title: "IPHONE CAMERA", mode: .iPhone, enabled: true)
      modeButton(title: "META CAMERA", mode: .glasses, enabled: viewModel.hasActiveDevice)
    }
    .frame(height: 44)
    .background(DesignSystem.colors.deepNavy)
    .overlay(Rectangle().stroke(DesignSystem.colors.white, lineWidth: 1))
  }

  private var pendingTasksSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("PENDING TASKS")
        .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
        .foregroundColor(DesignSystem.colors.blueGrey)
        .padding(.bottom, 8)

      if viewModel.isSyncingOperations {
        syncBanner
          .padding(.bottom, 10)
      }

      if let message = viewModel.operationsSyncError,
         !message.isEmpty {
        noticeBanner(title: "OPS NOTICE", body: message)
          .padding(.bottom, viewModel.pendingTaskSOPs.isEmpty ? 0 : 10)
      }

      if viewModel.pendingTaskSOPs.isEmpty {
        emptyStateCard(
          title: "NO PENDING TASKS",
          body: "All assigned SOPs for this demo shift are complete. Reopen the app to reset the shift list."
        )
      } else {
        VStack(spacing: 0) {
          ForEach(viewModel.pendingTaskSOPs) { sop in
            Button {
              viewModel.presentCapture(for: sop)
            } label: {
              PendingTaskRow(
                sop: sop,
                packageTitle: sop.packageTitle,
                isTopTask: sop.id == viewModel.pendingTaskSOPs.first?.id
              )
            }
            .buttonStyle(.plain)

            if sop.id != viewModel.pendingTaskSOPs.last?.id {
              Divider()
                .overlay(DesignSystem.colors.white.opacity(0.08))
            }
          }
        }
        .background(DesignSystem.colors.deepNavy)
        .overlay(Rectangle().stroke(DesignSystem.colors.white.opacity(0.16), lineWidth: 1))
      }
    }
  }

  private var syncBanner: some View {
    HStack(spacing: 10) {
      ProgressView()
        .tint(DesignSystem.colors.vibrantTeal)

      Text("Syncing pending tasks…")
        .font(DesignSystem.fonts.mono(size: 13, weight: .semibold))
        .foregroundColor(DesignSystem.colors.white)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DesignSystem.colors.deepNavy.opacity(0.75))
    .overlay(Rectangle().stroke(DesignSystem.colors.vibrantTeal.opacity(0.5), lineWidth: 1))
  }

  private func noticeBanner(title: String, body: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
        .foregroundColor(DesignSystem.colors.vibrantTeal)

      Text(body)
        .font(DesignSystem.fonts.body(size: 14))
        .foregroundColor(DesignSystem.colors.blueGrey)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DesignSystem.colors.deepNavy.opacity(0.75))
    .overlay(Rectangle().stroke(DesignSystem.colors.vibrantTeal.opacity(0.32), lineWidth: 1))
  }

  private func emptyStateCard(title: String, body: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
        .foregroundColor(DesignSystem.colors.vibrantTeal)

      Text(body)
        .font(DesignSystem.fonts.body(size: 14))
        .foregroundColor(DesignSystem.colors.blueGrey)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DesignSystem.colors.deepNavy)
    .overlay(Rectangle().stroke(DesignSystem.colors.white.opacity(0.16), lineWidth: 1))
  }

  private func actionButton(title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(DesignSystem.fonts.mono(size: 13, weight: .semibold))
        .foregroundColor(DesignSystem.colors.deepNavy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.colors.vibrantTeal)
        .overlay(Rectangle().stroke(DesignSystem.colors.white, lineWidth: 0.5))
    }
    .buttonStyle(.plain)
  }

  private func modeButton(title: String, mode: StreamingMode, enabled: Bool) -> some View {
    let selected = viewModel.preferredCaptureMode == mode
    return Button {
      viewModel.selectCaptureMode(mode)
    } label: {
      Text(title)
        .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
        .foregroundColor(selected ? DesignSystem.colors.deepNavy : DesignSystem.colors.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(selected ? DesignSystem.colors.vibrantTeal : DesignSystem.colors.deepNavy)
        .overlay(Rectangle().stroke(DesignSystem.colors.white, lineWidth: 0.5))
    }
    .disabled(!enabled)
    .opacity(enabled ? 1.0 : 0.45)
    .buttonStyle(.plain)
  }
}

private struct PendingTaskRow: View {
  let sop: SOPTemplate
  let packageTitle: String?
  let isTopTask: Bool

  private var taskSubtitle: String {
    let duration = "\(Int(max(sop.estimatedDuration, 15)))S"
    let prefix = "\(sop.items.count) ITEMS · EST. \(duration)"
    if let packageTitle, !packageTitle.isEmpty {
      return "\(prefix) · \(packageTitle.uppercased())"
    }
    return prefix
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text(sop.name)
          .font(DesignSystem.fonts.mono(size: 22, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)
          .multilineTextAlignment(.leading)

        Text(taskSubtitle)
          .font(DesignSystem.fonts.mono(size: 11, weight: .semibold))
          .foregroundColor(isTopTask ? DesignSystem.colors.vibrantTeal : DesignSystem.colors.blueGrey)
      }

      Spacer()

      Image(systemName: "chevron.right")
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(DesignSystem.colors.blueGrey)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isTopTask ? DesignSystem.colors.deepNavy.opacity(0.92) : DesignSystem.colors.deepNavy)
  }
}
