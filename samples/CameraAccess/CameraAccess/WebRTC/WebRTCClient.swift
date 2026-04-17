import Foundation
import UIKit
import WebRTC

protocol WebRTCClientDelegate: AnyObject {
  func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState)
  func webRTCClient(_ client: WebRTCClient, didGenerateCandidate candidate: RTCIceCandidate)
  func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack)
  func webRTCClient(_ client: WebRTCClient, didRemoveRemoteVideoTrack track: RTCVideoTrack)
  func webRTCClient(_ client: WebRTCClient, didUpdateSenderStats stats: WebRTCSenderStats)
}

/// Manages RTCPeerConnection, video/audio tracks, and SDP negotiation.
/// Video uses a custom capturer fed by the worker camera pipeline.
class WebRTCClient: NSObject {
  weak var delegate: WebRTCClientDelegate?

  private let factory: RTCPeerConnectionFactory
  private var streamProfile = WebRTCConfig.supportModeGlassesProfile
  private var peerConnection: RTCPeerConnection?
  private var videoSource: RTCVideoSource!
  private var videoCapturer: CustomVideoCapturer!
  private var localVideoTrack: RTCVideoTrack?
  private var localAudioTrack: RTCAudioTrack?
  private var localVideoSender: RTCRtpSender?
  private(set) var remoteVideoTrack: RTCVideoTrack?
  private var receiveRemoteVideo = true

  override init() {
    RTCInitializeSSL()
    let encoderFactory = RTCDefaultVideoEncoderFactory()
    let decoderFactory = RTCDefaultVideoDecoderFactory()
    self.factory = RTCPeerConnectionFactory(
      encoderFactory: encoderFactory,
      decoderFactory: decoderFactory
    )
    super.init()
  }

  func setup(
    iceServers: [RTCIceServer]? = nil,
    profile: WebRTCStreamProfile = WebRTCConfig.supportModeGlassesProfile,
    receiveRemoteVideo: Bool = true
  ) {
    streamProfile = profile
    self.receiveRemoteVideo = receiveRemoteVideo
    let config = RTCConfiguration()
    config.iceServers = iceServers ?? [RTCIceServer(urlStrings: WebRTCConfig.stunServers)]
    config.sdpSemantics = .unifiedPlan
    config.continualGatheringPolicy = .gatherContinually

    let constraints = RTCMediaConstraints(
      mandatoryConstraints: nil,
      optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
    )

    peerConnection = factory.peerConnection(
      with: config,
      constraints: constraints,
      delegate: self
    )

    createMediaTracks()
  }

  private func createMediaTracks() {
    videoSource = factory.videoSource()
    videoSource.adaptOutputFormat(
      toWidth: Int32(streamProfile.maxWidth),
      height: Int32(streamProfile.maxHeight),
      fps: Int32(streamProfile.maxFramerate)
    )
    videoCapturer = CustomVideoCapturer(delegate: videoSource)
    videoCapturer.onStatsSample = { [weak self] stats in
      guard let self else { return }
      self.delegate?.webRTCClient(self, didUpdateSenderStats: stats)
    }
    localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
    localVideoTrack?.isEnabled = true
    if let localVideoTrack {
      localVideoSender = peerConnection?.add(localVideoTrack, streamIds: ["stream0"])
      applyVideoSenderParameters()
    }

    let audioConstraints = RTCMediaConstraints(
      mandatoryConstraints: nil,
      optionalConstraints: nil
    )
    let audioSource = factory.audioSource(with: audioConstraints)
    localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
    localAudioTrack?.isEnabled = true
    if let localAudioTrack {
      peerConnection?.add(localAudioTrack, streamIds: ["stream0"])
    }
  }

  func pushVideoFrame(_ image: UIImage) {
    videoCapturer?.pushFrame(image)
  }

  func pushPixelBuffer(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
    videoCapturer?.pushPixelBuffer(pixelBuffer, timeStampNs: timeStampNs)
  }

  func updateStreamProfile(_ profile: WebRTCStreamProfile) {
    streamProfile = profile
    videoSource?.adaptOutputFormat(
      toWidth: Int32(profile.maxWidth),
      height: Int32(profile.maxHeight),
      fps: Int32(profile.maxFramerate)
    )
    applyVideoSenderParameters()
  }

  private func applyVideoSenderParameters() {
    guard let localVideoSender else { return }
    let parameters = localVideoSender.parameters
    let encodings = parameters.encodings

    if encodings.isEmpty {
      NSLog("[WebRTC] Sender parameters missing encodings; bitrate tuning skipped")
      return
    }

    for encoding in encodings {
      encoding.maxBitrateBps = NSNumber(value: streamProfile.maxBitrateBps)
      encoding.maxFramerate = NSNumber(value: streamProfile.maxFramerate)
    }

    parameters.encodings = encodings
    parameters.degradationPreference = NSNumber(
      value: RTCDegradationPreference.maintainFramerate.rawValue
    )
    localVideoSender.parameters = parameters

    NSLog(
      "[WebRTC] Sender tuned for support mode (%dx%d @ %dfps, %@ bps)",
      streamProfile.maxWidth,
      streamProfile.maxHeight,
      streamProfile.maxFramerate,
      NSNumber(value: streamProfile.maxBitrateBps)
    )
  }

  // MARK: - SDP Negotiation

  func createOffer(completion: @escaping (RTCSessionDescription) -> Void) {
    let constraints = RTCMediaConstraints(
      mandatoryConstraints: [
        "OfferToReceiveAudio": "true",
        "OfferToReceiveVideo": receiveRemoteVideo ? "true" : "false",
      ],
      optionalConstraints: nil
    )
    peerConnection?.offer(for: constraints) { [weak self] sdp, error in
      guard let sdp else {
        NSLog("[WebRTC] Failed to create offer: %@", error?.localizedDescription ?? "unknown")
        return
      }
      self?.peerConnection?.setLocalDescription(sdp) { error in
        if let error {
          NSLog("[WebRTC] Failed to set local description: %@", error.localizedDescription)
        } else {
          completion(sdp)
        }
      }
    }
  }

  func set(remoteSdp: RTCSessionDescription, completion: @escaping (Error?) -> Void) {
    peerConnection?.setRemoteDescription(remoteSdp, completionHandler: completion)
  }

  func set(remoteCandidate: RTCIceCandidate, completion: @escaping (Error?) -> Void) {
    peerConnection?.add(remoteCandidate, completionHandler: completion)
  }

  func muteAudio(_ mute: Bool) {
    localAudioTrack?.isEnabled = !mute
    NSLog("[WebRTC] Local mic %@", mute ? "muted" : "live")
  }

  func close() {
    localVideoTrack?.isEnabled = false
    localAudioTrack?.isEnabled = false
    localVideoSender = nil
    remoteVideoTrack = nil
    peerConnection?.close()
    peerConnection = nil
    NSLog("[WebRTC] Peer connection closed")
  }

  deinit {
    RTCCleanupSSL()
  }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCClient: RTCPeerConnectionDelegate {
  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange stateChanged: RTCSignalingState
  ) {
    NSLog("[WebRTC] Signaling state: %d", stateChanged.rawValue)
  }

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCIceConnectionState
  ) {
    NSLog("[WebRTC] ICE connection state: %d", newState.rawValue)
    delegate?.webRTCClient(self, didChangeConnectionState: newState)
  }

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCIceGatheringState
  ) {
    NSLog("[WebRTC] ICE gathering state: %d", newState.rawValue)
  }

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didGenerate candidate: RTCIceCandidate
  ) {
    let sdp = candidate.sdp
    if sdp.contains("relay") {
      NSLog("[WebRTC] ICE candidate: RELAY (TURN)")
    } else if sdp.contains("srflx") {
      NSLog("[WebRTC] ICE candidate: SERVER REFLEXIVE (STUN)")
    } else if sdp.contains("host") {
      NSLog("[WebRTC] ICE candidate: HOST (local)")
    }
    delegate?.webRTCClient(self, didGenerateCandidate: candidate)
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
    NSLog(
      "[WebRTC] Remote stream added with %d audio tracks, %d video tracks",
      stream.audioTracks.count,
      stream.videoTracks.count
    )
    if let videoTrack = stream.videoTracks.first {
      remoteVideoTrack = videoTrack
      delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: videoTrack)
    }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
    NSLog("[WebRTC] Remote stream removed")
    if let track = remoteVideoTrack {
      remoteVideoTrack = nil
      delegate?.webRTCClient(self, didRemoveRemoteVideoTrack: track)
    }
  }

  func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
    NSLog("[WebRTC] Negotiation needed")
  }

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didRemove candidates: [RTCIceCandidate]
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didOpen dataChannel: RTCDataChannel
  ) {}
}
