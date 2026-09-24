import Foundation
import os

private let logger = Logger(subsystem: "com.universe.app", category: "gptlive.peer")

/// The audio half of a GPT‑Live call: one send/receive WebRTC audio track.
/// WebRTC's own audio device module captures the mic and plays the model's
/// voice, with its built-in echo cancellation.
@MainActor
protocol GPTLiveAudioPeer: AnyObject {
    /// Called on the main actor if the media connection drops.
    var onFailure: ((String) -> Void)? { get set }
    /// A complete SDP offer (all ICE candidates gathered — there is no trickle).
    func makeOffer() async throws -> String
    func applyAnswer(_ sdp: String) async throws
    func close()
}

enum GPTLivePeerError: LocalizedError {
    case unavailable
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "GPT‑Live voice isn't included in this build of Astro."
        case let .setupFailed(detail): "Couldn't set up the voice connection: \(detail)"
        }
    }
}

#if canImport(WebRTC)
import WebRTC

@MainActor
final class GPTLiveWebRTCPeer: NSObject, GPTLiveAudioPeer {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    var onFailure: ((String) -> Void)?
    private var connection: RTCPeerConnection?
    private let relay = DelegateRelay()

    override init() {
        super.init()
    }

    private func makeConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: relay) else {
            throw GPTLivePeerError.setupFailed("peer connection")
        }
        relay.onIceFailed = { [weak self] in
            Task { @MainActor in self?.onFailure?("The voice connection dropped.") }
        }

        let source = Self.factory.audioSource(with: constraints)
        let track = Self.factory.audioTrack(with: source, trackId: "universe-mic")
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendRecv
        guard connection.addTransceiver(with: track, init: transceiverInit) != nil else {
            throw GPTLivePeerError.setupFailed("audio track")
        }
        return connection
    }

    func makeOffer() async throws -> String {
        let connection = try makeConnection()
        self.connection = connection
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) } else {
                    continuation.resume(throwing: error ?? GPTLivePeerError.setupFailed("offer"))
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }

        // No trickle ICE on this endpoint: wait (bounded) for gathering to finish.
        let deadline = Date().addingTimeInterval(3)
        while connection.iceGatheringState != .complete, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let sdp = connection.localDescription?.sdp, !sdp.isEmpty else {
            throw GPTLivePeerError.setupFailed("empty offer")
        }
        logger.info("Offer ready (gathering \(connection.iceGatheringState == .complete ? "complete" : "timed out", privacy: .public))")
        return sdp
    }

    func applyAnswer(_ sdp: String) async throws {
        guard let connection else { throw GPTLivePeerError.setupFailed("no connection") }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(answer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close() {
        relay.onIceFailed = nil
        connection?.close()
        connection = nil
    }
}

/// WebRTC calls its delegate on an internal signalling thread.
private final class DelegateRelay: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    var onIceFailed: (() -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .disconnected {
            logger.warning("ICE state \(newState.rawValue)")
        }
        if newState == .failed { onIceFailed?() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

@MainActor
func makeGPTLiveAudioPeer() throws -> any GPTLiveAudioPeer { GPTLiveWebRTCPeer() }

#else

@MainActor
func makeGPTLiveAudioPeer() throws -> any GPTLiveAudioPeer { throw GPTLivePeerError.unavailable }

#endif
