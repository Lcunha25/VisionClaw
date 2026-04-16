/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import MWDATCamera
import MWDATCore
import AVFoundation
import Combine
import Speech
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

enum ChecklistCompletionSource: String, Codable {
  case pending
  case manual
  case voice
  case vision
}

enum SopTerminationStatus: String, Codable {
  case timedOut = "timed_out"
  case allItemsChecked = "all_items_checked"
  case userEnded = "user_ended"
}

enum DossierPipelineStatusKind {
  case info
  case active
  case success
  case error
}

struct SOPTemplate: Identifiable, Hashable {
  let id: UUID
  let remoteID: String?
  let name: String
  let steps: [SOPStepTemplate]
  let estimatedDuration: Double
  let shiftID: String?
  let shiftName: String?
  let packageID: String?
  let packageRunID: String?
  let packageTitle: String?
  let packageVersion: Int?
  let sopVersion: Int?
  let sourceType: String
  let sortOrder: Int
  let required: Bool

  var items: [String] {
    steps.map(\.title)
  }

  var validationSummary: String {
    let labels = Array(Set(steps.map { $0.validation.uppercased() })).sorted()
    return labels.isEmpty ? "NO VALIDATION" : labels.joined(separator: " + ")
  }

  init(
    id: UUID = UUID(),
    remoteID: String? = nil,
    name: String,
    steps: [SOPStepTemplate]? = nil,
    items: [String] = [],
    estimatedDuration: Double = 15.0,
    shiftID: String? = nil,
    shiftName: String? = nil,
    packageID: String? = nil,
    packageRunID: String? = nil,
    packageTitle: String? = nil,
    packageVersion: Int? = nil,
    sopVersion: Int? = nil,
    sourceType: String = "standalone",
    sortOrder: Int = 0,
    required: Bool = true
  ) {
    self.id = id
    self.remoteID = remoteID
    self.name = name
    let resolvedSteps = steps ?? items.enumerated().map { index, item in
      SOPStepTemplate(
        id: ChecklistItemState.normalizedItemID(from: item),
        order: index + 1,
        title: item,
        aiPrompt: "Look at the image and confirm whether \"\(item)\" has been completed."
      )
    }
    self.steps = resolvedSteps.sorted { $0.order < $1.order }
    self.estimatedDuration = estimatedDuration
    self.shiftID = shiftID
    self.shiftName = shiftName
    self.packageID = packageID
    self.packageRunID = packageRunID
    self.packageTitle = packageTitle
    self.packageVersion = packageVersion
    self.sopVersion = sopVersion
    self.sourceType = sourceType
    self.sortOrder = sortOrder
    self.required = required
  }
}

private func validRemoteUUID(_ value: String?) -> String? {
  guard let value,
        UUID(uuidString: value) != nil
  else { return nil }
  return value
}

struct SOPStepTemplate: Identifiable, Hashable {
  let id: String
  let order: Int
  let title: String
  let description: String
  let duration: String
  let validation: String
  let critical: Bool
  let aiPrompt: String
  let expectedObjects: [String]
  let allowManualComplete: Bool

  init(
    id: String,
    order: Int,
    title: String,
    description: String = "",
    duration: String = "30s",
    validation: String = "visual",
    critical: Bool = false,
    aiPrompt: String,
    expectedObjects: [String] = [],
    allowManualComplete: Bool = true
  ) {
    self.id = id
    self.order = order
    self.title = title
    self.description = description
    self.duration = duration
    self.validation = validation
    self.critical = critical
    self.aiPrompt = aiPrompt
    self.expectedObjects = expectedObjects
    self.allowManualComplete = allowManualComplete
  }
}

private struct RemoteSOPListResponse: Decodable {
  let version: String?

  private let sops: [RemoteSOP]?
  private let data: [RemoteSOP]?
  private let templates: [RemoteSOP]?
  private let sopTemplates: [RemoteSOP]?

  var allSOPs: [RemoteSOP] {
    sops ?? data ?? templates ?? sopTemplates ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case sops
    case data
    case templates
    case sopTemplates = "sop_templates"
  }
}

private struct RemoteSOP: Decodable {
  let id: String
  let name: String
  let items: [RemoteSOPItem]
  let estimatedDuration: Double?
  let updatedAt: Date?
  let createdAt: Date?

  private enum CodingKeys: String, CodingKey {
    case id
    case uuid
    case sopID = "sop_id"
    case name
    case title
    case items
    case estimatedDuration = "estimatedDuration"
    case estimatedDurationSnake = "estimated_duration"
    case duration
    case updatedAt = "updatedAt"
    case updatedAtSnake = "updated_at"
    case modifiedAtSnake = "modified_at"
    case createdAt = "createdAt"
    case createdAtSnake = "created_at"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    let decodedID = try container.decodeIfPresent(String.self, forKey: .id)
    let decodedUUID = try container.decodeIfPresent(String.self, forKey: .uuid)
    let decodedSopID = try container.decodeIfPresent(String.self, forKey: .sopID)
    id = decodedID ?? decodedUUID ?? decodedSopID ?? UUID().uuidString

    let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
    let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
    name = decodedName ?? decodedTitle ?? "Untitled SOP"

    if let decodedItems = try container.decodeIfPresent([RemoteSOPItem].self, forKey: .items) {
      items = decodedItems
    } else if let stringItems = try container.decodeIfPresent([String].self, forKey: .items) {
      items = stringItems.map { RemoteSOPItem(name: $0) }
    } else {
      items = []
    }

    if let estimate = try container.decodeIfPresent(Double.self, forKey: .estimatedDuration) {
      estimatedDuration = estimate
    } else if let estimate = try container.decodeIfPresent(Double.self, forKey: .estimatedDurationSnake) {
      estimatedDuration = estimate
    } else if let estimate = try container.decodeIfPresent(Double.self, forKey: .duration) {
      estimatedDuration = estimate
    } else if let estimateInt = try container.decodeIfPresent(Int.self, forKey: .estimatedDuration) {
      estimatedDuration = Double(estimateInt)
    } else if let estimateInt = try container.decodeIfPresent(Int.self, forKey: .estimatedDurationSnake) {
      estimatedDuration = Double(estimateInt)
    } else if let estimateInt = try container.decodeIfPresent(Int.self, forKey: .duration) {
      estimatedDuration = Double(estimateInt)
    } else {
      estimatedDuration = nil
    }

    let decodedUpdatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    let decodedUpdatedAtSnake = try container.decodeIfPresent(String.self, forKey: .updatedAtSnake)
    let decodedModifiedAtSnake = try container.decodeIfPresent(String.self, forKey: .modifiedAtSnake)
    let updatedRaw = decodedUpdatedAt ?? decodedUpdatedAtSnake ?? decodedModifiedAtSnake

    let decodedCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    let decodedCreatedAtSnake = try container.decodeIfPresent(String.self, forKey: .createdAtSnake)
    let createdRaw = decodedCreatedAt ?? decodedCreatedAtSnake

    updatedAt = Self.parseDate(updatedRaw)
    createdAt = Self.parseDate(createdRaw)
  }

  private static func parseDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoFormatter.date(from: raw) { return date }

    let fallbackISO = ISO8601DateFormatter()
    if let date = fallbackISO.date(from: raw) { return date }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: raw)
  }
}

private struct RemoteSOPItem: Decodable {
  let name: String

  init(name: String) {
    self.name = name
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case title
    case label
    case item
  }

  init(from decoder: Decoder) throws {
    if let singleValueContainer = try? decoder.singleValueContainer(),
      let raw = try? singleValueContainer.decode(String.self)
    {
      name = raw
      return
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
    let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
    let decodedLabel = try container.decodeIfPresent(String.self, forKey: .label)
    let decodedItem = try container.decodeIfPresent(String.self, forKey: .item)
    name = decodedName ?? decodedTitle ?? decodedLabel ?? decodedItem ?? "Unknown Item"
  }
}

private final class SopVideoRecorder: @unchecked Sendable {
  private let queue = DispatchQueue(label: "sop.video.recorder", qos: .userInitiated)
  private var writer: AVAssetWriter?
  private var writerInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var recordingStartHostTime: CFTimeInterval?
  private(set) var outputURL: URL?
  private var isFinishing = false
  private var appendedFrameCount = 0

  func appendFrame(_ image: UIImage) {
    queue.async { [weak self] in
      guard let self, !self.isFinishing else { return }
      self.configureWriterIfNeeded(for: image)

      guard let writer = self.writer,
            writer.status == .writing,
            let writerInput = self.writerInput,
            let adaptor = self.pixelBufferAdaptor,
            writerInput.isReadyForMoreMediaData,
            let start = self.recordingStartHostTime else {
        if self.writer == nil {
          NSLog("[SOPRecorder] Dropping frame because writer was never configured")
        } else if let writer = self.writer {
          NSLog("[SOPRecorder] Dropping frame because writer is not writable (status=%d)", writer.status.rawValue)
        }
        return
      }

      let elapsed = CACurrentMediaTime() - start
      let presentationTime = CMTime(seconds: max(0, elapsed), preferredTimescale: 600)

      guard let pixelBuffer = Self.makePixelBuffer(from: image) else { return }
      let appended = adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
      if appended {
        self.appendedFrameCount += 1
        if self.appendedFrameCount == 1 {
          NSLog("[SOPRecorder] First frame appended successfully")
        } else if self.appendedFrameCount % 60 == 0 {
          NSLog("[SOPRecorder] Appended %d frames", self.appendedFrameCount)
        }
      } else {
        NSLog("[SOPRecorder] Failed appending frame at %.3fs (writer status=%d)", elapsed, writer.status.rawValue)
      }
    }
  }

  func finishRecording() async -> URL? {
    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }

        NSLog(
          "[SOPRecorder] finishRecording called (frames=%d, hasWriter=%@, outputURL=%@)",
          self.appendedFrameCount,
          self.writer == nil ? "no" : "yes",
          self.outputURL?.path ?? "nil")

        guard let writer = self.writer,
              let writerInput = self.writerInput,
              writer.status == .writing else {
          if let writer = self.writer {
            NSLog("[SOPRecorder] finishRecording returning nil because writer status=%d", writer.status.rawValue)
          } else {
            NSLog("[SOPRecorder] finishRecording returning nil because writer was never created")
          }
          continuation.resume(returning: nil)
          return
        }

        self.isFinishing = true
        writerInput.markAsFinished()
        writer.finishWriting {
          NSLog(
            "[SOPRecorder] finishWriting completed (status=%d, outputURL=%@)",
            writer.status.rawValue,
            self.outputURL?.path ?? "nil")
          continuation.resume(returning: writer.status == .completed ? self.outputURL : nil)
        }
      }
    }
  }

  private func configureWriterIfNeeded(for image: UIImage) {
    guard writer == nil else { return }

    let size = Self.normalizedSize(for: image)
    guard size.width > 0, size.height > 0 else {
      NSLog("[SOPRecorder] Invalid normalized size: %@", NSCoder.string(for: size))
      return
    }

    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("sop_\(UUID().uuidString)")
      .appendingPathExtension("mp4")

    try? FileManager.default.removeItem(at: fileURL)

    NSLog("[SOPRecorder] Creating writer at %@ with size %@", fileURL.path, NSCoder.string(for: size))

    guard let writer = try? AVAssetWriter(outputURL: fileURL, fileType: .mp4) else {
      NSLog("[SOPRecorder] Failed to create AVAssetWriter")
      return
    }

    let outputSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 2_500_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
      ]
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = true

    let sourceAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height)
    ]

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourceAttributes)

    guard writer.canAdd(input) else {
      NSLog("[SOPRecorder] Writer cannot add AVAssetWriterInput")
      return
    }
    writer.add(input)

    guard writer.startWriting() else {
      NSLog("[SOPRecorder] startWriting failed: %@", writer.error?.localizedDescription ?? "unknown")
      return
    }
    writer.startSession(atSourceTime: .zero)
    NSLog("[SOPRecorder] Writer started successfully")

    self.writer = writer
    self.writerInput = input
    self.pixelBufferAdaptor = adaptor
    self.recordingStartHostTime = CACurrentMediaTime()
    self.outputURL = fileURL
  }

  private static func normalizedSize(for image: UIImage) -> CGSize {
    var width = max(2, Int(image.size.width.rounded()))
    var height = max(2, Int(image.size.height.rounded()))
    if width % 2 != 0 { width += 1 }
    if height % 2 != 0 { height += 1 }
    return CGSize(width: width, height: height)
  }

  private static func makePixelBuffer(from image: UIImage) -> CVPixelBuffer? {
    guard let cgImage = image.cgImage else { return nil }

    let width = cgImage.width
    let height = cgImage.height
    var pixelBuffer: CVPixelBuffer?

    let attrs: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]

    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32ARGB,
      attrs as CFDictionary,
      &pixelBuffer
    )

    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }

    guard let context = CGContext(
      data: baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ) else {
      return nil
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}

struct ChecklistItemState: Identifiable, Codable, Hashable {
  let id: UUID
  let itemID: String
  let name: String
  let description: String
  let duration: String
  let validation: String
  let critical: Bool
  let aiPrompt: String
  let expectedObjects: [String]
  let allowManualComplete: Bool
  var isChecked: Bool
  var completionSource: ChecklistCompletionSource

  init(
    id: UUID = UUID(),
    itemID: String? = nil,
    name: String,
    description: String = "",
    duration: String = "30s",
    validation: String = "visual",
    critical: Bool = false,
    aiPrompt: String? = nil,
    expectedObjects: [String] = [],
    allowManualComplete: Bool = true,
    isChecked: Bool = false,
    completionSource: ChecklistCompletionSource = .pending
  ) {
    self.id = id
    self.itemID = itemID ?? ChecklistItemState.normalizedItemID(from: name)
    self.name = name
    self.description = description
    self.duration = duration
    self.validation = validation
    self.critical = critical
    self.aiPrompt = aiPrompt ?? "Look at the image and confirm whether \"\(name)\" has been completed."
    self.expectedObjects = expectedObjects
    self.allowManualComplete = allowManualComplete
    self.isChecked = isChecked
    self.completionSource = completionSource
  }

  static func normalizedItemID(from name: String) -> String {
    let lowered = name.lowercased()
    let filtered = lowered.map { ch in
      ch.isLetter || ch.isNumber ? ch : "_"
    }
    let collapsed = String(filtered)
      .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return collapsed.isEmpty ? UUID().uuidString.lowercased() : collapsed
  }
}

private enum WorkerLiveLogger {
  static func log(
    _ event: String,
    sessionID: String? = nil,
    roomCode: String? = nil,
    assetID: String? = nil,
    assetType: String? = nil,
    bucket: String? = nil,
    path: String? = nil,
    byteSize: Int? = nil,
    retryCount: Int? = nil,
    uploadState: String? = nil,
    error: String? = nil
  ) {
    let payload: [String: Any] = [
      "event": event,
      "sessionId": sessionID ?? NSNull(),
      "roomCode": roomCode ?? NSNull(),
      "assetId": assetID ?? NSNull(),
      "assetType": assetType ?? NSNull(),
      "bucket": bucket ?? NSNull(),
      "path": path ?? NSNull(),
      "byteSize": byteSize ?? NSNull(),
      "retryCount": retryCount ?? NSNull(),
      "uploadState": uploadState ?? NSNull(),
      "error": error ?? NSNull()
    ]

    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          let encoded = String(data: data, encoding: .utf8)
    else {
      NSLog("[worker-live] %@", event)
      return
    }

    NSLog("[worker-live] %@", encoded)
  }
}

struct WorkerMediaUploadResult: Equatable {
  let assetType: String
  let assetID: String?
  let bucket: String?
  let path: String?
  let byteSize: Int
  let uploadState: String
  let errorMessage: String?

  var succeeded: Bool {
    uploadState == "uploaded"
  }
}

actor WorkerAdminLiveSessionCoordinator {
  typealias Sleeper = @Sendable (UInt64) async -> Void
  typealias FileLoader = @Sendable (URL) async -> Data?

  private let api: WorkerAdminAPI
  private let heartbeatIntervalNanoseconds: UInt64
  private let sleeper: Sleeper
  private let fileLoader: FileLoader

  private var sessionID: String?
  private var roomCode: String?
  private var currentStepIndex: Int = 0
  private var helpRequested: Bool = false
  private var lastFrameBucket: String?
  private var lastFramePath: String?
  private var heartbeatTask: Task<Void, Never>?
  private var queuedFrameData: Data?
  private var frameUploadTask: Task<Void, Never>?

  init(
    api: WorkerAdminAPI,
    sessionID: String? = nil,
    heartbeatIntervalNanoseconds: UInt64 = 7_000_000_000,
    sleeper: @escaping Sleeper = { nanoseconds in
      guard nanoseconds > 0 else { return }
      try? await Task.sleep(nanoseconds: nanoseconds)
    },
    fileLoader: @escaping FileLoader = { url in
      await Task.detached(priority: .utility) {
        try? Data(contentsOf: url)
      }.value
    }
  ) {
    self.api = api
    self.sessionID = sessionID
    self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
    self.sleeper = sleeper
    self.fileLoader = fileLoader
  }

  func start(
    sessionID: String,
    currentStepIndex: Int,
    helpRequested: Bool,
    roomCode: String? = nil
  ) async {
    self.sessionID = sessionID
    self.currentStepIndex = currentStepIndex
    self.helpRequested = helpRequested
    if let roomCode = Self.trimmed(roomCode) {
      self.roomCode = roomCode
    }

    if heartbeatTask == nil, heartbeatIntervalNanoseconds > 0 {
      heartbeatTask = Task { [heartbeatIntervalNanoseconds] in
        while !Task.isCancelled {
          await self.sleeper(heartbeatIntervalNanoseconds)
          if Task.isCancelled { break }
          await self.sendHeartbeat()
        }
      }
    }

    await sendHeartbeat()
  }

  func updateRoomCode(_ roomCode: String?, sendImmediateHeartbeat: Bool = true) async {
    guard let roomCode = Self.trimmed(roomCode) else { return }
    self.roomCode = roomCode
    if sendImmediateHeartbeat {
      await sendHeartbeat()
    }
  }

  func updateCurrentStepIndex(_ currentStepIndex: Int, sendImmediateHeartbeat: Bool = false) async {
    self.currentStepIndex = currentStepIndex
    if sendImmediateHeartbeat {
      await sendHeartbeat()
    }
  }

  func updateHelpRequested(_ helpRequested: Bool, sendImmediateHeartbeat: Bool = true) async {
    self.helpRequested = helpRequested
    if sendImmediateHeartbeat {
      await sendHeartbeat()
    }
  }

  func enqueueFrameUpload(data: Data) async {
    queuedFrameData = data
    guard frameUploadTask == nil else { return }
    frameUploadTask = Task {
      await self.drainQueuedFrames()
    }
  }

  func uploadVideoRecording(from fileURL: URL?) async -> WorkerMediaUploadResult {
    let byteSize: Int
    let data: Data?
    let missingDataError: String

    if let fileURL {
      data = await fileLoader(fileURL)
      if let data {
        byteSize = data.count
        missingDataError = data.isEmpty ? "Recording file is empty." : "Recording file could not be loaded."
      } else {
        byteSize = 0
        missingDataError = "Recording file could not be loaded."
      }
    } else {
      data = nil
      byteSize = 0
      missingDataError = "Recording file was not created."
    }

    return await uploadAsset(
      assetType: "video",
      filename: "recording.mp4",
      contentType: "video/mp4",
      data: data,
      byteSize: byteSize,
      missingDataError: missingDataError
    )
  }

  func completeSession(
    videoFileURL: URL?,
    onBeforeMarkEnded: () async -> Void
  ) async -> WorkerMediaUploadResult {
    queuedFrameData = nil
    frameUploadTask?.cancel()
    frameUploadTask = nil

    let result = await uploadVideoRecording(from: videoFileURL)
    await sendHeartbeat()
    await onBeforeMarkEnded()

    heartbeatTask?.cancel()
    heartbeatTask = nil
    return result
  }

  func stop() async {
    queuedFrameData = nil
    frameUploadTask?.cancel()
    frameUploadTask = nil
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  private func sendHeartbeat() async {
    guard let sessionID else { return }

    let heartbeat = WorkerLiveHeartbeatRequest(
      sessionID: sessionID,
      webrtcRoomCode: roomCode,
      currentStepIndex: currentStepIndex,
      helpRequested: helpRequested,
      status: "active",
      lastFrameBucket: lastFrameBucket,
      lastFramePath: lastFramePath
    )

    WorkerLiveLogger.log(
      "heartbeat_sent",
      sessionID: sessionID,
      roomCode: roomCode,
      bucket: lastFrameBucket,
      path: lastFramePath,
      uploadState: "active"
    )

    do {
      try await retry(
        sessionID: sessionID,
        roomCode: roomCode,
        assetType: nil,
        bucket: lastFrameBucket,
        path: lastFramePath,
        uploadState: "active"
      ) {
        try await api.sendWorkerLiveHeartbeat(heartbeat)
      }

      WorkerLiveLogger.log(
        "heartbeat_result",
        sessionID: sessionID,
        roomCode: roomCode,
        bucket: lastFrameBucket,
        path: lastFramePath,
        uploadState: "active"
      )
    } catch {
      WorkerLiveLogger.log(
        "heartbeat_result",
        sessionID: sessionID,
        roomCode: roomCode,
        bucket: lastFrameBucket,
        path: lastFramePath,
        uploadState: "active",
        error: error.localizedDescription
      )
    }
  }

  private func drainQueuedFrames() async {
    while !Task.isCancelled {
      guard let frameData = queuedFrameData else { break }
      queuedFrameData = nil

      let result = await uploadAsset(
        assetType: "frame",
        filename: "last-frame.jpg",
        contentType: "image/jpeg",
        data: frameData,
        byteSize: frameData.count,
        missingDataError: "Frame JPEG data was empty."
      )

      if result.succeeded {
        lastFrameBucket = result.bucket
        lastFramePath = result.path
        if !Task.isCancelled {
          await sendHeartbeat()
        }
      }
    }

    frameUploadTask = nil
    if queuedFrameData != nil, !Task.isCancelled {
      frameUploadTask = Task {
        await self.drainQueuedFrames()
      }
    }
  }

  private func uploadAsset(
    assetType: String,
    filename: String,
    contentType: String,
    data: Data?,
    byteSize: Int,
    missingDataError: String
  ) async -> WorkerMediaUploadResult {
    guard let sessionID else {
      return WorkerMediaUploadResult(
        assetType: assetType,
        assetID: nil,
        bucket: nil,
        path: nil,
        byteSize: byteSize,
        uploadState: "failed",
        errorMessage: "Session ID missing."
      )
    }

    let logPrefix = assetType == "frame" ? "frame" : "video"

    do {
      let target = try await retry(
        sessionID: sessionID,
        roomCode: roomCode,
        assetType: assetType,
        byteSize: byteSize,
        uploadState: "pending"
      ) {
        try await api.requestWorkerMediaUploadTarget(
          sessionID: sessionID,
          assetType: assetType,
          filename: filename,
          contentType: contentType,
          byteSize: byteSize
        )
      }

      WorkerLiveLogger.log(
        "\(logPrefix)_upload_target",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "pending"
      )

      guard let data, !data.isEmpty else {
        WorkerLiveLogger.log(
          "\(logPrefix)_upload_failure",
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "failed",
          error: missingDataError
        )
        return await finalizeFailure(
          logPrefix: logPrefix,
          sessionID: sessionID,
          assetType: assetType,
          target: target,
          byteSize: byteSize,
          errorMessage: missingDataError
        )
      }

      do {
        try await retry(
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "pending"
        ) {
          try await api.uploadBinary(to: target, data: data, contentType: contentType)
        }

        WorkerLiveLogger.log(
          "\(logPrefix)_upload_success",
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "pending"
        )

        do {
          try await retry(
            sessionID: sessionID,
            roomCode: roomCode,
            assetID: target.assetID,
            assetType: assetType,
            bucket: target.bucket,
            path: target.path,
            byteSize: byteSize,
            uploadState: "uploaded"
          ) {
            try await api.finalizeWorkerMediaUpload(
              WorkerMediaFinalizeRequest(
                assetID: target.assetID,
                sessionID: sessionID,
                bucket: target.bucket,
                path: target.path,
                status: "uploaded",
                byteSize: byteSize,
                error: nil
              )
            )
          }

          WorkerLiveLogger.log(
            "\(logPrefix)_finalize_success",
            sessionID: sessionID,
            roomCode: roomCode,
            assetID: target.assetID,
            assetType: assetType,
            bucket: target.bucket,
            path: target.path,
            byteSize: byteSize,
            uploadState: "uploaded"
          )

          return WorkerMediaUploadResult(
            assetType: assetType,
            assetID: target.assetID,
            bucket: target.bucket,
            path: target.path,
            byteSize: byteSize,
            uploadState: "uploaded",
            errorMessage: nil
          )
        } catch {
          let finalizeError = "Finalize uploaded failed: \(error.localizedDescription)"
          WorkerLiveLogger.log(
            "\(logPrefix)_finalize_failure",
            sessionID: sessionID,
            roomCode: roomCode,
            assetID: target.assetID,
            assetType: assetType,
            bucket: target.bucket,
            path: target.path,
            byteSize: byteSize,
            uploadState: "uploaded",
            error: finalizeError
          )
          return await finalizeFailure(
            logPrefix: logPrefix,
            sessionID: sessionID,
            assetType: assetType,
            target: target,
            byteSize: byteSize,
            errorMessage: finalizeError
          )
        }
      } catch {
        let uploadError = error.localizedDescription
        WorkerLiveLogger.log(
          "\(logPrefix)_upload_failure",
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: target.assetID,
          assetType: assetType,
          bucket: target.bucket,
          path: target.path,
          byteSize: byteSize,
          uploadState: "failed",
          error: uploadError
        )
        return await finalizeFailure(
          logPrefix: logPrefix,
          sessionID: sessionID,
          assetType: assetType,
          target: target,
          byteSize: byteSize,
          errorMessage: uploadError
        )
      }
    } catch {
      WorkerLiveLogger.log(
        "\(logPrefix)_upload_failure",
        sessionID: sessionID,
        roomCode: roomCode,
        assetType: assetType,
        byteSize: byteSize,
        uploadState: "failed",
        error: error.localizedDescription
      )

      return WorkerMediaUploadResult(
        assetType: assetType,
        assetID: nil,
        bucket: nil,
        path: nil,
        byteSize: byteSize,
        uploadState: "failed",
        errorMessage: error.localizedDescription
      )
    }
  }

  private func finalizeFailure(
    logPrefix: String,
    sessionID: String,
    assetType: String,
    target: WorkerMediaUploadTarget,
    byteSize: Int,
    errorMessage: String
  ) async -> WorkerMediaUploadResult {
    do {
      try await retry(
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "failed"
      ) {
        try await api.finalizeWorkerMediaUpload(
          WorkerMediaFinalizeRequest(
            assetID: target.assetID,
            sessionID: sessionID,
            bucket: target.bucket,
            path: target.path,
            status: "failed",
            byteSize: byteSize,
            error: errorMessage
          )
        )
      }

      WorkerLiveLogger.log(
        "\(logPrefix)_finalize_success",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "failed",
        error: errorMessage
      )
    } catch {
      WorkerLiveLogger.log(
        "\(logPrefix)_finalize_failure",
        sessionID: sessionID,
        roomCode: roomCode,
        assetID: target.assetID,
        assetType: assetType,
        bucket: target.bucket,
        path: target.path,
        byteSize: byteSize,
        uploadState: "failed",
        error: error.localizedDescription
      )
    }

    return WorkerMediaUploadResult(
      assetType: assetType,
      assetID: target.assetID,
      bucket: target.bucket,
      path: target.path,
      byteSize: byteSize,
      uploadState: "failed",
      errorMessage: errorMessage
    )
  }

  private func retry<T>(
    sessionID: String?,
    roomCode: String?,
    assetID: String? = nil,
    assetType: String?,
    bucket: String? = nil,
    path: String? = nil,
    byteSize: Int? = nil,
    uploadState: String? = nil,
    operation: () async throws -> T
  ) async throws -> T {
    let backoffSchedule: [UInt64] = [750_000_000, 1_500_000_000, 3_000_000_000]
    var attempt = 0

    while true {
      do {
        return try await operation()
      } catch {
        guard !Task.isCancelled, attempt < backoffSchedule.count, Self.isTransient(error) else {
          throw error
        }

        let retryCount = attempt + 1
        WorkerLiveLogger.log(
          "retry_scheduled",
          sessionID: sessionID,
          roomCode: roomCode,
          assetID: assetID,
          assetType: assetType,
          bucket: bucket,
          path: path,
          byteSize: byteSize,
          retryCount: retryCount,
          uploadState: uploadState,
          error: error.localizedDescription
        )

        await sleeper(backoffSchedule[attempt])
        attempt += 1
      }
    }
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private static func isTransient(_ error: Error) -> Bool {
    if error is CancellationError {
      return false
    }

    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut,
           .cannotFindHost,
           .cannotConnectToHost,
           .networkConnectionLost,
           .dnsLookupFailed,
           .notConnectedToInternet,
           .resourceUnavailable,
           .dataNotAllowed,
           .callIsActive,
           .internationalRoamingOff:
        return true
      default:
        return false
      }
    }

    if let opsError = error as? OpsAPIError {
      switch opsError {
      case .invalidResponse:
        return true
      case .server(let statusCode, _):
        return [408, 409, 425, 429, 500, 502, 503, 504].contains(statusCode)
      case .notConfigured, .invalidURL, .missingWorkerSession, .missingWorkerBearerToken:
        return false
      }
    }

    return false
  }
}

struct ShippedSessionRecord: Identifiable, Codable {
  let id: UUID
  let timestamp: Date
  let sopName: String
  let status: String

  init(id: UUID = UUID(), timestamp: Date, sopName: String, status: String) {
    self.id = id
    self.timestamp = timestamp
    self.sopName = sopName
    self.status = status
  }

  var timestampText: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter.string(from: timestamp)
  }
}

private struct PendingWorkerRecording: Codable, Equatable {
  let sessionID: String
  let filePath: String
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .low
  @Published var preferredCaptureMode: StreamingMode = .iPhone
  @Published var isSopAuditRunning: Bool = false
  @Published var sopAuditSecondsRemaining: Double = 15.0
  @Published var sopAuditStatusMessage: String = ""
  @Published var selectedSOP: SOPTemplate?
  @Published var checklistItems: [ChecklistItemState] = []
  @Published var shouldDismissCapture: Bool = false
  @Published var showShipSuccessToast: Bool = false
  @Published var isListeningForVoice: Bool = false
  @Published var isDossierUploading: Bool = false
  @Published var dossierPipelineStatusMessage: String = ""
  @Published var dossierPipelineStatusKind: DossierPipelineStatusKind = .info
  @Published var dossierPipelineStatusTimestamp: String = ""
  @Published var dossierSpotterHitCount: Int = 0
  @Published var shippedHistory: [ShippedSessionRecord] = []
  @Published var isSyncingOperations: Bool = false
  @Published var operationsSyncError: String?
  @Published var workerProfile: BackendWorker?
  @Published var registeredDevice: BackendDevice?
  @Published var activeShift: BackendShift?
  @Published var assignedPackages: [BackendAssignedPackage] = []
  @Published var activeExecutionSession: BackendExecutionSession?
  @Published var helpRequestNotes: String = ""
  @Published var helpStatusMessage: String = ""
  @Published var isRequestingHelp: Bool = false
  @Published var packageClosureStatusMessage: String = ""
  @Published var isClosingPackage: Bool = false
  @Published var activeCaptureSOP: SOPTemplate?

  @Published var availableSOPs: [SOPTemplate] = []
  @Published private(set) var locallyCompletedPendingTaskKeys: Set<String> = []

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  var progressText: String {
    "\(checklistItems.filter { $0.isChecked }.count)/\(checklistItems.count)"
  }

  var currentAssignedSOP: SOPTemplate? {
    if let selectedSOP, pendingTaskSOPs.contains(selectedSOP) {
      return selectedSOP
    }
    return pendingTaskSOPs.first
  }

  var workerDisplayName: String {
    if isDemoWorkerMode {
      return "Lucas Pereira"
    }
    return workerProfile?.displayName ?? "Unassigned Worker"
  }

  var workerRoleText: String {
    workerProfile?.role?.uppercased() ?? "WORKER"
  }

  var activePackageTitle: String {
    assignedPackages.first?.title
      ?? activeShift?.package?.title
      ?? currentAssignedSOP?.packageTitle
      ?? "No Active Package"
  }

  var pendingTaskSOPs: [SOPTemplate] {
    availableSOPs
      .sorted { $0.sortOrder < $1.sortOrder }
      .filter { !locallyCompletedPendingTaskKeys.contains(pendingTaskKey(for: $0)) }
  }

  var pendingShiftLabel: String {
    activeShift?.shiftName
      ?? currentAssignedSOP?.shiftName
      ?? "MORNING SHIFT"
  }

  var pendingTaskHeaderSummary: String {
    let count = pendingTaskSOPs.count
    if count == 0 {
      return "ALL PENDING TASKS COMPLETE"
    }
    return "\(count) PENDING TASK\(count == 1 ? "" : "S") · \(selectedCaptureModeLabel)"
  }

  var activeAssignedPackageCount: Int {
    assignedPackages.count
  }

  var currentPackageProgressText: String {
    guard let key = currentPackageCompletionKey, !currentPackageRequiredRemoteIDs.isEmpty else {
      return availableSOPs.isEmpty ? "NO PACKAGE QUEUE" : "\(availableSOPs.count) SOPS QUEUED"
    }

    let completedCount = locallyCompletedSopsByPackageKey[key]?.count ?? 0
    return "\(completedCount)/\(currentPackageRequiredRemoteIDs.count) PACKAGE SOPS COMPLETE"
  }

  var currentSessionSyncLabel: String {
    if let activeExecutionSession {
      return "SESSION \(activeExecutionSession.id.prefix(8))"
    }
    if currentSopSessionId != nil {
      return "LOCAL SESSION"
    }
    return "NOT STARTED"
  }

  var canRequestHelp: Bool {
    isSopAuditRunning
  }

  var canCloseCurrentPackage: Bool {
    guard activePackageRunID != nil else { return false }
    guard let key = currentPackageCompletionKey, !currentPackageRequiredRemoteIDs.isEmpty else { return false }
    let completed = locallyCompletedSopsByPackageKey[key] ?? []
    return Set(currentPackageRequiredRemoteIDs).isSubset(of: completed)
  }

  var selectedCaptureModeLabel: String {
    switch preferredCaptureMode {
    case .glasses: return "META CAMERA"
    case .iPhone: return "IPHONE CAMERA"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Operational backend integration
  private let opsAPIClient = OpsAPIClient()
  private let geminiLiveSpotter = GeminiLiveSpotter()
  let webrtcViewModel = WebRTCSessionViewModel()
  private var workerAdminSync: WorkerAdminLiveSessionCoordinator?
  private var currentSopSessionId: String?
  private var sopCountdownTask: Task<Void, Never>?
  private var sopVideoRecorder: SopVideoRecorder?
  private var proofImagesByTargetID: [String: Data] = [:]
  private var lastSpotterInferenceTime: Date = .distantPast
  private var isSpotterInferenceInFlight = false
  private var isFinalizingAndShipping = false
  private var successToastTask: Task<Void, Never>?
  private var hasLoadedWorkerContext = false
  private var hasEnteredWorkerHome = false
  private var isUsingLocalSessionFallback = false
  private var roomCodeCancellable: AnyCancellable?
  private var connectionStateCancellable: AnyCancellable?
  private var locallyCompletedSopsByPackageKey: [String: Set<String>] = [:]
  private var lastLivePreviewSyncAt: Date = .distantPast
  private var hasActiveHelpEscalation = false
  private var hasLoggedRoomCreatedForSession = false
  private var hasLoggedRoomJoinedForSession = false
  private var didAttemptPendingRecordingRecovery = false

  private var isDemoWorkerMode: Bool {
    let configuredCode = GeminiConfig.workerLoginCode.trimmingCharacters(in: .whitespacesAndNewlines)
    let workerCode = workerProfile?.loginCode?.trimmingCharacters(in: .whitespacesAndNewlines)
    let loginCode = workerCode?.isEmpty == false ? workerCode! : configuredCode
    return loginCode.uppercased() == "EMBC-0001"
  }

  private func pendingTaskKey(for sop: SOPTemplate) -> String {
    [
      sop.shiftID ?? "shift",
      sop.packageRunID ?? sop.packageID ?? "standalone",
      sop.remoteID ?? sop.id.uuidString,
      "\(sop.sortOrder)"
    ].joined(separator: "::")
  }

  // Hold-to-talk speech recognition
  private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private let audioEngine = AVAudioEngine()
  private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
  private var speechTask: SFSpeechRecognitionTask?
  private var lastProcessedTranscript: String = ""

  private var currentPackageCompletionKey: String? {
    if let runID = activePackageRunID {
      return runID
    }
    return currentAssignedSOP?.packageID ?? assignedPackages.first?.id
  }

  private var activePackageRunID: String? {
    currentAssignedSOP?.packageRunID
      ?? assignedPackages.first(where: { $0.id == currentAssignedSOP?.packageID })?.packageRunID
      ?? assignedPackages.first?.packageRunID
  }

  private var currentPackageRequiredRemoteIDs: [String] {
    let packageID = currentAssignedSOP?.packageID ?? assignedPackages.first?.id
    return availableSOPs
      .filter { sop in
        sop.required &&
          sop.packageID == packageID &&
          sop.sourceType == "package"
      }
      .compactMap(\.remoteID)
  }

  private let historyDefaultsKey = "visionclaw.shipped.history.v2"
  private let pendingRecordingDefaultsKey = "visionclaw.pending.worker.recording.v1"
  private static let pipelineTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  // The core DAT SDK StreamSession - handles all streaming operations
  private var streamSession: StreamSession
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var iPhoneCameraManager: IPhoneCameraManager?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
      }
    }

    attachListeners()
    loadHistoryFromDefaults()
    requestSpeechPermissionsIfNeeded()
    observeWebRTCSession()
  }

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: resolution,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
    attachListeners()
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func attachListeners() {
    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        if let image = videoFrame.makeUIImage() {
          self.currentVideoFrame = image
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }

          if self.webrtcViewModel.isActive {
            self.webrtcViewModel.pushVideoFrame(image)
          }

          if self.isSopAuditRunning {
            Task { await self.syncLivePreviewFrameIfNeeded(image: image) }
            self.sopVideoRecorder?.appendFrame(image)
            self.spotChecklistItemsIfThrottled(image: image)
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Suppress device-not-found errors when user hasn't started streaming yet
        if self.streamingStatus == .stopped {
          if case .deviceNotConnected = error { return }
          if case .deviceNotFound = error { return }
        }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    await streamSession.start()
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    if isSopAuditRunning {
      await endAndShip(status: .userEnded)
    } else {
      await workerAdminSync?.stop()
      workerAdminSync = nil
    }

    if webrtcViewModel.isActive {
      webrtcViewModel.stopSession()
    }
    activeCaptureSOP = nil

    if streamingMode == .iPhone {
      stopIPhoneSession()
      return
    }
    await streamSession.stop()
  }

  func beginLiveCapture(for sop: SOPTemplate) async {
    selectedSOP = sop
    activeCaptureSOP = sop
    configureChecklist(for: sop)
    showShipSuccessToast = false
    shouldDismissCapture = false
    sopAuditStatusMessage = ""
    helpStatusMessage = ""

    if !hasLoadedWorkerContext {
      await loadWorkerContextIfNeeded()
    }

    if !isStreaming {
      await startPreferredCamera()
    }

    guard isStreaming else { return }

    await startSopAudit(for: sop)
  }

  func selectCaptureMode(_ mode: StreamingMode) {
    guard mode != .glasses || hasActiveDevice else {
      sopAuditStatusMessage = "Meta camera not connected."
      return
    }
    preferredCaptureMode = mode
    if webrtcViewModel.isActive {
      do {
        if let routeWarning = try configureWorkerAudioRoute(for: mode, reason: .viewer) {
          helpStatusMessage = routeWarning
        }
      } catch {
        helpStatusMessage = "Audio route update failed: \(error.localizedDescription)"
      }
    }
  }

  func presentCapture(for sop: SOPTemplate) {
    selectedSOP = sop
    activeCaptureSOP = sop
    shouldDismissCapture = false
  }

  func handleWorkerHomeEntered() async {
    if !hasLoadedWorkerContext {
      await loadWorkerContextIfNeeded()
    }

    guard !hasEnteredWorkerHome else { return }
    hasEnteredWorkerHome = true
    await resetDemoShiftForHomeIfNeeded(reloadAssignments: false)
  }

  func handleWorkerAppBecameActive() async {
    guard hasEnteredWorkerHome else { return }
    guard !isSopAuditRunning, activeCaptureSOP == nil else { return }
    await resetDemoShiftForHomeIfNeeded(reloadAssignments: true)
  }

  func restoreActiveCaptureIfNeeded() {
    guard activeCaptureSOP == nil else { return }
    guard isSopAuditRunning else { return }
    if let activeSOP = selectedSOP ?? currentAssignedSOP {
      activeCaptureSOP = activeSOP
    }
  }

  func switchToPreferredCaptureModeIfNeeded() async {
    guard let _ = selectedSOP else { return }

    if preferredCaptureMode == .glasses, !hasActiveDevice {
      sopAuditStatusMessage = "Meta camera not connected."
      return
    }

    if isStreaming && streamingMode == preferredCaptureMode {
      return
    }

    await stopCurrentCameraTransportOnly()
    await startPreferredCamera()
  }

  func loadWorkerContextIfNeeded() async {
    guard !hasLoadedWorkerContext else { return }
    await refreshWorkerContext()
  }

  func refreshWorkerContext() async {
    guard GeminiConfig.isOpsConfigured else {
      operationsSyncError = "Set the ops-api URL in Settings to load assignments."
      return
    }

    let loginCode = GeminiConfig.workerLoginCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !loginCode.isEmpty else {
      operationsSyncError = "Set a worker login code in Settings to bootstrap assignments."
      return
    }

    isSyncingOperations = true
    operationsSyncError = nil
    packageClosureStatusMessage = ""
    defer { isSyncingOperations = false }

    do {
      let payload = try await opsAPIClient.bootstrap(
        loginCode: loginCode,
        platform: "ios",
        label: UIDevice.current.name
      )

      workerProfile = payload.worker
      registeredDevice = payload.device
      activeShift = payload.shift
      let canonicalLucasTemplates = lucasDemoQueueTemplates()
      let resolvedQueue = canonicalLucasQueue(from: payload.queue)
      assignedPackages =
        payload.assignedPackages.isEmpty
        ? deriveAssignedPackages(from: resolvedQueue, canonicalTemplates: canonicalLucasTemplates)
        : payload.assignedPackages
      availableSOPs = resolvedQueue.map { hydrateQueueItem($0, canonicalTemplates: canonicalLucasTemplates) }
      if selectedSOP == nil || !pendingTaskSOPs.contains(selectedSOP!) {
        selectedSOP = pendingTaskSOPs.first
      }
      hasLoadedWorkerContext = true

      if availableSOPs.isEmpty {
        if isDemoWorkerMode {
          applyLucasDemoWorkerFallback(reason: "No remote SOPs were assigned yet. Using the local Lucas demo queue.")
        } else {
          operationsSyncError = "No SOPs assigned to this worker yet."
        }
      }

      await recoverPendingWorkerRecordingIfNeeded()
    } catch {
      if isDemoWorkerMode {
        applyLucasDemoWorkerFallback(
          reason: "Assignment sync failed: \(error.localizedDescription). Using the local Lucas demo queue."
        )
        hasLoadedWorkerContext = true
      } else {
        operationsSyncError = "Assignment sync failed: \(error.localizedDescription)"
      }
    }
  }

  private func canonicalLucasQueue(from queue: [WorkerQueueItem]) -> [WorkerQueueItem] {
    var seen = Set<String>()
    return queue
      .sorted { lhs, rhs in
        let leftOrder = lhs.sortOrder == 0 ? lucasCanonicalOrder(for: lhs.sopID) : lhs.sortOrder
        let rightOrder = rhs.sortOrder == 0 ? lucasCanonicalOrder(for: rhs.sopID) : rhs.sortOrder
        if leftOrder == rightOrder {
          return lhs.sopTitle < rhs.sopTitle
        }
        return leftOrder < rightOrder
      }
      .filter { item in
        let key = item.sopID.lowercased()
        guard !seen.contains(key) else { return false }
        seen.insert(key)
        return true
      }
  }

  private func hydrateQueueItem(
    _ queueItem: WorkerQueueItem,
    canonicalTemplates: [SOPTemplate]
  ) -> SOPTemplate {
    let canonical = canonicalTemplates.first { template in
      template.name.caseInsensitiveCompare(queueItem.sopTitle) == .orderedSame
    }

    let stepTemplates: [SOPStepTemplate]
    if queueItem.steps.isEmpty {
      stepTemplates = canonical?.steps ?? []
    } else {
      stepTemplates = queueItem.steps.enumerated().map { index, step in
        SOPStepTemplate(
          id: step.id,
          order: step.order == 0 ? index + 1 : step.order,
          title: step.title,
          description: step.description,
          duration: step.duration,
          validation: step.validation,
          critical: step.critical,
          aiPrompt: step.aiPrompt,
          expectedObjects: step.expectedObjects,
          allowManualComplete: step.allowManualComplete
        )
      }
    }

    let resolvedSortOrder = canonical?.sortOrder ?? (queueItem.sortOrder == 0 ? lucasCanonicalOrder(for: queueItem.sopID) : queueItem.sortOrder)
    let resolvedShiftName = queueItem.shiftName ?? canonical?.shiftName ?? "Morning"
    let resolvedPackageTitle = queueItem.packageTitle ?? canonical?.packageTitle
    let resolvedPackageVersion = queueItem.packageVersion ?? canonical?.packageVersion
    let resolvedSopVersion = queueItem.sopVersion ?? canonical?.sopVersion
    let resolvedSourceType =
      queueItem.packageID == nil && canonical?.packageID != nil
      ? canonical?.sourceType ?? queueItem.sourceType
      : queueItem.sourceType

    return SOPTemplate(
      id: UUID(uuidString: queueItem.sopID) ?? canonical?.id ?? UUID(),
      remoteID: queueItem.sopID,
      name: canonical?.name ?? queueItem.sopTitle,
      steps: stepTemplates,
      estimatedDuration: canonical?.estimatedDuration ?? max(Double(max(stepTemplates.count, 1)) * 18.0, 18.0),
      shiftID: validRemoteUUID(queueItem.shiftAssignmentID),
      shiftName: resolvedShiftName,
      packageID: queueItem.packageID ?? canonical?.packageID,
      packageRunID: queueItem.packageRunID ?? canonical?.packageRunID,
      packageTitle: resolvedPackageTitle,
      packageVersion: resolvedPackageVersion,
      sopVersion: resolvedSopVersion,
      sourceType: resolvedSourceType,
      sortOrder: resolvedSortOrder,
      required: queueItem.required
    )
  }

  private func deriveAssignedPackages(
    from queue: [WorkerQueueItem],
    canonicalTemplates: [SOPTemplate]
  ) -> [BackendAssignedPackage] {
    var resolved: [String: BackendAssignedPackage] = [:]

    for item in queue {
      guard let packageID = item.packageID else { continue }
      let matchingTemplate = canonicalTemplates.first { template in
        template.name.caseInsensitiveCompare(item.sopTitle) == .orderedSame
      }
      resolved[packageID] = BackendAssignedPackage(
        id: packageID,
        title: item.packageTitle ?? matchingTemplate?.packageTitle ?? "Assigned Package",
        description: nil,
        outcome: nil,
        version: item.packageVersion ?? matchingTemplate?.packageVersion,
        shiftName: item.shiftName ?? matchingTemplate?.shiftName ?? "Morning",
        active: item.active ?? true,
        packageRunID: item.packageRunID,
        packageRunStatus: nil,
        packageRunStartedAt: item.startsAt,
        packageRunCompletedAt: item.endsAt
      )
    }

    return resolved.values.sorted { lhs, rhs in
      let leftOrder = lucasCanonicalPackageOrder(for: lhs.title)
      let rightOrder = lucasCanonicalPackageOrder(for: rhs.title)
      if leftOrder == rightOrder {
        return lhs.title < rhs.title
      }
      return leftOrder < rightOrder
    }
  }

  private func lucasCanonicalOrder(for sopID: String) -> Int {
    switch sopID {
    case "22222222-2222-2222-2222-222222222222":
      return 1
    case "a1000001-0000-0000-0000-000000000001":
      return 2
    case "a1000002-0000-0000-0000-000000000002":
      return 3
    case "a1000003-0000-0000-0000-000000000003":
      return 4
    default:
      return 99
    }
  }

  private func lucasCanonicalPackageOrder(for packageTitle: String) -> Int {
    switch packageTitle {
    case "Inbound Cold Chain Audit":
      return 1
    case "QSR Value Meal Order":
      return 2
    default:
      return 99
    }
  }

  private func applyLucasDemoWorkerFallback(reason: String) {
    workerProfile = BackendWorker(
      id: "worker-lucas",
      loginCode: "EMBC-0001",
      displayName: "Lucas Pereira",
      role: "Kitchen Staff",
      status: "active"
    )

    let inboundPackage = BackendAssignedPackage(
      id: "33333333-3333-3333-3333-333333333333",
      title: "Inbound Cold Chain Audit",
      description: "Verify cold-chain compliance for inbound product before storing.",
      outcome: "Cold Chain Verified",
      version: 2,
      shiftName: "Morning",
      active: true,
      packageRunID: nil,
      packageRunStatus: nil,
      packageRunStartedAt: nil,
      packageRunCompletedAt: nil
    )

    let mealPackage = BackendAssignedPackage(
      id: "b2000001-0000-0000-0000-000000000001",
      title: "QSR Value Meal Order",
      description: "Standard meal execution from assembly to drink handoff.",
      outcome: "Order Fulfilled",
      version: 2,
      shiftName: "Morning",
      active: true,
      packageRunID: nil,
      packageRunStatus: nil,
      packageRunStartedAt: nil,
      packageRunCompletedAt: nil
    )

    let shiftPackage = BackendPackage(
      id: inboundPackage.id,
      title: inboundPackage.title,
      description: inboundPackage.description,
      outcome: inboundPackage.outcome,
      version: inboundPackage.version,
      status: "active"
    )

    activeShift = BackendShift(
      id: "shift-lucas-morning",
      packageID: inboundPackage.id,
      shiftName: "Morning",
      startsAt: nil,
      endsAt: nil,
      active: true,
      package: shiftPackage
    )

    assignedPackages = [inboundPackage, mealPackage]
    availableSOPs = lucasDemoQueueTemplates()
    selectedSOP = pendingTaskSOPs.first
    operationsSyncError = reason
  }

  private func lucasDemoQueueTemplates() -> [SOPTemplate] {
    [
      SOPTemplate(
        remoteID: "22222222-2222-2222-2222-222222222222",
        name: "Cold Chain Verification SOP",
        steps: [
          SOPStepTemplate(
            id: "inspect_packaging_seal",
            order: 1,
            title: "Inspect packaging seal",
            description: "Check the inbound package seal before accepting the delivery.",
            duration: "30s",
            validation: "visual",
            critical: true,
            aiPrompt: "Look at the image and confirm whether the operator inspected the package seal before accepting the delivery.",
            expectedObjects: ["seal", "package"],
            allowManualComplete: true
          ),
          SOPStepTemplate(
            id: "record_temperature_log",
            order: 2,
            title: "Record temperature log",
            description: "Read the temperature and confirm it is entered into the log.",
            duration: "30s",
            validation: "visual",
            critical: false,
            aiPrompt: "Look at the image and confirm whether the operator recorded the product temperature in the log.",
            expectedObjects: ["thermometer", "clipboard"],
            allowManualComplete: true
          ),
          SOPStepTemplate(
            id: "verify_lot_number",
            order: 3,
            title: "Verify lot number",
            description: "Confirm the lot number is visible and matches the manifest.",
            duration: "30s",
            validation: "visual",
            critical: false,
            aiPrompt: "Look at the image and confirm whether the operator verified the lot number on the inbound package.",
            expectedObjects: ["label", "lot"],
            allowManualComplete: true
          ),
          SOPStepTemplate(
            id: "sign_off",
            order: 4,
            title: "Sign off",
            description: "Acknowledge the cold-chain verification and release storage.",
            duration: "30s",
            validation: "tap",
            critical: false,
            aiPrompt: "Look at the image and confirm whether the cold-chain verification was signed off.",
            expectedObjects: ["clipboard", "signature"],
            allowManualComplete: true
          ),
        ],
        estimatedDuration: 72,
        shiftID: nil,
        shiftName: "Morning",
        packageID: "33333333-3333-3333-3333-333333333333",
        packageTitle: "Inbound Cold Chain Audit",
        packageVersion: 2,
        sopVersion: 1,
        sourceType: "package",
        sortOrder: 1,
        required: true
      ),
      SOPTemplate(
        remoteID: "a1000001-0000-0000-0000-000000000001",
        name: "Burger Assembly",
        steps: [
          SOPStepTemplate(id: "toast_the_bun", order: 1, title: "Toast the bun", description: "Place bun halves on the grill until golden.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the bun has been toasted.", expectedObjects: ["bun"], allowManualComplete: true),
          SOPStepTemplate(id: "place_patty_on_grill", order: 2, title: "Place patty on grill", description: "Place the patty on the grill and season as needed.", duration: "30s", validation: "visual", critical: true, aiPrompt: "Look at the image and confirm whether the patty was placed on the grill.", expectedObjects: ["patty", "grill"], allowManualComplete: true),
          SOPStepTemplate(id: "add_cheese_slice", order: 3, title: "Add cheese slice", description: "Place cheese slice on the patty before removal.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether a cheese slice was added to the patty.", expectedObjects: ["cheese", "patty"], allowManualComplete: true),
          SOPStepTemplate(id: "apply_condiments", order: 4, title: "Apply condiments", description: "Apply standard condiments to the bottom bun.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether condiments were applied to the bun.", expectedObjects: ["bun", "condiments"], allowManualComplete: true),
          SOPStepTemplate(id: "stack_ingredients", order: 5, title: "Stack ingredients", description: "Assemble ingredients in the correct order.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the burger ingredients were stacked in the correct order.", expectedObjects: ["bun", "patty", "lettuce"], allowManualComplete: true),
          SOPStepTemplate(id: "quality_check", order: 6, title: "Quality check", description: "Confirm finished burger matches the reference build.", duration: "30s", validation: "visual", critical: true, aiPrompt: "Look at the image and confirm whether the finished burger matches the reference build.", expectedObjects: ["burger"], allowManualComplete: true),
        ],
        estimatedDuration: 108,
        shiftID: nil,
        shiftName: "Morning",
        packageID: "b2000001-0000-0000-0000-000000000001",
        packageTitle: "QSR Value Meal Order",
        packageVersion: 2,
        sopVersion: 2,
        sourceType: "package",
        sortOrder: 2,
        required: true
      ),
      SOPTemplate(
        remoteID: "a1000002-0000-0000-0000-000000000002",
        name: "Fries Assembly",
        steps: [
          SOPStepTemplate(id: "load_fry_basket", order: 1, title: "Load fry basket", description: "Fill the basket to the correct portion.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the fry basket was loaded to the correct portion.", expectedObjects: ["basket", "fries"], allowManualComplete: true),
          SOPStepTemplate(id: "cook_fries", order: 2, title: "Cook fries", description: "Start the fryer and monitor the timer.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the fries are cooking in the fryer.", expectedObjects: ["fryer", "basket"], allowManualComplete: true),
          SOPStepTemplate(id: "drain_and_salt", order: 3, title: "Drain and salt", description: "Drain basket and season fries.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the fries were drained and salted.", expectedObjects: ["fries", "salt"], allowManualComplete: true),
          SOPStepTemplate(id: "bag_fries", order: 4, title: "Bag fries", description: "Transfer fries into the correct serving container.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the fries were transferred into the serving container.", expectedObjects: ["fries", "container"], allowManualComplete: true),
        ],
        estimatedDuration: 72,
        shiftID: nil,
        shiftName: "Morning",
        packageID: "b2000001-0000-0000-0000-000000000001",
        packageTitle: "QSR Value Meal Order",
        packageVersion: 2,
        sopVersion: 2,
        sourceType: "package",
        sortOrder: 3,
        required: true
      ),
      SOPTemplate(
        remoteID: "a1000003-0000-0000-0000-000000000003",
        name: "Drink Prep",
        steps: [
          SOPStepTemplate(id: "select_cup_size", order: 1, title: "Select cup size", description: "Choose the cup size that matches the ticket.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the correct cup size was selected.", expectedObjects: ["cup"], allowManualComplete: true),
          SOPStepTemplate(id: "fill_beverage", order: 2, title: "Fill beverage", description: "Dispense the beverage to the marked fill line.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the beverage was filled to the marked line.", expectedObjects: ["cup", "drink"], allowManualComplete: true),
          SOPStepTemplate(id: "add_lid_and_straw", order: 3, title: "Add lid and straw", description: "Seal the cup and attach the straw.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the lid and straw were added to the drink.", expectedObjects: ["lid", "straw"], allowManualComplete: true),
          SOPStepTemplate(id: "stage_for_pickup", order: 4, title: "Stage for pickup", description: "Place the drink in the order hand-off zone.", duration: "30s", validation: "visual", critical: false, aiPrompt: "Look at the image and confirm whether the drink was staged for pickup.", expectedObjects: ["cup", "handoff"], allowManualComplete: true),
        ],
        estimatedDuration: 72,
        shiftID: nil,
        shiftName: "Morning",
        packageID: "b2000001-0000-0000-0000-000000000001",
        packageTitle: "QSR Value Meal Order",
        packageVersion: 2,
        sopVersion: 1,
        sourceType: "package",
        sortOrder: 4,
        required: true
      ),
    ]
  }

  func startSopAudit(for sop: SOPTemplate) async {
    guard !isSopAuditRunning else { return }

    let sessionId = await createOrFallbackSessionID(for: sop)
    await workerAdminSync?.stop()
    workerAdminSync = WorkerAdminLiveSessionCoordinator(api: opsAPIClient)
    currentSopSessionId = sessionId
    activeCaptureSOP = sop
    isSopAuditRunning = true
    sopAuditSecondsRemaining = sop.estimatedDuration
    sopAuditStatusMessage = ""
    proofImagesByTargetID = [:]
    lastLivePreviewSyncAt = .distantPast
    hasLoggedRoomCreatedForSession = false
    hasLoggedRoomJoinedForSession = false
    if streamingMode == .iPhone {
      sopVideoRecorder = nil
    } else {
      sopVideoRecorder = SopVideoRecorder()
    }
    isDossierUploading = false
    dossierSpotterHitCount = 0
    updateDossierPipelineStatus("Recording execution...", kind: .info)
    lastSpotterInferenceTime = .distantPast
    isSpotterInferenceInFlight = false
    isFinalizingAndShipping = false
    lastProcessedTranscript = ""
    helpStatusMessage = ""
    hasActiveHelpEscalation = false
    packageClosureStatusMessage = ""
    operationsSyncError = nil

    WorkerLiveLogger.log(
      "session_start",
      sessionID: sessionId,
      roomCode: webrtcViewModel.roomCode.isEmpty ? nil : webrtcViewModel.roomCode,
      uploadState: "active"
    )
    await workerAdminSync?.start(
      sessionID: sessionId,
      currentStepIndex: nextIncompleteStepIndex(),
      helpRequested: false,
      roomCode: webrtcViewModel.roomCode
    )

    do {
      if let routeWarning = try configureWorkerAudioRoute(for: preferredCaptureMode, reason: .viewer) {
        helpStatusMessage = routeWarning
      }
    } catch {
      helpStatusMessage = "Audio route error: \(error.localizedDescription)"
    }

    if streamingMode == .iPhone {
      iPhoneCameraManager?.startRecording(sessionID: sessionId)
      rememberPendingRecording(sessionID: sessionId, fileURL: expectedIPhoneRecordingURL(for: sessionId))
    }

    await ensureLiveRoomSession()

    // No countdown/auto-timeout for long SOP runs.
    sopCountdownTask?.cancel()
    sopCountdownTask = nil
  }

  func startSopAudit() {
    let sop = selectedSOP ?? pendingTaskSOPs.first ?? availableSOPs.first ?? SOPTemplate(name: "Wallet & Thermos", items: ["Wallet", "Thermos"])
    selectedSOP = sop
    configureChecklist(for: sop)
    Task { await startSopAudit(for: sop) }
  }

  func toggleChecklistItem(itemID: UUID, viaVoice: Bool) {
    guard let index = checklistItems.firstIndex(where: { $0.id == itemID }) else { return }
    if !checklistItems[index].allowManualComplete && !checklistItems[index].isChecked && !viaVoice {
      sopAuditStatusMessage = "This step completes through visual AI only."
      return
    }

    checklistItems[index].isChecked.toggle()
    checklistItems[index].completionSource = checklistItems[index].isChecked
      ? (viaVoice ? .voice : .manual)
      : .pending

    let item = checklistItems[index]
    Task {
      await handleChecklistMutation(
        item: item,
        stepIndex: index,
        eventType: item.isChecked ? "step_complete" : "step_reopened"
      )
    }

    if checklistItems.allSatisfy({ $0.isChecked }) {
      Task { await endAndShip(status: .allItemsChecked) }
    }
  }

  func userTappedEndAndShip() {
    Task { await endAndShip(status: .userEnded) }
  }

  func requestSupervisorHelp() {
    Task { await requestSupervisorHelpFlow() }
  }

  func closeCurrentPackage() {
    Task { await closeCurrentPackageFlow() }
  }

  func closeSupervisorRoom() {
    webrtcViewModel.stopSession()
    helpStatusMessage = "Supervisor room closed."
    hasActiveHelpEscalation = false
    Task { @MainActor in
      await workerAdminSync?.updateHelpRequested(false)
      await patchActiveExecutionSession(
        ExecutionSessionPatch(
          helpRequested: false
        )
      )
    }
  }

  func clearCaptureDismissFlag() {
    shouldDismissCapture = false
  }

  private func recordPackageProgressIfNeeded(for sop: SOPTemplate) {
    guard sop.sourceType == "package" else { return }
    guard let completionKey = sop.packageRunID ?? sop.packageID else { return }
    guard let remoteSOPID = sop.remoteID else { return }

    var completed = locallyCompletedSopsByPackageKey[completionKey] ?? []
    completed.insert(remoteSOPID)
    locallyCompletedSopsByPackageKey[completionKey] = completed
  }

  private func markPendingTaskComplete(_ sop: SOPTemplate) {
    locallyCompletedPendingTaskKeys.insert(pendingTaskKey(for: sop))
  }

  private func resetDemoShiftForHomeIfNeeded(reloadAssignments: Bool) async {
    guard isDemoWorkerMode else { return }
    guard !isSopAuditRunning, activeCaptureSOP == nil else { return }

    locallyCompletedPendingTaskKeys = []
    selectedSOP = nil
    shouldDismissCapture = false
    helpStatusMessage = ""
    packageClosureStatusMessage = ""

    if reloadAssignments, hasLoadedWorkerContext {
      await refreshWorkerContext()
    }
  }

  func endAndShip(status: SopTerminationStatus, cancelCountdownTask: Bool = true) async {
    guard !isFinalizingAndShipping, isSopAuditRunning, currentSopSessionId != nil else { return }
    isFinalizingAndShipping = true
    stopHoldToTalk()
    let sessionID = currentSopSessionId
    let syncedToBackend = activeExecutionSession != nil
    let completedSOP = selectedSOP
    let roomCodeAtEnd = webrtcViewModel.roomCode.isEmpty ? nil : webrtcViewModel.roomCode

    WorkerLiveLogger.log(
      "session_end_requested",
      sessionID: sessionID,
      roomCode: roomCodeAtEnd,
      uploadState: "active"
    )

    isSopAuditRunning = false
    isDossierUploading = true
    updateDossierPipelineStatus("Finalizing session media...", kind: .active)
    if cancelCountdownTask {
      sopCountdownTask?.cancel()
    }
    sopCountdownTask = nil

    var recordedVideoURL: URL?
    if streamingMode == .iPhone {
      recordedVideoURL = await iPhoneCameraManager?.stopRecording()
      stopIPhoneSession()
    } else {
      await streamSession.stop()
      if let videoRecorder = sopVideoRecorder {
        recordedVideoURL = await videoRecorder.finishRecording()
      }
    }

    let proofImages = proofImagesByTargetID
    sopVideoRecorder = nil
    proofImagesByTargetID = [:]
    let checklistPayload: [[String: Any]] = checklistItems.map {
      [
        "name": $0.name,
        "checked": $0.isChecked,
        "source": $0.completionSource.rawValue
      ]
    }
    let completedCount = checklistItems.filter(\.isChecked).count
    let finalStepIndex = nextIncompleteStepIndex()

    await workerAdminSync?.updateCurrentStepIndex(finalStepIndex)
    await workerAdminSync?.updateHelpRequested(false, sendImmediateHeartbeat: false)

    let videoUploadResult: WorkerMediaUploadResult
    if let workerAdminSync {
      videoUploadResult = await workerAdminSync.completeSession(videoFileURL: recordedVideoURL) { [weak self] in
        guard let self else { return }

        if activeExecutionSession != nil {
          await self.postExecutionEvent(
            type: "session_completed",
            payload: [
              "termination_status": status.rawValue,
              "completed_steps": completedCount,
              "total_steps": self.checklistItems.count,
              "checklist": checklistPayload
            ]
          )

          await self.patchActiveExecutionSession(
            ExecutionSessionPatch(
              status: status == .allItemsChecked ? "completed" : "ended",
              currentSopID: self.selectedSOP?.remoteID,
              currentStepIndex: finalStepIndex,
              helpRequested: false,
              endedAt: ISO8601DateFormatter().string(from: Date())
            )
          )
        } else if recordedVideoURL == nil {
          self.updateDossierPipelineStatus("Execution ended locally. No backend session was active.", kind: .info)
        }
      }
    } else {
      videoUploadResult = WorkerMediaUploadResult(
        assetType: "video",
        assetID: nil,
        bucket: nil,
        path: nil,
        byteSize: 0,
        uploadState: "failed",
        errorMessage: "Worker admin sync was unavailable during teardown."
      )

      if activeExecutionSession != nil {
        await postExecutionEvent(
          type: "session_completed",
          payload: [
            "termination_status": status.rawValue,
            "completed_steps": completedCount,
            "total_steps": checklistItems.count,
            "checklist": checklistPayload
          ]
        )

        await patchActiveExecutionSession(
          ExecutionSessionPatch(
            status: status == .allItemsChecked ? "completed" : "ended",
            currentSopID: selectedSOP?.remoteID,
            currentStepIndex: finalStepIndex,
            helpRequested: false,
            endedAt: ISO8601DateFormatter().string(from: Date())
          )
        )
      } else if recordedVideoURL == nil {
        updateDossierPipelineStatus("Execution ended locally. No backend session was active.", kind: .info)
      }
    }

    if let activeExecutionSession {
      if let remoteSOPID = completedSOP?.remoteID {
        await createExecutionMemoryLink(
          sessionID: activeExecutionSession.id,
          sopID: remoteSOPID,
          completedSteps: completedCount
        )
      }
      await uploadEvidenceMediaAssets(
        sessionID: activeExecutionSession.id,
        proofImages: proofImages
      )
    }

    if status == .allItemsChecked, let completedSOP {
      recordPackageProgressIfNeeded(for: completedSOP)
    }

    if let completedSOP {
      markPendingTaskComplete(completedSOP)
    }

    if videoUploadResult.succeeded {
      clearPendingRecording()
    } else if let recordedVideoURL, let sessionID {
      rememberPendingRecording(sessionID: sessionID, fileURL: recordedVideoURL)
      didAttemptPendingRecordingRecovery = false
    }

    if let recordedVideoURL, videoUploadResult.succeeded {
      try? FileManager.default.removeItem(at: recordedVideoURL)
    }

    if !videoUploadResult.succeeded {
      let errorMessage = videoUploadResult.errorMessage ?? "Video finalize failed."
      operationsSyncError = "Session recording finalize failed: \(errorMessage)"
      updateDossierPipelineStatus("Session recording finalize failed.", kind: .error)
    } else {
      updateDossierPipelineStatus("Session recording finalized.", kind: .success)
    }

    isDossierUploading = false

    appendHistoryRecord(
      ShippedSessionRecord(
        timestamp: Date(),
        sopName: completedSOP?.name ?? "Unknown SOP",
        status: videoUploadResult.succeeded ? "Replay ready" : "Finalize failed"
      )
    )

    if let sessionID {
      WorkerLiveLogger.log(
        "session_end_completed",
        sessionID: sessionID,
        roomCode: roomCodeAtEnd,
        assetID: videoUploadResult.assetID,
        assetType: videoUploadResult.assetType,
        bucket: videoUploadResult.bucket,
        path: videoUploadResult.path,
        byteSize: videoUploadResult.byteSize,
        uploadState: videoUploadResult.uploadState,
        error: videoUploadResult.errorMessage
      )
    }

    if webrtcViewModel.isActive {
      webrtcViewModel.stopSession()
    }
    await workerAdminSync?.stop()
    workerAdminSync = nil

    hasActiveHelpEscalation = false
    activeExecutionSession = nil
    currentSopSessionId = nil
    activeCaptureSOP = nil
    selectedSOP = nil
    sopAuditSecondsRemaining = 0.0
    if canCloseCurrentPackage {
      packageClosureStatusMessage = "All required SOPs are complete. Close the package from NOW."
    }
    sopAuditStatusMessage = videoUploadResult.succeeded
      ? (syncedToBackend ? "Execution synced" : "Execution uploaded")
      : "Execution ended with media finalize issues"
    isSpotterInferenceInFlight = false
    shouldDismissCapture = true
    showShipSuccessToast = true
    successToastTask?.cancel()
    successToastTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      self?.showShipSuccessToast = false
    }
    isFinalizingAndShipping = false
  }

  // MARK: - iPhone Camera Mode

  func handleStartIPhone() async {
    let granted = await IPhoneCameraManager.requestPermission()
    if granted {
      startIPhoneSession()
    } else {
      showError("Camera permission denied. Please grant access in Settings.")
    }
  }

  private func startIPhoneSession() {
    streamingMode = .iPhone
    let camera = IPhoneCameraManager()
    camera.onFrameCaptured = { [weak self] image in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentVideoFrame = image
        if !self.hasReceivedFirstFrame {
          self.hasReceivedFirstFrame = true
        }
        if self.webrtcViewModel.isActive {
          self.webrtcViewModel.pushVideoFrame(image)
        }
        if self.isSopAuditRunning {
          Task { await self.syncLivePreviewFrameIfNeeded(image: image) }
          self.sopVideoRecorder?.appendFrame(image)
          self.spotChecklistItemsIfThrottled(image: image)
        }
      }
    }
    camera.start()
    iPhoneCameraManager = camera
    streamingStatus = .streaming
    NSLog("[Stream] iPhone camera mode started")
  }

  private func observeWebRTCSession() {
    roomCodeCancellable = webrtcViewModel.$roomCode
      .removeDuplicates()
      .sink { [weak self] roomCode in
        guard let self else { return }
        Task { @MainActor [weak self] in
          guard let self else { return }
          if !roomCode.isEmpty, !self.hasLoggedRoomCreatedForSession {
            self.hasLoggedRoomCreatedForSession = true
            WorkerLiveLogger.log(
              "room_created",
              sessionID: self.currentSopSessionId,
              roomCode: roomCode,
              uploadState: "active"
            )
          }
          await self.syncLiveRoomState(roomCode: roomCode)
        }
      }

    connectionStateCancellable = webrtcViewModel.$connectionState
      .removeDuplicates { lhs, rhs in
        String(describing: lhs) == String(describing: rhs)
      }
      .sink { [weak self] state in
        guard let self else { return }
        Task { @MainActor [weak self] in
          self?.updateHelpStatus(for: state)
        }
      }
  }

  private func stopIPhoneSession() {
    sopCountdownTask?.cancel()
    sopCountdownTask = nil
    isSopAuditRunning = false
    isSpotterInferenceInFlight = false
    stopHoldToTalk()

    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    streamingMode = .glasses
    NSLog("[Stream] iPhone camera mode stopped")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    streamSession.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .audioStreamingError:
      return "Audio streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }

  private func configureChecklist(for sop: SOPTemplate) {
    checklistItems = sop.steps
      .sorted { $0.order < $1.order }
      .map { step in
      ChecklistItemState(
        itemID: step.id,
        name: step.title,
        description: step.description,
        duration: step.duration,
        validation: step.validation,
        critical: step.critical,
        aiPrompt: step.aiPrompt,
        expectedObjects: step.expectedObjects,
        allowManualComplete: step.allowManualComplete
      )
    }
  }

  private func appendHistoryRecord(_ record: ShippedSessionRecord) {
    shippedHistory.insert(record, at: 0)
    if shippedHistory.count > 100 {
      shippedHistory = Array(shippedHistory.prefix(100))
    }
    saveHistoryToDefaults()
  }

  private func loadHistoryFromDefaults() {
    guard let data = UserDefaults.standard.data(forKey: historyDefaultsKey) else { return }
    guard let decoded = try? JSONDecoder().decode([ShippedSessionRecord].self, from: data) else { return }
    shippedHistory = decoded
  }

  private func saveHistoryToDefaults() {
    guard let encoded = try? JSONEncoder().encode(shippedHistory) else { return }
    UserDefaults.standard.set(encoded, forKey: historyDefaultsKey)
  }

  private func rememberPendingRecording(sessionID: String, fileURL: URL) {
    let pending = PendingWorkerRecording(sessionID: sessionID, filePath: fileURL.path)
    guard let encoded = try? JSONEncoder().encode(pending) else { return }
    UserDefaults.standard.set(encoded, forKey: pendingRecordingDefaultsKey)
  }

  private func clearPendingRecording() {
    UserDefaults.standard.removeObject(forKey: pendingRecordingDefaultsKey)
  }

  private func loadPendingRecording() -> PendingWorkerRecording? {
    guard let data = UserDefaults.standard.data(forKey: pendingRecordingDefaultsKey) else { return nil }
    return try? JSONDecoder().decode(PendingWorkerRecording.self, from: data)
  }

  private func expectedIPhoneRecordingURL(for sessionID: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("sop_\(sessionID)")
      .appendingPathExtension("mp4")
  }

  private func recoverPendingWorkerRecordingIfNeeded() async {
    guard !didAttemptPendingRecordingRecovery else { return }
    guard let pendingRecording = loadPendingRecording() else {
      didAttemptPendingRecordingRecovery = true
      return
    }

    didAttemptPendingRecordingRecovery = true
    let pendingURL = URL(fileURLWithPath: pendingRecording.filePath)
    let recoveryURL = FileManager.default.fileExists(atPath: pendingURL.path) ? pendingURL : nil
    let recoverySync = WorkerAdminLiveSessionCoordinator(
      api: opsAPIClient,
      sessionID: pendingRecording.sessionID,
      heartbeatIntervalNanoseconds: 0
    )

    let result = await recoverySync.uploadVideoRecording(from: recoveryURL)
    if result.succeeded {
      clearPendingRecording()
      if let recoveryURL {
        try? FileManager.default.removeItem(at: recoveryURL)
      }
    } else {
      operationsSyncError = "Recovered recording finalize failed: \(result.errorMessage ?? "Unknown error")"
    }

    do {
      _ = try await opsAPIClient.updateExecutionSession(
        id: pendingRecording.sessionID,
        patch: ExecutionSessionPatch(
          status: "ended",
          helpRequested: false,
          endedAt: ISO8601DateFormatter().string(from: Date())
        )
      )
    } catch {
      if result.succeeded {
        operationsSyncError = "Recovered video uploaded, but session end sync failed: \(error.localizedDescription)"
      }
    }
  }

  private func requestSpeechPermissionsIfNeeded() {
    SFSpeechRecognizer.requestAuthorization { status in
      if status != .authorized {
        NSLog("[Speech] Speech recognition authorization denied: %@", String(describing: status))
      }
    }

    AVAudioApplication.requestRecordPermission { granted in
      if !granted {
        NSLog("[Speech] Microphone permission denied")
      }
    }
  }

  func startHoldToTalk() {
    guard !isListeningForVoice else { return }
    guard let speechRecognizer, speechRecognizer.isAvailable else {
      sopAuditStatusMessage = "Speech recognizer unavailable"
      return
    }

    do {
      if let routeWarning = try configureWorkerAudioRoute(for: preferredCaptureMode, reason: .holdToTalk) {
        helpStatusMessage = routeWarning
      }
    } catch {
      sopAuditStatusMessage = "Audio session error: \(error.localizedDescription)"
      return
    }

    speechTask?.cancel()
    speechTask = nil

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    speechRequest = request

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
      request.append(buffer)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      sopAuditStatusMessage = "Mic start failed: \(error.localizedDescription)"
      stopHoldToTalk()
      return
    }

    isListeningForVoice = true

    speechTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }

      if let result {
        let transcript = result.bestTranscription.formattedString.lowercased()
        self.handleVoiceTranscript(transcript)
      }

      if error != nil {
        self.stopHoldToTalk()
      }
    }
  }

  func stopHoldToTalk() {
    guard isListeningForVoice || audioEngine.isRunning else { return }

    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }

    speechRequest?.endAudio()
    speechRequest = nil
    speechTask?.cancel()
    speechTask = nil
    isListeningForVoice = false

    if webrtcViewModel.isActive {
      do {
        if let routeWarning = try configureWorkerAudioRoute(for: preferredCaptureMode, reason: .viewer) {
          helpStatusMessage = routeWarning
        }
      } catch {
        NSLog("[Speech] Failed to restore talkback audio route: %@", error.localizedDescription)
      }
    } else {
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        NSLog("[Speech] Failed to deactivate audio session: %@", error.localizedDescription)
      }
    }
  }

  private func handleVoiceTranscript(_ transcript: String) {
    guard transcript != lastProcessedTranscript else { return }
    lastProcessedTranscript = transcript

    if transcript.contains("done") {
      markFirstUncheckedAsVoice()
      return
    }

    guard let checkRange = transcript.range(of: "check ") else { return }
    let spokenItem = transcript[checkRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spokenItem.isEmpty else { return }

    if let matched = checklistItems.first(where: { $0.name.lowercased().contains(spokenItem) || spokenItem.contains($0.name.lowercased()) }) {
      setChecklistItemChecked(itemID: matched.id, source: .voice)
    }
  }

  private func markFirstUncheckedAsVoice() {
    guard let firstUnchecked = checklistItems.first(where: { !$0.isChecked }) else { return }
    setChecklistItemChecked(itemID: firstUnchecked.id, source: .voice)
  }

  private func setChecklistItemChecked(itemID: UUID, source: ChecklistCompletionSource) {
    guard let index = checklistItems.firstIndex(where: { $0.id == itemID }) else { return }
    guard !checklistItems[index].isChecked else { return }
    checklistItems[index].isChecked = true
    checklistItems[index].completionSource = source

    let item = checklistItems[index]
    Task {
      await handleChecklistMutation(
        item: item,
        stepIndex: index,
        eventType: "step_complete"
      )
    }

    if checklistItems.allSatisfy({ $0.isChecked }) {
      Task { await endAndShip(status: .allItemsChecked) }
    }
  }

  private func setChecklistItemCheckedBySpotterID(_ itemID: String) {
    guard let index = checklistItems.firstIndex(where: { $0.itemID == itemID }) else { return }
    guard !checklistItems[index].isChecked else { return }

    checklistItems[index].isChecked = true
    checklistItems[index].completionSource = .vision
    dossierSpotterHitCount += 1
    updateDossierPipelineStatus("Live spotter hit #\(dossierSpotterHitCount)", kind: .active)

    let item = checklistItems[index]
    Task {
      await handleChecklistMutation(
        item: item,
        stepIndex: index,
        eventType: "step_complete"
      )
    }

    if checklistItems.allSatisfy({ $0.isChecked }) {
      Task { await endAndShip(status: .allItemsChecked) }
    }
  }

  private func captureProofImageIfNeeded(for itemID: String, from image: UIImage) {
    guard proofImagesByTargetID[itemID] == nil else { return }
    guard let jpegData = image.jpegData(compressionQuality: 0.9) else { return }
    proofImagesByTargetID[itemID] = jpegData
  }

  private func buildDossierMetadataJSONString() -> String {
    let checkedCount = checklistItems.filter { $0.isChecked }.count
    let complianceLevel: String
    if !checklistItems.isEmpty, checkedCount == checklistItems.count {
      complianceLevel = "FULLY"
    } else if checkedCount == 0 {
      complianceLevel = "NON"
    } else {
      complianceLevel = "PARTIALLY"
    }

    let foundItems: [[String: Any]] = checklistItems.map { item in
      let notes: String
      if item.isChecked {
        switch item.completionSource {
        case .vision:
          notes = "Spotted live by edge AI"
        case .voice:
          notes = "Confirmed by voice"
        case .manual:
          notes = "Checked by operator"
        case .pending:
          notes = "Found"
        }
      } else {
        notes = "Not found"
      }

      return [
        "target": item.itemID,
        "found": item.isChecked,
        "notes": notes
      ]
    }

    let checklist: [[String: Any]] = checklistItems.map { item in
      [
        "name": item.name,
        "checked": item.isChecked
      ]
    }

    let metadata: [String: Any] = [
      "compliance_level": complianceLevel,
      "found_items": foundItems,
      "checklist": checklist
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: []),
          let json = String(data: data, encoding: .utf8) else {
      return "{}"
    }

    return json
  }

  private func spotChecklistItemsIfThrottled(image: UIImage) {
    guard isSopAuditRunning else { return }
    guard !isSpotterInferenceInFlight else { return }

    let now = Date()
    guard now.timeIntervalSince(lastSpotterInferenceTime) >= 0.6 else { return } // ~1.6 FPS
    lastSpotterInferenceTime = now
    isSpotterInferenceInFlight = true

    let pendingItems = checklistItems
      .filter { !$0.isChecked }
      .map {
        GeminiLiveSpotter.SpotterRequestItem(
          id: $0.itemID,
          name: $0.name,
          aiPrompt: $0.aiPrompt,
          expectedObjects: $0.expectedObjects
        )
      }

    guard !pendingItems.isEmpty else {
      isSpotterInferenceInFlight = false
      return
    }

    Task { [weak self] in
      guard let self else { return }
      let matchedIDs: [String]
      do {
        matchedIDs = try await self.geminiLiveSpotter.detectVisibleItemIDs(image: image, items: pendingItems)
      } catch {
        matchedIDs = []
      }

      await MainActor.run {
        matchedIDs.forEach {
          self.captureProofImageIfNeeded(for: $0, from: image)
          self.setChecklistItemCheckedBySpotterID($0)
        }
        self.isSpotterInferenceInFlight = false
      }
    }
  }

  private func startPreferredCamera() async {
    switch preferredCaptureMode {
    case .iPhone:
      await handleStartIPhone()
    case .glasses:
      guard hasActiveDevice else {
        showError("Meta camera unavailable. Connect glasses or switch to iPhone.")
        return
      }
      await handleStartStreaming()
    }
  }

  private func stopCurrentCameraTransportOnly() async {
    switch streamingMode {
    case .iPhone:
      iPhoneCameraManager?.stop()
      iPhoneCameraManager = nil
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped
      // Default to glasses mode when stopped; next start sets active mode explicitly.
      streamingMode = .glasses
    case .glasses:
      await streamSession.stop()
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped
    }
  }

  private enum WorkerAudioRouteReason {
    case viewer
    case holdToTalk
  }

  private func describeAudioPorts(_ ports: [AVAudioSessionPortDescription]) -> String {
    if ports.isEmpty {
      return "none"
    }

    return ports
      .map { "\($0.portType.rawValue):\($0.portName)" }
      .joined(separator: ",")
  }

  private func logWorkerAudioRoute(
    session: AVAudioSession,
    mode: StreamingMode,
    reason: WorkerAudioRouteReason,
    note: String? = nil
  ) {
    let modeLabel = mode == .iPhone ? "iphone" : "glasses"
    let reasonLabel = reason == .viewer ? "viewer" : "hold_to_talk"
    NSLog(
      "[WorkerAudio] reason=%@ mode=%@ muted=%@ inputs=%@ outputs=%@ note=%@",
      reasonLabel,
      modeLabel,
      webrtcViewModel.isMuted ? "true" : "false",
      describeAudioPorts(session.currentRoute.inputs),
      describeAudioPorts(session.currentRoute.outputs),
      note ?? "none"
    )
  }

  private func hasBluetoothTalkbackRoute(_ route: AVAudioSessionRouteDescription) -> Bool {
    route.outputs.contains {
      $0.portType == .bluetoothA2DP
        || $0.portType == .bluetoothHFP
        || $0.portType == .bluetoothLE
    }
  }

  @discardableResult
  private func configureWorkerAudioRoute(
    for mode: StreamingMode,
    reason: WorkerAudioRouteReason
  ) throws -> String? {
    let session = AVAudioSession.sharedInstance()
    var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
    let audioMode: AVAudioSession.Mode

    switch mode {
    case .iPhone:
      audioMode = .voiceChat
      options.formUnion([.defaultToSpeaker, .duckOthers])
    case .glasses:
      audioMode = .videoChat
    }

    try session.setCategory(.playAndRecord, mode: audioMode, options: options)
    try session.setPreferredIOBufferDuration(0.064)
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    switch mode {
    case .iPhone:
      try session.overrideOutputAudioPort(.speaker)
      logWorkerAudioRoute(session: session, mode: mode, reason: reason)
      return nil
    case .glasses:
      if hasBluetoothTalkbackRoute(session.currentRoute) {
        try session.overrideOutputAudioPort(.none)
        logWorkerAudioRoute(session: session, mode: mode, reason: reason)
        return nil
      }
      try session.overrideOutputAudioPort(.speaker)
      switch reason {
      case .viewer:
        let note = "Meta audio route unavailable. Using phone speaker until glasses/Bluetooth audio connects."
        logWorkerAudioRoute(session: session, mode: mode, reason: reason, note: note)
        return note
      case .holdToTalk:
        let note = "Meta mic route unavailable. Hold-to-talk is using the phone until glasses/Bluetooth audio connects."
        logWorkerAudioRoute(session: session, mode: mode, reason: reason, note: note)
        return note
      }
    }
  }

  private func liveRoomStatusMessage(localOnly: Bool, helpRequested: Bool, roomCode: String? = nil) -> String {
    if localOnly {
      return helpRequested
        ? "Live room is local-only. Admin can't join until the backend session sync succeeds."
        : "Local live room active. Admin visibility will start once the backend session sync succeeds."
    }

    if let roomCode, !roomCode.isEmpty {
      return helpRequested
        ? "Supervisor request sent. Room \(roomCode) is ready for manager join."
        : "Live room active: \(roomCode)"
    }

    return helpRequested
      ? "Supervisor request sent. Waiting for the live room to finish syncing."
      : "Opening live execution room..."
  }

  private func waitForRoomCode(timeoutNanoseconds: UInt64 = 5_000_000_000) async -> String? {
    if !webrtcViewModel.roomCode.isEmpty {
      return webrtcViewModel.roomCode
    }

    let step: UInt64 = 150_000_000
    var waited: UInt64 = 0
    while waited < timeoutNanoseconds {
      try? await Task.sleep(nanoseconds: step)
      waited += step
      if !webrtcViewModel.roomCode.isEmpty {
        return webrtcViewModel.roomCode
      }
    }
    return nil
  }

  private func createOrFallbackSessionID(for sop: SOPTemplate) async -> String {
    if let activeExecutionSession {
      currentSopSessionId = activeExecutionSession.id
      isUsingLocalSessionFallback = false
      return activeExecutionSession.id
    }

    guard let workerID = workerProfile?.id else {
      isUsingLocalSessionFallback = true
      let fallback = UUID().uuidString
      operationsSyncError = "Worker context unavailable. Recording locally until ops-api is reachable."
      return fallback
    }

    do {
      let shiftID = validRemoteUUID(sop.shiftID) ?? validRemoteUUID(activeShift?.id)
      let packageID = validRemoteUUID(sop.packageID) ?? validRemoteUUID(activeShift?.packageID) ?? validRemoteUUID(activeShift?.package?.id)
      let packageRunID = validRemoteUUID(sop.packageRunID) ?? validRemoteUUID(activePackageRunID)
      let currentSopID = validRemoteUUID(sop.remoteID)
      let createdSession = try await opsAPIClient.createExecutionSession(
        workerID: workerID,
        deviceID: registeredDevice?.id,
        shiftID: shiftID,
        packageID: packageID,
        packageRunID: packageRunID,
        currentSopID: currentSopID,
        sopVersion: sop.sopVersion,
        packageVersion: sop.packageVersion
      )
      activeExecutionSession = createdSession
      isUsingLocalSessionFallback = false
      operationsSyncError = nil
      await postExecutionEvent(
        type: "session_started",
        payload: [
          "sop_name": sop.name,
          "capture_mode": selectedCaptureModeLabel.lowercased()
        ]
      )
      return createdSession.id
    } catch {
      isUsingLocalSessionFallback = true
      operationsSyncError = "Execution session could not sync. Continuing locally: \(error.localizedDescription)"
      return UUID().uuidString
    }
  }

  private func handleChecklistMutation(
    item: ChecklistItemState,
    stepIndex: Int,
    eventType: String
  ) async {
    let nextIndex = nextIncompleteStepIndex()
    await workerAdminSync?.updateCurrentStepIndex(nextIndex, sendImmediateHeartbeat: true)
    await postExecutionEvent(
      type: eventType,
      payload: [
        "step_index": stepIndex,
        "step_name": item.name,
        "source": item.completionSource.rawValue,
        "checked": item.isChecked
      ]
    )
    await patchActiveExecutionSession(
      ExecutionSessionPatch(
        status: "active",
        currentSopID: selectedSOP?.remoteID,
        currentStepIndex: nextIndex
      )
    )
  }

  private func nextIncompleteStepIndex() -> Int {
    checklistItems.firstIndex(where: { !$0.isChecked }) ?? checklistItems.count
  }

  private func syncLivePreviewFrameIfNeeded(image: UIImage) async {
    guard isSopAuditRunning else { return }
    guard let sessionID = currentSopSessionId else { return }
    guard let jpegData = image.jpegData(compressionQuality: 0.65) else { return }

    let now = Date()
    guard now.timeIntervalSince(lastLivePreviewSyncAt) >= 2.0 else { return }
    lastLivePreviewSyncAt = now

    if streamingMode == .glasses, let fileURL = sopVideoRecorder?.outputURL {
      rememberPendingRecording(sessionID: sessionID, fileURL: fileURL)
    }

    await workerAdminSync?.enqueueFrameUpload(data: jpegData)
  }

  private func requestSupervisorHelpFlow() async {
    guard canRequestHelp else {
      helpStatusMessage = "Start an SOP before requesting live support."
      return
    }

    isRequestingHelp = true
    defer { isRequestingHelp = false }

    await ensureLiveRoomSession()

    let notes = helpRequestNotes.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let sessionID = activeExecutionSession?.id else {
      helpStatusMessage = liveRoomStatusMessage(localOnly: true, helpRequested: true, roomCode: webrtcViewModel.roomCode)
      return
    }

    do {
      _ = try await opsAPIClient.createIntervention(
        sessionID: sessionID,
        type: "help_request",
        notes: notes.isEmpty ? "Worker requested assistance." : notes
      )
      hasActiveHelpEscalation = true
      await workerAdminSync?.updateHelpRequested(true)
      await postExecutionEvent(
        type: "help_requested",
        payload: [
          "notes": notes,
          "room_code": webrtcViewModel.roomCode
        ]
      )
      await patchActiveExecutionSession(
        ExecutionSessionPatch(
          helpRequested: true,
          webrtcRoomCode: webrtcViewModel.roomCode.isEmpty ? nil : webrtcViewModel.roomCode
        )
      )
      helpStatusMessage = liveRoomStatusMessage(localOnly: false, helpRequested: true, roomCode: webrtcViewModel.roomCode)
    } catch {
      helpStatusMessage = "Live room is open locally, but the backend help request failed: \(error.localizedDescription)"
    }
  }

  private func syncLiveRoomState(roomCode: String) async {
    guard !roomCode.isEmpty else { return }
    await workerAdminSync?.updateRoomCode(roomCode)
    guard activeExecutionSession != nil else {
      helpStatusMessage = liveRoomStatusMessage(localOnly: true, helpRequested: hasActiveHelpEscalation, roomCode: roomCode)
      return
    }

    helpStatusMessage = liveRoomStatusMessage(localOnly: false, helpRequested: hasActiveHelpEscalation, roomCode: roomCode)
    await patchActiveExecutionSession(
      ExecutionSessionPatch(
        helpRequested: hasActiveHelpEscalation,
        webrtcRoomCode: roomCode
      )
    )
  }

  private func closeCurrentPackageFlow() async {
    guard !isClosingPackage else { return }
    guard canCloseCurrentPackage else {
      packageClosureStatusMessage = "Complete all required SOPs before closing the package."
      return
    }
    guard let packageRunID = activePackageRunID else {
      packageClosureStatusMessage = "Package run is not synced yet. Ask ops-api to expose the package close route."
      return
    }
    guard let workerID = workerProfile?.id else {
      packageClosureStatusMessage = "Worker context missing. Refresh the assignment queue first."
      return
    }

    isClosingPackage = true
    defer { isClosingPackage = false }

    do {
      _ = try await opsAPIClient.closePackageRun(
        packageRunID: packageRunID,
        workerID: workerID
      )
      packageClosureStatusMessage = "Package closed and synced."
      await refreshWorkerContext()
    } catch {
      packageClosureStatusMessage = "Package close failed: \(error.localizedDescription)"
    }
  }

  private func updateHelpStatus(for state: WebRTCConnectionState) {
    let localOnly = activeExecutionSession == nil
    switch state {
    case .connected:
      if !hasLoggedRoomJoinedForSession {
        hasLoggedRoomJoinedForSession = true
        WorkerLiveLogger.log(
          "room_joined",
          sessionID: currentSopSessionId,
          roomCode: webrtcViewModel.roomCode.isEmpty ? nil : webrtcViewModel.roomCode,
          uploadState: "active"
        )
      }
      helpStatusMessage = localOnly
        ? "Local live room connected. Admin join stays unavailable until backend sync succeeds."
        : "Live viewer connected."
    case .waitingForPeer:
      if !webrtcViewModel.roomCode.isEmpty {
        helpStatusMessage = liveRoomStatusMessage(
          localOnly: localOnly,
          helpRequested: hasActiveHelpEscalation,
          roomCode: webrtcViewModel.roomCode
        )
      }
    case .connecting:
      helpStatusMessage = localOnly
        ? "Opening local live room..."
        : "Opening live execution room..."
    case .backgrounded:
      helpStatusMessage = "Live room paused in background. Returning will reconnect."
    case .error(let message):
      helpStatusMessage = "Live room error: \(message)"
    case .disconnected:
      if !isRequestingHelp {
        helpStatusMessage = ""
      }
    }
  }

  private func ensureLiveRoomSession() async {
    do {
      if let routeWarning = try configureWorkerAudioRoute(for: preferredCaptureMode, reason: .viewer) {
        helpStatusMessage = routeWarning
      }
    } catch {
      helpStatusMessage = "Audio route error: \(error.localizedDescription)"
    }

    let hasRoomCode = !webrtcViewModel.roomCode.isEmpty

    if webrtcViewModel.isActive {
      switch webrtcViewModel.connectionState {
      case .connected, .waitingForPeer:
        if hasRoomCode {
          await syncLiveRoomState(roomCode: webrtcViewModel.roomCode)
          return
        }
      case .connecting:
        if hasRoomCode {
          await syncLiveRoomState(roomCode: webrtcViewModel.roomCode)
          return
        }
      case .backgrounded, .error, .disconnected:
        break
      }

      helpStatusMessage = "Restarting live room for this SOP..."
      webrtcViewModel.stopSession()
    }

    await webrtcViewModel.startSession()
    if let roomCode = await waitForRoomCode() {
      await syncLiveRoomState(roomCode: roomCode)
    } else if activeExecutionSession == nil {
      helpStatusMessage = "Opening local-only live room..."
      operationsSyncError = "Live room is local-only until the backend execution session sync succeeds."
    } else {
      helpStatusMessage = "Live room still syncing. Manager join will unlock once the room code is published."
      operationsSyncError = "Live room did not publish a room code yet. Verify signal settings and session sync before expecting admin join."
    }
  }

  private func postExecutionEvent(type: String, payload: [String: Any]) async {
    guard let sessionID = activeExecutionSession?.id else { return }
    do {
      _ = try await opsAPIClient.postExecutionEvent(
        sessionID: sessionID,
        eventType: type,
        payload: payload
      )
    } catch {
      operationsSyncError = "Event sync failed: \(error.localizedDescription)"
    }
  }

  private func patchActiveExecutionSession(_ patch: ExecutionSessionPatch) async {
    guard let sessionID = activeExecutionSession?.id else { return }
    do {
      activeExecutionSession = try await opsAPIClient.updateExecutionSession(id: sessionID, patch: patch)
    } catch {
      operationsSyncError = "Session sync failed: \(error.localizedDescription)"
    }
  }

  private func uploadMediaAssetIfPossible(
    assetID: String,
    data: Data,
    contentType: String,
    label: String
  ) async -> Bool {
    guard !data.isEmpty else { return false }

    do {
      let uploadTarget = try await opsAPIClient.requestMediaUploadTarget(
        assetID: assetID,
        contentType: contentType,
        byteCount: data.count
      )
      try await opsAPIClient.uploadBinary(to: uploadTarget, data: data, contentType: contentType)
      _ = try await opsAPIClient.finalizeMediaAssetUpload(
        assetID: assetID,
        byteCount: data.count,
        contentType: contentType
      )
      return true
    } catch {
      operationsSyncError = "\(label) upload is pending until ops-api exposes upload targets. \(error.localizedDescription)"
      return false
    }
  }

  private func uploadEvidenceMediaAssets(
    sessionID: String,
    proofImages: [String: Data]
  ) async {
    for (targetID, imageData) in proofImages {
      do {
        let evidenceAsset = try await opsAPIClient.registerMediaAsset(
          sessionID: sessionID,
          bucket: "evidence-images",
          path: "sessions/\(sessionID)/proof/\(targetID).jpg",
          assetType: "photo",
          metadata: [
            "item_id": targetID,
            "upload_state": "pending",
            "bytes": imageData.count
          ]
        )
        _ = await uploadMediaAssetIfPossible(
          assetID: evidenceAsset.id,
          data: imageData,
          contentType: "image/jpeg",
          label: "Evidence image"
        )
      } catch {
        operationsSyncError = "Evidence registration failed: \(error.localizedDescription)"
      }
    }
  }

  private func createExecutionMemoryLink(
    sessionID: String,
    sopID: String,
    completedSteps: Int
  ) async {
    do {
      _ = try await opsAPIClient.createMemoryLink(
        sourceID: sessionID,
        sourceType: "execution_session",
        targetID: sopID,
        targetType: "sop",
        linkType: "executed",
        metadata: [
          "completed_steps": completedSteps,
          "total_steps": checklistItems.count
        ]
      )
    } catch {
      operationsSyncError = "Memory link sync failed: \(error.localizedDescription)"
    }
  }

  private func updateDossierPipelineStatus(_ message: String, kind: DossierPipelineStatusKind) {
    dossierPipelineStatusMessage = message
    dossierPipelineStatusKind = kind
    dossierPipelineStatusTimestamp = Self.pipelineTimestampFormatter.string(from: Date())
  }
}
