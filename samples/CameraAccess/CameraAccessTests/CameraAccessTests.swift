/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import MWDATCore
import SwiftUI
import XCTest

@testable import CameraAccess

#if canImport(MWDATMockDevice)
import MWDATMockDevice

@MainActor
class ViewModelIntegrationTests: XCTestCase {

  private var mockDevice: MockRaybanMeta?
  private var cameraKit: MockCameraKit?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()

    // Pair mock device and set up camera kit
    let pairedMockDevice = MockDeviceKit.shared.pairRaybanMeta()
    mockDevice = pairedMockDevice
    cameraKit = pairedMockDevice.getCameraKit()

    // Power on and unfold the device to make it available
    pairedMockDevice.powerOn()
    pairedMockDevice.unfold()

    // Wait for device to be available in Wearables
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }

  override func tearDown() async throws {
    MockDeviceKit.shared.pairedDevices.forEach { mockDevice in
      MockDeviceKit.shared.unpairDevice(mockDevice)
    }
    mockDevice = nil
    cameraKit = nil
    try await super.tearDown()
  }

  // MARK: - Video Streaming Flow Tests

  func testVideoStreamingFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    await camera.setCameraFeed(fileURL: videoURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Stop streaming
    await viewModel.stopSession()

    // Wait for session to stop
    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Verify streaming stopped (allow for final states to be stopped or waiting)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }

  // MARK: - Photo Capture Flow Tests

  func testStreamingAndPhotoCaptureFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    guard let imageURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "png") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    await camera.setCameraFeed(fileURL: videoURL)
    await camera.setCapturedImage(fileURL: imageURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Capture photo while streaming
    viewModel.capturePhoto()
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify photo captured while maintaining stream (allow for some timing flexibility)
    XCTAssertTrue(viewModel.capturedPhoto != nil)
    XCTAssertTrue(viewModel.showPhotoPreview)
    XCTAssertTrue(viewModel.isStreaming)

    // Dismiss photo and stop streaming
    viewModel.dismissPhotoPreview()
    XCTAssertFalse(viewModel.showPhotoPreview)
    XCTAssertNil(viewModel.capturedPhoto)

    await viewModel.stopSession()
    try await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }
}
#endif

private final class RequestCaptureURLProtocol: URLProtocol {
  static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private struct WorkerUploadTargetRequestCapture: Equatable {
  let sessionID: String
  let assetType: String
  let filename: String
  let contentType: String
  let byteSize: Int
}

private struct WorkerAdminAPISnapshot {
  let heartbeats: [WorkerLiveHeartbeatRequest]
  let uploadTargetRequests: [WorkerUploadTargetRequestCapture]
  let uploadCalls: [(assetID: String, byteSize: Int, contentType: String)]
  let finalizeRequests: [WorkerMediaFinalizeRequest]
}

private final class WorkerAdminAPIMock: WorkerAdminAPI, @unchecked Sendable {
  private let lock = NSLock()

  var heartbeatErrors: [Error] = []
  var uploadTargetErrors: [Error] = []
  var uploadErrors: [Error] = []
  var finalizeErrors: [Error] = []
  var uploadTargetResponses: [WorkerMediaUploadTarget] = []
  var onFinalizeAttempt: ((WorkerMediaFinalizeRequest) -> Void)?

  private var recordedHeartbeats: [WorkerLiveHeartbeatRequest] = []
  private var recordedUploadTargetRequests: [WorkerUploadTargetRequestCapture] = []
  private var recordedUploadCalls: [(assetID: String, byteSize: Int, contentType: String)] = []
  private var recordedFinalizeRequests: [WorkerMediaFinalizeRequest] = []

  func sendWorkerLiveHeartbeat(_ heartbeat: WorkerLiveHeartbeatRequest) async throws {
    let queuedError = lock.withLock { () -> Error? in
      recordedHeartbeats.append(heartbeat)
      return heartbeatErrors.isEmpty ? nil : heartbeatErrors.removeFirst()
    }

    if let queuedError {
      throw queuedError
    }
  }

  func requestWorkerMediaUploadTarget(
    sessionID: String,
    assetType: String,
    filename: String,
    contentType: String,
    byteSize: Int
  ) async throws -> WorkerMediaUploadTarget {
    let (queuedError, response) = lock.withLock { () -> (Error?, WorkerMediaUploadTarget) in
      recordedUploadTargetRequests.append(
        WorkerUploadTargetRequestCapture(
          sessionID: sessionID,
          assetType: assetType,
          filename: filename,
          contentType: contentType,
          byteSize: byteSize
        )
      )
      let queuedError = uploadTargetErrors.isEmpty ? nil : uploadTargetErrors.removeFirst()
      let response: WorkerMediaUploadTarget
      if uploadTargetResponses.isEmpty {
        let index = recordedUploadTargetRequests.count
        response = WorkerMediaUploadTarget(
          assetID: "\(assetType)-asset-\(index)",
          bucket: "\(assetType)-bucket",
          path: "sessions/\(sessionID)/\(filename)",
          uploadURL: "https://upload.example/\(assetType)-\(index)"
        )
      } else {
        response = uploadTargetResponses.removeFirst()
      }
      return (queuedError, response)
    }

    if let queuedError {
      throw queuedError
    }
    return response
  }

  func finalizeWorkerMediaUpload(_ finalize: WorkerMediaFinalizeRequest) async throws {
    let (queuedError, finalizeHandler) = lock.withLock { () -> (Error?, ((WorkerMediaFinalizeRequest) -> Void)?) in
      recordedFinalizeRequests.append(finalize)
      let queuedError = finalizeErrors.isEmpty ? nil : finalizeErrors.removeFirst()
      return (queuedError, onFinalizeAttempt)
    }

    finalizeHandler?(finalize)

    if let queuedError {
      throw queuedError
    }
  }

  func uploadBinary(
    to target: WorkerMediaUploadTarget,
    data: Data,
    contentType: String
  ) async throws {
    let queuedError = lock.withLock { () -> Error? in
      recordedUploadCalls.append((assetID: target.assetID, byteSize: data.count, contentType: contentType))
      return uploadErrors.isEmpty ? nil : uploadErrors.removeFirst()
    }

    if let queuedError {
      throw queuedError
    }
  }

  func snapshot() -> WorkerAdminAPISnapshot {
    lock.lock()
    defer { lock.unlock() }
    return WorkerAdminAPISnapshot(
      heartbeats: recordedHeartbeats,
      uploadTargetRequests: recordedUploadTargetRequests,
      uploadCalls: recordedUploadCalls,
      finalizeRequests: recordedFinalizeRequests
    )
  }
}

private actor SleepRecorder {
  private(set) var values: [UInt64] = []

  func record(_ value: UInt64) {
    values.append(value)
  }

  func snapshot() -> [UInt64] {
    values
  }
}

private final class CallOrderRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [String] = []

  func append(_ value: String) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

final class WorkerAdminLiveSessionCoordinatorTests: XCTestCase {
  private func makeTempFile(data: Data, suffix: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("worker-admin-\(suffix)")
      .appendingPathExtension("mp4")
    try? FileManager.default.removeItem(at: url)
    try data.write(to: url)
    return url
  }

  func testHeartbeatKeepsStickyRoomCodeAndLastFrameLocation() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "frame-asset-1",
        bucket: "live-frames",
        path: "sessions/session-1/last-frame.jpg",
        uploadURL: "https://upload.example/frame-1"
      )
    ]

    let frameFinalized = expectation(description: "frame finalized")
    api.onFinalizeAttempt = { finalize in
      if finalize.assetID == "frame-asset-1", finalize.status == "uploaded" {
        frameFinalized.fulfill()
      }
    }

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      heartbeatIntervalNanoseconds: 0,
      sleeper: { _ in }
    )

    await coordinator.start(sessionID: "session-1", currentStepIndex: 0, helpRequested: false)
    await coordinator.updateRoomCode("ROOM42")
    await coordinator.enqueueFrameUpload(data: Data([0x01, 0x02, 0x03]))

    await fulfillment(of: [frameFinalized], timeout: 1.0)

    await coordinator.updateRoomCode("")
    await coordinator.updateHelpRequested(true)

    let snapshot = api.snapshot()
    XCTAssertEqual(snapshot.heartbeats.first?.webrtcRoomCode, nil)
    XCTAssertEqual(snapshot.heartbeats.last?.webrtcRoomCode, "ROOM42")
    XCTAssertEqual(snapshot.heartbeats.last?.lastFrameBucket, "live-frames")
    XCTAssertEqual(snapshot.heartbeats.last?.lastFramePath, "sessions/session-1/last-frame.jpg")
    XCTAssertEqual(snapshot.finalizeRequests.last?.status, "uploaded")
  }

  func testFrameUploadFinalizesFailedWhenUploadFailsAfterRetries() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "frame-asset-2",
        bucket: "live-frames",
        path: "sessions/session-2/last-frame.jpg",
        uploadURL: "https://upload.example/frame-2"
      )
    ]
    api.uploadErrors = [
      URLError(.networkConnectionLost),
      URLError(.networkConnectionLost),
      URLError(.networkConnectionLost),
      URLError(.networkConnectionLost),
    ]

    let sleepRecorder = SleepRecorder()
    let frameFailed = expectation(description: "frame failed finalize")
    api.onFinalizeAttempt = { finalize in
      if finalize.assetID == "frame-asset-2", finalize.status == "failed" {
        frameFailed.fulfill()
      }
    }

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      heartbeatIntervalNanoseconds: 0,
      sleeper: { value in
        await sleepRecorder.record(value)
      }
    )

    await coordinator.start(sessionID: "session-2", currentStepIndex: 0, helpRequested: false)
    await coordinator.enqueueFrameUpload(data: Data([0x0A, 0x0B]))

    await fulfillment(of: [frameFailed], timeout: 1.0)

    let snapshot = api.snapshot()
    let recordedSleeps = await sleepRecorder.snapshot()
    XCTAssertEqual(snapshot.uploadCalls.count, 4)
    XCTAssertEqual(snapshot.finalizeRequests.last?.status, "failed")
    XCTAssertEqual(recordedSleeps, [750_000_000, 1_500_000_000, 3_000_000_000])
  }

  func testVideoUploadFinalizesFailedWhenRecordingIsMissing() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-1",
        bucket: "execution-videos",
        path: "sessions/session-3/recording.mp4",
        uploadURL: "https://upload.example/video-1"
      )
    ]

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      sessionID: "session-3",
      heartbeatIntervalNanoseconds: 0,
      sleeper: { _ in }
    )

    let result = await coordinator.uploadVideoRecording(from: nil)
    let snapshot = api.snapshot()

    XCTAssertEqual(result.uploadState, "failed")
    XCTAssertEqual(snapshot.uploadTargetRequests.last?.byteSize, 0)
    XCTAssertEqual(snapshot.finalizeRequests.last?.status, "failed")
    XCTAssertTrue(snapshot.uploadCalls.isEmpty)
  }

  func testCompleteSessionUploadsVideoBeforeEndCallback() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-2",
        bucket: "execution-videos",
        path: "sessions/session-4/recording.mp4",
        uploadURL: "https://upload.example/video-2"
      )
    ]

    let fileURL = try makeTempFile(data: Data([0x01, 0x02, 0x03]), suffix: "ordering")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let callOrder = CallOrderRecorder()
    api.onFinalizeAttempt = { finalize in
      if finalize.assetID == "video-asset-2", finalize.status == "uploaded" {
        callOrder.append("finalize")
      }
    }

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      heartbeatIntervalNanoseconds: 0,
      sleeper: { _ in }
    )

    await coordinator.start(sessionID: "session-4", currentStepIndex: 0, helpRequested: false)
    let result = await coordinator.completeSession(videoFileURL: fileURL) {
      callOrder.append("end")
    }

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(callOrder.values, ["finalize", "end"])
  }

  func testVideoFinalizeRetriesTransientErrorsThenSucceeds() async throws {
    let api = WorkerAdminAPIMock()
    api.uploadTargetResponses = [
      WorkerMediaUploadTarget(
        assetID: "video-asset-3",
        bucket: "execution-videos",
        path: "sessions/session-5/recording.mp4",
        uploadURL: "https://upload.example/video-3"
      )
    ]
    api.finalizeErrors = [
      URLError(.timedOut),
      URLError(.networkConnectionLost),
    ]

    let sleepRecorder = SleepRecorder()
    let fileURL = try makeTempFile(data: Data([0xAB, 0xCD, 0xEF]), suffix: "retry")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let coordinator = WorkerAdminLiveSessionCoordinator(
      api: api,
      sessionID: "session-5",
      heartbeatIntervalNanoseconds: 0,
      sleeper: { value in
        await sleepRecorder.record(value)
      }
    )

    let result = await coordinator.uploadVideoRecording(from: fileURL)
    let snapshot = api.snapshot()
    let recordedSleeps = await sleepRecorder.snapshot()

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(
      snapshot.finalizeRequests.filter { $0.assetID == "video-asset-3" && $0.status == "uploaded" }.count,
      3
    )
    XCTAssertEqual(recordedSleeps, [750_000_000, 1_500_000_000])
  }
}

final class OpsAPIClientRoutingTests: XCTestCase {
  override func tearDown() {
    RequestCaptureURLProtocol.handler = nil
    super.tearDown()
  }

  func testWorkerRoutesUseAdminBaseURL() async throws {
    let settings = SettingsManager.shared
    let originalOpsBaseURL = settings.opsBaseURL
    let originalAdminBaseURL = settings.adminBaseURL
    let originalBearerToken = settings.openClawBearerToken

    settings.opsBaseURL = "https://ops.example.test"
    settings.adminBaseURL = "http://admin.example.test:3001"
    settings.openClawBearerToken = "worker-bearer-token"
    defer {
      settings.opsBaseURL = originalOpsBaseURL
      settings.adminBaseURL = originalAdminBaseURL
      settings.openClawBearerToken = originalBearerToken
    }

    let lock = NSLock()
    var capturedRequests: [URLRequest] = []
    RequestCaptureURLProtocol.handler = { request in
      lock.withLock {
        capturedRequests.append(request)
      }

      let body: Data
      switch request.url?.path {
      case "/health":
        body = Data(#"{"status":"ok","service":"ops"}"#.utf8)
      case "/api/worker/live/heartbeat":
        body = Data("{}".utf8)
      case "/api/worker/media/upload-target":
        body = Data(
          #"{"assetId":"video-asset-1","bucket":"execution-videos","path":"sessions/session-1/recording.mp4","uploadUrl":"https://upload.example/video-1"}"#
            .utf8
        )
      default:
        body = Data("{}".utf8)
      }

      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
      return (try XCTUnwrap(response), body)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RequestCaptureURLProtocol.self]
    let client = OpsAPIClient(session: URLSession(configuration: configuration))

    let health = try await client.health()
    XCTAssertEqual(health, "ok:ops")

    try await client.sendWorkerLiveHeartbeat(
      WorkerLiveHeartbeatRequest(
        sessionID: "11111111-1111-1111-1111-111111111111",
        webrtcRoomCode: "ROOM42",
        currentStepIndex: 2,
        helpRequested: true,
        status: "active",
        lastFrameBucket: "live-frames",
        lastFramePath: "sessions/session-1/last-frame.jpg"
      )
    )

    _ = try await client.requestWorkerMediaUploadTarget(
      sessionID: "11111111-1111-1111-1111-111111111111",
      assetType: "video",
      filename: "recording.mp4",
      contentType: "video/mp4",
      byteSize: 256
    )

    let requests = lock.withLock { capturedRequests }
    XCTAssertEqual(requests.map { $0.url?.host }, ["ops.example.test", "admin.example.test", "admin.example.test"])
    XCTAssertEqual(requests.map { $0.url?.path }, ["/health", "/api/worker/live/heartbeat", "/api/worker/media/upload-target"])
    XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(requests.dropFirst().first?.value(forHTTPHeaderField: "Authorization"), "Bearer worker-bearer-token")
  }

  func testWorkerRouteErrorsMentionAdminIngest() async throws {
    let settings = SettingsManager.shared
    let originalAdminBaseURL = settings.adminBaseURL
    let originalBearerToken = settings.openClawBearerToken

    settings.adminBaseURL = "http://admin.example.test:3001"
    settings.openClawBearerToken = "worker-bearer-token"
    defer {
      settings.adminBaseURL = originalAdminBaseURL
      settings.openClawBearerToken = originalBearerToken
    }

    RequestCaptureURLProtocol.handler = { request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 404,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/html"]
      )
      let body = Data("<pre>Cannot POST /api/worker/media/upload-target</pre>".utf8)
      return (try XCTUnwrap(response), body)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RequestCaptureURLProtocol.self]
    let client = OpsAPIClient(session: URLSession(configuration: configuration))

    do {
      _ = try await client.requestWorkerMediaUploadTarget(
        sessionID: "11111111-1111-1111-1111-111111111111",
        assetType: "video",
        filename: "recording.mp4",
        contentType: "video/mp4",
        byteSize: 256
      )
      XCTFail("Expected admin ingest request to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Admin ingest returned HTTP 404"))
      XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("ops-api"))
      XCTAssertTrue(error.localizedDescription.contains("/api/worker/media/upload-target"))
    }
  }
}
