#if os(iOS)
import Foundation

#if canImport(WebRTC)
import WebRTC

// REAL TRANSPORT (Plan 3 Task 4). Active automatically when the `stasel/WebRTC`
// SwiftPM package is present. Opens an RTCPeerConnection, exchanges SDP directly
// with the DashScope realtime endpoint using the on-device key (no backend), and
// pipes data-channel events through RealtimeEventParser to the ClassroomController.
@MainActor
final class QwenRealtimeTransport: NSObject, ClassroomTransport {
    private let factory: RTCPeerConnectionFactory
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var instructions = ""
    private var onEvent: ((RealtimeEvent) -> Void)?
    // nonisolated: the remote track arrives on RTCPeerConnectionDelegate
    // callbacks, which are not main-actor. An immutable stream needs no
    // isolation, and the consumer awaits it from wherever it likes.
    nonisolated let remoteAudioTrack = AsyncStream<RTCAudioTrack>.makeStream()

    override init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                           decoderFactory: RTCDefaultVideoDecoderFactory())
        super.init()
    }

    func connect(instructions: String, apiKey: String, workspaceId: String, region: String, model: String,
                 onEvent: @escaping (RealtimeEvent) -> Void) async throws {
        self.instructions = instructions
        self.onEvent = onEvent
        let config = RTCConfiguration()
        config.iceServers = []
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw NSError(domain: "Qwen", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not create peer connection"])
        }
        self.peer = peer

        // Local mic track.
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "mic0")
        peer.add(audioTrack, streamIds: ["local0"])

        // Data channel for realtime events.
        let dcConfig = RTCDataChannelConfiguration()
        let dc = peer.dataChannel(forLabel: "oai-events", configuration: dcConfig)
        dc?.delegate = self
        self.channel = dc

        let offer = try await peer.offer(for: constraints)
        try await peer.setLocalDescription(offer)

        let resolvedRegion = region == "cn-beijing" ? "cn-beijing" : "ap-southeast-1"
        guard let endpoint = URL(string: "https://\(workspaceId).\(resolvedRegion).maas.aliyuncs.com/api/v1/webrtc/realtime?model=\(model)") else {
            throw NSError(domain: "Qwen", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid DashScope endpoint"])
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = offer.sdp.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let answerSDP = String(data: data, encoding: .utf8) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw NSError(domain: "Qwen", code: status, userInfo: [NSLocalizedDescriptionKey: "DashScope WebRTC error \(status): \(detail)"])
        }
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answerSDP))
    }

    private func sendSessionUpdate() {
        let session: [String: Any] = [
            "modalities": ["text", "audio"],
            "voice": "Ethan",
            "input_audio_format": "pcm",
            "output_audio_format": "pcm",
            "instructions": "\(instructions)\n\n\(omniDirectInstructions)",
            "input_audio_transcription": ["model": "qwen3-asr-flash-realtime"],
            "tools": realtimePlaybackTools,
            "turn_detection": ["type": "semantic_vad", "threshold": 0.5, "silence_duration_ms": 800, "create_response": true],
        ]
        send(["type": "session.update", "session": session])
    }

    private func send(_ payload: [String: Any]) {
        guard let channel, channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func stopSpeaking() {
        send(["type": "response.cancel"])
        send(["type": "output_audio_buffer.clear"])
    }

    func sendToolResult(callId: String?, ok: Bool) {
        send(["type": "conversation.item.create",
              "item": ["type": "function_call_output", "call_id": callId as Any,
                       "output": "{\"ok\":\(ok)}"]])
    }

    func updateContext(_ context: String) {
        send(["type": "session.update", "session": ["instructions": composeInstructions(instructions, freshContext: context)]])
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text",
                                    "text": "[SYSTEM] The podcast is now at a new position. This is the ONLY current context — ignore earlier positions we discussed:\n\(context)"]]]])
    }

    func injectUserText(_ text: String) {
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": "Read the following teacher answer aloud exactly. Do not add commentary or call tools.\n\n\(text)"]]]])
        requestResponse()
    }

    func requestResponse() { send(["type": "response.create"]) }
}

extension QwenRealtimeTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCAudioTrack { remoteAudioTrack.continuation.yield(track) }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
    }
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

extension QwenRealtimeTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open {
            Task { @MainActor in self.sendSessionUpdate() }
        }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary,
              let json = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any] else { return }
        Task { @MainActor in
            if let event = RealtimeEventParser.parse(json) { self.onEvent?(event) }
        }
    }
}

#else

// STUB TRANSPORT — active when the WebRTC package is NOT present (e.g. this
// build environment, where GitHub release assets are unreachable). Keeps the app
// compiling and running; the live class surfaces a clear "not available" error.
// Conforms to the same ClassroomTransport protocol, so flipping to the real
// implementation above requires only adding the WebRTC package dependency — no
// changes to ClassroomController, LiveClassSession, or any view.
@MainActor
final class QwenRealtimeTransport: ClassroomTransport {
    struct NotIntegrated: LocalizedError {
        var errorDescription: String? {
            "Live voice class needs the WebRTC package, which isn't integrated in this build yet."
        }
    }

    func connect(instructions: String, apiKey: String, workspaceId: String, region: String, model: String,
                 onEvent: @escaping (RealtimeEvent) -> Void) async throws {
        throw NotIntegrated()
    }

    func stopSpeaking() {}
    func sendToolResult(callId: String?, ok: Bool) {}
    func updateContext(_ context: String) {}
    func injectUserText(_ text: String) {}
    func speak(_ text: String) {}
    func requestResponse() {}
}

#endif
#endif
