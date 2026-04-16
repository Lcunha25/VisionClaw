import AVFoundation
import UIKit

class IPhoneCameraManager: NSObject, @unchecked Sendable {
  private let captureSession = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let movieOutput = AVCaptureMovieFileOutput()
  private let sessionQueue = DispatchQueue(label: "iphone-camera-session")
  private let context = CIContext()
  private var isRunning = false
  private var isConfigured = false
  private var recordingCompletion: ((URL?) -> Void)?
  private var currentRecordingURL: URL?

  var onFrameCaptured: ((UIImage) -> Void)?

  func start() {
    guard !isRunning else { return }
    sessionQueue.async { [weak self] in
      NSLog("[iPhoneCamera] start() requested")
      self?.configureSession()
      self?.captureSession.startRunning()
      self?.isRunning = true
      NSLog("[iPhoneCamera] captureSession.startRunning() complete (isRunning=%@, sessionRunning=%@)",
            self?.isRunning == true ? "true" : "false",
            self?.captureSession.isRunning == true ? "true" : "false")
    }
  }

  func startRecording(sessionID: String) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.configureSession()

      NSLog(
        "[iPhoneCamera] startRecording requested (sessionConfigured=%@, sessionRunning=%@, alreadyRecording=%@)",
        self.isConfigured ? "true" : "false",
        self.captureSession.isRunning ? "true" : "false",
        self.movieOutput.isRecording ? "true" : "false")

      if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: FileManager.default.temporaryDirectory.path),
         let freeSize = attributes[.systemFreeSize] as? NSNumber {
        NSLog("[iPhoneCamera] Free disk space before recording: %@ bytes", freeSize)
      }

      guard self.captureSession.isRunning else {
        NSLog("[iPhoneCamera] Cannot start recording because capture session is not running")
        return
      }
      guard !self.movieOutput.isRecording else {
        NSLog("[iPhoneCamera] Ignoring startRecording because movie output is already recording")
        return
      }

      let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sop_\(sessionID)")
        .appendingPathExtension("mp4")
      try? FileManager.default.removeItem(at: fileURL)
      self.currentRecordingURL = fileURL

      self.movieOutput.startRecording(to: fileURL, recordingDelegate: self)
      NSLog("[iPhoneCamera] Started recording SOP video: %@", fileURL.path)
    }
  }

  func stopRecording() async -> URL? {
    await withCheckedContinuation { continuation in
      sessionQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }

        NSLog(
          "[iPhoneCamera] stopRecording requested (isRecording=%@, currentRecordingURL=%@)",
          self.movieOutput.isRecording ? "true" : "false",
          self.currentRecordingURL?.path ?? "nil")

        guard self.movieOutput.isRecording else {
          NSLog("[iPhoneCamera] stopRecording returning currentRecordingURL immediately because movieOutput.isRecording=false")
          continuation.resume(returning: self.currentRecordingURL)
          return
        }

        self.recordingCompletion = { url in
          NSLog("[iPhoneCamera] stopRecording completion fired with URL=%@", url?.path ?? "nil")
          continuation.resume(returning: url)
        }
        self.movieOutput.stopRecording()
        NSLog("[iPhoneCamera] movieOutput.stopRecording() called")
      }
    }
  }

  func stop() {
    guard isRunning else { return }
    sessionQueue.async { [weak self] in
      NSLog("[iPhoneCamera] stop() requested")
      self?.captureSession.stopRunning()
      self?.isRunning = false
      NSLog("[iPhoneCamera] captureSession.stopRunning() complete")
    }
  }

  private func configureSession() {
    guard !isConfigured else { return }

    captureSession.beginConfiguration()
    captureSession.sessionPreset = .medium

    // Add back camera input
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: camera) else {
      NSLog("[iPhoneCamera] Failed to access back camera")
      captureSession.commitConfiguration()
      return
    }

    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
    }

    if let microphone = AVCaptureDevice.default(for: .audio),
       let audioInput = try? AVCaptureDeviceInput(device: microphone),
       captureSession.canAddInput(audioInput) {
      captureSession.addInput(audioInput)
    } else {
      NSLog("[iPhoneCamera] Microphone input unavailable for recording")
    }

    // Add video output
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    videoOutput.alwaysDiscardsLateVideoFrames = true

    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }

    // Add movie output for full-session recording.
    if captureSession.canAddOutput(movieOutput) {
      captureSession.addOutput(movieOutput)
    }

    // Force portrait-oriented frames from the sensor
    if let connection = videoOutput.connection(with: .video) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    }

    if let movieConnection = movieOutput.connection(with: .video) {
      if movieConnection.isVideoRotationAngleSupported(90) {
        movieConnection.videoRotationAngle = 90
      }
    }

    captureSession.commitConfiguration()
    isConfigured = true
    NSLog("[iPhoneCamera] Session configured successfully")
  }

  static func requestPermission() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    default:
      return false
    }
  }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension IPhoneCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
    let image = UIImage(cgImage: cgImage)

    onFrameCaptured?(image)
  }
}

extension IPhoneCameraManager: AVCaptureFileOutputRecordingDelegate {
  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    NSLog("[iPhoneCamera] didStartRecordingTo fired for %@", fileURL.path)
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    if let error {
      NSLog("[iPhoneCamera] Recording failed: %@", error.localizedDescription)
    } else {
      NSLog("[iPhoneCamera] Recording finished: %@", outputFileURL.path)
    }

    if let attributes = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path),
       let fileSize = attributes[.size] as? NSNumber {
      NSLog("[iPhoneCamera] Recorded file size: %@ bytes", fileSize)
    } else {
      NSLog("[iPhoneCamera] Could not read recorded file size at %@", outputFileURL.path)
    }

    let completion = recordingCompletion
    recordingCompletion = nil
    currentRecordingURL = outputFileURL
    completion?(error == nil ? outputFileURL : nil)
  }
}
