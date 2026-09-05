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
    private var micTrack: RTCAudioTrack?
    private var turnMode: TurnMode = .continuous
    // Tracks whether a teacher response is in flight. response.cancel is only
    // valid while one is; sending it otherwise draws a "Conversation has none
    // active response" error. Set on response.created, cleared on response.done.
    private var hasActiveResponse = false
    /// True while a response we CANCELLED is still winding down.
    ///
    /// The server sends response.done for a cancelled response too, and that event used to be
    /// handled as "the teacher finished" — which moved the scene out of the state the learner
    /// was in. Holding to talk mid-answer therefore showed Live 等你开口 while the controller
    /// had already been told the turn was over, and nothing responded.
    private var cancelledResponse = false

    /// Open data channel = a turn can still be carried. Deliberately the CHANNEL and not
    /// a flag set at connect time: the flag is what stayed true through the server's idle
    /// timeout, so a hold five minutes later sent into a closed pipe and heard nothing
    /// back.
    var isAlive: Bool { channel?.readyState == .open }
    // Turn-boundary events worth logging. Everything else (transcript deltas above
    // all) is per-token noise that hides these.
    private static let loggedEventTypes: Set<String> = [
        "input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped",
        "input_audio_buffer.committed", "input_audio_buffer.cleared",
        "response.created", "response.done", "session.updated",
        "response.function_call_arguments.done",
        // The two transcription events. Both are turn boundaries in reading mode —
        // they are what the conversation panel draws and what the extractor reads —
        // so their ABSENCE has to be visible in a log, not indistinguishable from
        // not being logged. They fire once per turn, not per delta.
        "conversation.item.input_audio_transcription.completed",
        "response.audio_transcript.done",
    ]

    // The teacher's voice. WebRTC's audio device module renders a remote track
    // to the output automatically, but ONLY while the RTCAudioTrack object is
    // retained and enabled — drop the reference and the render tears down and
    // the teacher goes silent. So we hold it for the life of the session.
    private var remoteAudioTrack: RTCAudioTrack?

    override init() {
        RTCInitializeSSL()
        // WebRTC keeps its own AVAudioSession config and reapplies it around
        // track changes; left at its default it routes to the earpiece, which
        // over speaker-played podcast audio reads as "the teacher is silent."
        // Match the app's classroom session (see LocalAudioPlayback): voiceChat
        // for echo cancellation so the podcast leaking into the mic does not trip
        // the model's VAD.
        //
        // WebRTC owns the MIC, and this config wins over anything the app set on
        // AVAudioSession — so the .defaultToSpeaker decision has to be made here
        // too, not just in LocalAudioPlayback. Setting it unconditionally forced
        // BOTH output and input to the built-in hardware even with a headset
        // attached, which is why audio came from the phone mic while wearing
        // headphones. Apply it only when nothing is plugged in.
        Self.applyAudioSessionConfig()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                           decoderFactory: RTCDefaultVideoDecoderFactory())
        super.init()
        // A headset can come and go mid-session, and the config above is a snapshot.
        // Recompute it on every route change so unplugging doesn't leave the mic
        // pinned to a device that's gone (and plugging in actually switches to it).
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioRouteChanged),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    @objc private func audioRouteChanged() {
        Self.applyAudioSessionConfig()
    }

    // `.defaultToSpeaker` forces BOTH output and input onto the built-in hardware,
    // overriding an attached headset — so it may only be set when there is nothing
    // attached. `.allowBluetooth` is what permits the HFP mic on AirPods, so it
    // stays on always. Static because it runs from init, before self exists.
    private static func applyAudioSessionConfig() {
        let session = AVAudioSession.sharedInstance()
        let headphonePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio, .carAudio,
        ]
        let headsetInputs: Set<AVAudioSession.Port> = [.headsetMic, .bluetoothHFP, .usbAudio]
        let attached = session.currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
            || (session.availableInputs ?? []).contains { headsetInputs.contains($0.portType) }

        let rtcConfig = RTCAudioSessionConfiguration.webRTC()
        rtcConfig.category = AVAudioSession.Category.playAndRecord.rawValue
        rtcConfig.mode = AVAudioSession.Mode.voiceChat.rawValue
        rtcConfig.categoryOptions = attached ? [.allowBluetooth] : [.defaultToSpeaker, .allowBluetooth]
        RTCAudioSessionConfiguration.setWebRTC(rtcConfig)
        NexaLog.log("RTC audio config: headset=\(attached) options=\(attached ? "[allowBluetooth]" : "[defaultToSpeaker, allowBluetooth]")")

        // The config above only takes effect the next time WebRTC configures the
        // session. Apply it to the LIVE session too, or an in-progress class keeps
        // using the stale route until the next track change.
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        do { try rtcSession.setConfiguration(rtcConfig, active: true) }
        catch { NexaLog.log("RTC setConfiguration failed: \(error.localizedDescription)") }
        rtcSession.unlockForConfiguration()
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

        // Local mic track, held so we can gate it. It starts DISABLED: the default
        // scene is self-study with the podcast playing, and a live mic there lets
        // the podcast bleed in and self-trigger the server VAD (a phantom turn the
        // moment the session connects). beginListening() (push-to-talk) and
        // enterLive() open it; it closes again whenever the podcast takes the floor.
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "mic0")
        audioTrack.isEnabled = false
        peer.add(audioTrack, streamIds: ["local0"])
        self.micTrack = audioTrack

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
            "turn_detection": turnDetectionConfig(turnMode),
        ]
        send(["type": "session.update", "session": session])
    }

    private func send(_ payload: [String: Any]) {
        let type = payload["type"] as? String ?? "?"
        guard let channel else { NexaLog.log("SEND \(type) DROPPED: no channel"); return }
        guard channel.readyState == .open else {
            NexaLog.log("SEND \(type) DROPPED: channel state=\(channel.readyState.rawValue)"); return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            NexaLog.log("SEND \(type) DROPPED: not serializable"); return
        }
        NexaLog.log("SEND \(type)")
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func stopSpeaking() {
        // Silence the teacher LOCALLY first. response.cancel alone does not stop
        // the voice: audio already sent over the RTP stream keeps rendering (and
        // manual turn control is unreliable on this server's WebRTC path — see
        // setTurnMode), so tapping "interrupt" left the teacher talking. Muting
        // the remote track cuts the voice instantly and does not depend on the
        // server obeying. Keep the reference — dropping it tears down the render.
        remoteAudioTrack?.isEnabled = false
        // response.cancel stops the in-flight response (so it doesn't keep
        // generating), but is only valid while one is actually in flight —
        // otherwise the server answers "Conversation has none active response".
        // stopSpeaking is called defensively on every floor grab, so guard it. Do
        // NOT send output_audio_buffer.clear — that's an OpenAI-only WebRTC event
        // this server rejects with invalid_value.
        guard hasActiveResponse else { return }
        hasActiveResponse = false
        cancelledResponse = true
        send(["type": "response.cancel"])
    }

    /// Answer a tool call, optionally with something for the teacher to read.
    ///
    /// `find_in_episode` needs this: every other tool DOES something and `{"ok":true}` says it all,
    /// but a search has to hand back where it found things or the teacher has nothing to seek to.
    func sendToolResult(callId: String?, ok: Bool, text: String? = nil) {
        var payload: [String: Any] = ["ok": ok]
        if let text { payload["result"] = text }
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":\(ok)}"
        send(["type": "conversation.item.create",
              "item": ["type": "function_call_output", "call_id": callId as Any, "output": json]])
        // A search result is only useful if the teacher speaks after reading it. The other tools
        // are actions the learner already sees happen, so they need no reply.
        if text != nil { requestResponse() }
    }

    func updateContext(_ context: String, scene: ClassroomScene) {
        send(["type": "session.update",
              "session": ["instructions": composeInstructions(instructions, freshContext: context, scene: scene)]])
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

    func setTurnMode(_ mode: TurnMode) {
        // NOTE: turn_detection is fixed at session creation (see sendSessionUpdate)
        // and NOT changed here. Over WebRTC only server-side VAD is honored, and
        // the config can only be set before the first audio frame — so both quick-
        // ask and Live ride the same always-on VAD. Mode only affects how the
        // controller treats the floor/playback, not the transport's turn control.
        turnMode = mode
    }

    func beginListening() {
        // The learner is taking the floor. Enable the mic (it's gated off while
        // the podcast plays) and clear any buffered audio so the turn starts from
        // the moment they pressed, not from podcast bleed before it.
        micTrack?.isEnabled = true
        // Whether the track EXISTS is the thing worth logging. "Live, 等你开口" with no
        // response can mean the mic never opened at all — the UI reports the floor, which is
        // local state, not whether audio is reaching the server.
        NexaLog.log("beginListening: micTrack=\(micTrack == nil ? "nil" : "enabled") sender=\(micSenderState)")
        send(["type": "input_audio_buffer.clear"])
    }

    private var micSenderState: String {
        guard let peer else { return "no-peer" }
        let senders = peer.senders.filter { $0.track?.kind == "audio" }
        return "audioSenders=\(senders.count)"
    }

    func stopListening() {
        // Gate the mic off. Called when the podcast takes the floor: a live mic
        // while the podcast plays lets it bleed into the input, and the server
        // VAD then self-triggers a phantom turn. Clear the buffer too so any
        // already-captured bleed can't be committed as a turn.
        micTrack?.isEnabled = false
        send(["type": "input_audio_buffer.clear"])
    }

    func endTurnAndRespond() {
        // Do NOT manually commit or response.create — WebRTC ignores manual turn
        // control. The server VAD detects the trailing silence after the learner
        // stops speaking and generates the response on its own. Releasing just
        // means "I'm done"; the mic stays live so the VAD can hear that silence
        // and so the learner can barge in on the teacher.
    }

    func cancelTurn() {
        // Slide-up cancel: close the mic, stop any response the VAD may have
        // already started, and drop the captured audio so the turn leaves no
        // trace. Routed through stopSpeaking so the teacher is muted locally and
        // response.cancel stays guarded by hasActiveResponse (sending it with no
        // response in flight draws "Conversation has none active response").
        micTrack?.isEnabled = false
        stopSpeaking()
        send(["type": "input_audio_buffer.clear"])
    }
}

extension QwenRealtimeTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCAudioTrack else { return }
        // Retain on the main actor and enable it. WebRTC renders it to the
        // configured output on its own; our only job is to keep it alive and on.
        Task { @MainActor in
            track.isEnabled = true
            self.remoteAudioTrack = track
        }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // The SERVER opened its own data channel. If events arrive here (not on the
        // channel we created), we must listen on THIS one — otherwise we SEND on
        // ours and RECV nothing.
        NexaLog.log("peer didOpen server dataChannel label=\(dataChannel.label) — switching to it")
        dataChannel.delegate = self
        Task { @MainActor in self.channel = dataChannel }
    }
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        NexaLog.log("ICE state=\(newState.rawValue)")
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

extension QwenRealtimeTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState.rawValue
        NexaLog.log("dataChannel state=\(state)")
        if dataChannel.readyState == .open {
            Task { @MainActor in self.sendSessionUpdate() }
        }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // Log EVERY inbound frame before any filtering — a silently-dropped binary
        // or unparseable frame looks identical to "server sent nothing".
        if buffer.isBinary {
            NexaLog.log("RECV binary frame \(buffer.data.count)B — dropped")
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any] else {
            let raw = String(data: buffer.data, encoding: .utf8)?.prefix(200) ?? "<non-utf8>"
            NexaLog.log("RECV unparseable text frame: \(raw)")
            return
        }
        let type = json["type"] as? String ?? "?"
        // Only failures and turn-boundary events are logged. Logging EVERY frame
        // buried the interesting ones under transcript deltas, which arrive dozens of
        // times per answer.
        if type == "error" || type.hasSuffix(".failed") {
            NexaLog.log("RECV \(type): \(String(describing: json))")
        } else if Self.loggedEventTypes.contains(type) {
            NexaLog.log("RECV \(type)")
        }
        Task { @MainActor in
            // Track response lifecycle so stopSpeaking() only cancels a real
            // in-flight response (see hasActiveResponse).
            switch type {
            case "response.created":
                self.hasActiveResponse = true
                // Un-mute for the new answer. stopSpeaking() mutes the remote
                // track to cut an interrupted teacher off mid-sentence; without
                // restoring it here the teacher would stay silent for the rest
                // of the session after the first interrupt.
                self.remoteAudioTrack?.isEnabled = true
            case "response.done": self.hasActiveResponse = false
            default: break
            }
            // A cancelled response still reports response.done, and forwarding it as
            // "the teacher finished" handed the floor and the scene phase away from a learner
            // who was mid-hold — the "Live, 等你开口 but no answer" bug.
            //
            // Only the TURN-ENDED signal is suppressed. Tool calls ride on this same event
            // (parseAll digs them out of `output`), and a note the teacher saved a moment
            // before the cancel must still be written — dropping the frame wholesale would
            // lose it silently, which is worse than the bug being fixed.
            let wasCancelled = type == "response.done" && self.cancelledResponse
            if wasCancelled {
                self.cancelledResponse = false
                NexaLog.log("response.done for a CANCELLED response — tool calls only")
            }
            // parseAll, not parse: a response.done carrying several tool calls used to
            // yield only the first, so the other saves were dropped AND the .responseDone
            // that hands the floor back was never emitted — the teacher appeared to be
            // still speaking forever.
            let parsed = CancelledResponse.forwarded(RealtimeEventParser.parseAll(json),
                                                     wasCancelled: wasCancelled)
            for event in parsed { self.onEvent?(event) }
        }
    }
}

#else

// STUB TRANSPORT — active only when the WebRTC package is absent (canImport
// fails). The package is now a dependency, so normal builds use the real
// transport above; this remains as a graceful fallback that surfaces a clear
// "not available" error instead of failing to compile. Conforms to the same
// ClassroomTransport protocol — no view/controller changes needed either way.
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
    func sendToolResult(callId: String?, ok: Bool, text: String? = nil) {}
    var isAlive: Bool { false }
    func updateContext(_ context: String, scene: ClassroomScene) {}
    func injectUserText(_ text: String) {}
    func speak(_ text: String) {}
    func requestResponse() {}
    func setTurnMode(_ mode: TurnMode) {}
    func beginListening() {}
    func stopListening() {}
    func endTurnAndRespond() {}
    func cancelTurn() {}
}

#endif
#endif
