import AVFAudio
import Foundation
import OSLog
@preconcurrency import WebRTC

/// Recall's media transport. Application state and all SDK control calls are
/// main-actor owned; SDK delegates copy values and enqueue ordered main callbacks.
@MainActor final class NativeRecallAudio: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()
    private let connect: (String) async throws -> CloudJSON
    private let receive: (String, CloudJSON) -> Void
    private let diagnostics: (CloudJSON) -> Void
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var microphone: RTCAudioTrack?
    private var speaker: RTCAudioTrack?
    private var connectionTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var lostConnection: Task<Void, Never>?
    private var samples: Task<Void, Never>?
    private var echoTail: Task<Void, Never>?
    private var stopped = false
    private var started = false
    private var audioActivated = false
    private var audioRunning = false
    private var paused = false
    private var muted = false
    private var listening = false
    private var interrupted = false
    private var armed = false
    private var playing = false
    private var tutorSpeaking = false
    private var playingResponseID: String?
    private var turnID = ""
    private var responseTurns: [String: String] = [:]
    private let openedAt = ContinuousClock.now
    private let logger = Logger(subsystem: "dev.kiwiapps.Knowledge", category: "VoiceAudio")

    init(connect: @escaping (String) async throws -> CloudJSON,
         receive: @escaping (String, CloudJSON) -> Void, diagnostics: @escaping (CloudJSON) -> Void) {
        self.connect = connect; self.receive = receive; self.diagnostics = diagnostics
    }

    func start() {
        guard connectionTask == nil, !stopped else { return }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.fail("Voice connection timed out. Start voice again.")
        }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await AVAudioApplication.requestRecordPermission() else {
                    fail("Allow microphone access for Knowledge in Settings to use voice."); return
                }
                try Task.checkCancellation(); guard !stopped else { return }
                let audio = RTCAudioSession.sharedInstance()
                audio.add(self)
                audio.useManualAudio = true; audio.isAudioEnabled = false
                audio.lockForConfiguration()
                do {
                    let configuration = RTCAudioSessionConfiguration()
                    configuration.category = AVAudioSession.Category.playAndRecord.rawValue
                    configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
                    configuration.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
                    configuration.sampleRate = 48_000; configuration.ioBufferDuration = 0.01
                    configuration.inputNumberOfChannels = 1; configuration.outputNumberOfChannels = 1
                    RTCAudioSessionConfiguration.setWebRTC(configuration)
                    try audio.setConfiguration(configuration, active: true)
                    audioActivated = true
                    audio.unlockForConfiguration()
                } catch { audio.unlockForConfiguration(); throw error }
                let configuration = RTCConfiguration()
                configuration.sdpSemantics = .unifiedPlan
                let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                guard let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
                    fail("The native voice connection could not be created."); return
                }
                peer = connection
                // The stock iOS device uses Apple's Voice Processing I/O for
                // EC/AGC/NS. Do not override it with another software NS pass.
                let source = Self.factory.audioSource(with: constraints)
                let track = Self.factory.audioTrack(with: source, trackId: "knowledge-microphone")
                track.isEnabled = false; microphone = track
                connection.add(track, streamIds: ["knowledge-voice"])
                guard let events = connection.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) else {
                    fail("The voice event channel could not be created."); return
                }
                channel = events; events.delegate = self
                let offer = try await Self.makeOffer(connection)
                try Task.checkCancellation()
                try await Self.setDescription(offer, on: connection, local: true)
                let gatheringDeadline = ContinuousClock.now + .seconds(10)
                while connection.iceGatheringState != .complete {
                    guard ContinuousClock.now < gatheringDeadline else { throw URLError(.timedOut) }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation(); guard !stopped, let sdp = connection.localDescription?.sdp else { return }
                snapshot("capture")
                let result = try await connect(sdp)
                try Task.checkCancellation(); guard !stopped else { return }
                try await Self.setDescription(RTCSessionDescription(type: .answer, sdp: result.text("sdp")), on: connection, local: false)
                try Task.checkCancellation(); guard !stopped else { return }
                audio.isAudioEnabled = true
                readyIfPossible()
            } catch is CancellationError { }
            catch { if !stopped { fail("Native voice could not connect: " + error.localizedDescription) } }
        }
    }

    // SDK completion handlers run on WebRTC queues. Form them outside actor
    // isolation so they never inherit a main-actor runtime assertion.
    nonisolated private static func makeOffer(_ peer: RTCPeerConnection) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"], optionalConstraints: nil)) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
            }
        }
    }
    nonisolated private static func setDescription(_ description: RTCSessionDescription, on peer: RTCPeerConnection, local: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion: @Sendable (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            if local { peer.setLocalDescription(description, completionHandler: completion) }
            else { peer.setRemoteDescription(description, completionHandler: completion) }
        }
    }

    func stop() {
        guard !stopped else { return }; stopped = true
        connectionTask?.cancel(); connectionTask = nil; deadline?.cancel(); deadline = nil
        lostConnection?.cancel(); lostConnection = nil; samples?.cancel(); samples = nil
        echoTail?.cancel(); echoTail = nil
        microphone?.isEnabled = false; speaker?.isEnabled = false
        RTCAudioSession.sharedInstance().remove(self)
        audioRunning = false
        channel?.delegate = nil; channel?.close(); channel = nil
        peer?.delegate = nil; peer?.close(); peer = nil; microphone = nil; speaker = nil
        if audioActivated {
            let audio = RTCAudioSession.sharedInstance()
            audio.isAudioEnabled = false; audio.lockForConfiguration()
            do { try audio.setActive(false) } catch { logger.error("Native voice audio deactivation failed") }
            audio.unlockForConfiguration(); audioActivated = false
        }
    }
    func setMuted(_ value: Bool) { muted = value; updateTracks() }
    func setPaused(_ value: Bool) { paused = value; updateTracks() }
    func setListening(_ value: Bool, turnID id: String, tutorSpeaking: Bool) {
        listening = value
        let finishedSpeaking = self.tutorSpeaking && !tutorSpeaking
        self.tutorSpeaking = tutorSpeaking
        if id != turnID { turnID = id; armed = false; interrupted = false }
        if finishedSpeaking { holdEchoTail() }
        updateTracks()
    }
    func interruptPlayback() {
        interrupted = true; playing = false; playingResponseID = nil; holdEchoTail()
    }
    func preparePlayback(turnID id: String) -> Bool {
        guard started, audioRunning, !stopped, !paused, !interrupted, !id.isEmpty, id == turnID, speaker != nil, peer?.connectionState == .connected else { return false }
        echoTail?.cancel(); echoTail = nil
        armed = true; updateTracks(); return true
    }
    private func holdEchoTail() {
        echoTail?.cancel()
        let delay = min(0.6, max(0.25, AVAudioSession.sharedInstance().outputLatency + 0.25))
        echoTail = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !stopped, !Task.isCancelled else { return }
            echoTail = nil; updateTracks()
        }
        updateTracks()
    }
    func routeChanged() { updateTracks(); snapshot("route_changed") }
    private func finishPlayback(responseID: String) {
        guard playingResponseID == responseID else { return }
        playingResponseID = nil; playing = false
        holdEchoTail()
    }
    private func updateTracks() {
        let enabled = !stopped && !muted && !paused && listening && !tutorSpeaking && !playing && echoTail == nil
        let changed = microphone != nil && microphone?.isEnabled != enabled
        microphone?.isEnabled = enabled
        speaker?.isEnabled = !stopped && !paused && !interrupted && armed
        if changed { snapshot("microphone_gate") }
    }
    private func readyIfPossible() {
        guard !started, !stopped, audioActivated, audioRunning, RTCAudioSession.sharedInstance().isAudioEnabled,
              peer?.connectionState == .connected, channel?.readyState == .open, speaker != nil else { return }
        started = true; deadline?.cancel(); deadline = nil
        snapshot("connected"); receive("started", .null)
        samples = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !stopped else { return }
                if playing { snapshot("playback_sample") }
            }
        }
    }
    private func fail(_ message: String) { guard !stopped else { return }; receive("error", .object(["message": .string(message)])); stop() }
    private func acceptSpeaker(_ track: RTCAudioTrack) {
        guard !stopped else { return }; track.isEnabled = false; speaker = track; updateTracks(); readyIfPossible()
    }
    private func changedConnection() {
        guard !stopped, let peer else { return }
        lostConnection?.cancel(); lostConnection = nil
        switch peer.connectionState {
        case .failed, .closed: fail("The native voice connection was lost. Start voice again.")
        case .disconnected:
            lostConnection = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.fail("The native voice connection was lost. Start voice again.")
            }
        default: readyIfPossible()
        }
    }
    private func received(_ data: Data) {
        guard !stopped else { return }
        guard data.count <= 1_000_000, let value = try? JSONDecoder().decode(CloudJSON.self, from: data) else { fail("The voice connection returned an unreadable event."); return }
        switch value.text("type") {
        case "response.created":
            let response = value.value("response")
            responseTurns[response.text("id")] = response.value("metadata").text("utteranceID")
            if responseTurns.count > 100 { responseTurns = [response.text("id"): response.value("metadata").text("utteranceID")] }
        case "input_audio_buffer.speech_started":
            snapshot("speech_started")
        case "output_audio_buffer.started":
            let id = value.text("response_id")
            guard responseTurns[id] == turnID else { speaker?.isEnabled = false; return }
            playingResponseID = id; playing = true
            echoTail?.cancel(); echoTail = nil
            updateTracks()
            snapshot("playback_started")
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared": finishPlayback(responseID: value.text("response_id"))
        case "error":
            let error = value.value("error")
            if !["response_cancel_not_active", "response_already_in_progress"].contains(error.text("code")) { fail(error.text("message")) }
        case "session.closed": receive("ended", .null); stop()
        default: break
        }
    }
    private func snapshot(_ phase: String) {
        let duration = openedAt.duration(to: .now).components
        let fields: [String: CloudJSON] = [
            "phase": .string(phase), "elapsedMs": .number(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15),
            "transport": .string("native-webrtc"),
            "audioDeviceRunning": .bool(audioRunning),
            "speakerEchoGuard": .bool(tutorSpeaking || playing || echoTail != nil), "automaticInterruption": .bool(false),
            "echoCancellationRequested": .bool(true), "noiseSuppressionRequested": .bool(true), "autoGainControlRequested": .bool(true),
            // VPIO is selected by the native audio device. Do not manufacture
            // unsupported echo metrics or equate configuration with effectiveness.
            "echoCancellation": .null, "noiseSuppression": .null, "autoGainControl": .null,
            "microphoneEnabled": .bool(microphone?.isEnabled == true), "outputMuted": .bool(speaker?.isEnabled != true),
            "tutorPlaying": .bool(playing), "paused": .bool(paused), "userMuted": .bool(muted), "serverListening": .bool(listening),
            "statsAvailable": .bool(false), "echoReturnLoss": .null, "echoReturnLossEnhancement": .null
        ]
        guard let peer else { diagnostics(.object(fields)); return }
        Self.collectStatistics(peer) { [weak self] measurements in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.diagnostics(.object(fields.merging(measurements) { _, value in value }))
            }
        }
    }
    nonisolated private static func collectStatistics(_ peer: RTCPeerConnection, completion: @escaping @Sendable ([String: CloudJSON]) -> Void) {
        peer.statistics { report in
            var fields: [String: CloudJSON] = ["statsAvailable": .bool(false)]
            for stat in report.statistics.values {
                guard stat.values["kind"] as? String == "audio" else { continue }
                if stat.type == "media-source" || stat.type == "inbound-rtp" {
                    fields["statsAvailable"] = .bool(true)
                    let keys = stat.type == "media-source" ? ["audioLevel": "microphoneLevel", "echoReturnLoss": "echoReturnLoss", "echoReturnLossEnhancement": "echoReturnLossEnhancement"] : ["audioLevel": "remoteLevel"]
                    for (source, destination) in keys {
                        if let value = (stat.values[source] as? NSNumber)?.doubleValue, value.isFinite { fields[destination] = .number(value) }
                    }
                }
            }
            completion(fields)
        }
    }
}

extension NativeRecallAudio: RTCPeerConnectionDelegate, RTCDataChannelDelegate, RTCAudioSessionDelegate {
    nonisolated func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.audioRunning = true; self.readyIfPossible()
        }
    }
    nonisolated func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.audioRunning = false
            if self.started { self.fail("Native voice audio stopped. Start voice again.") }
        }
    }
    nonisolated func audioSessionDidBeginInterruption(_ session: RTCAudioSession) {
        DispatchQueue.main.async { [weak self] in self?.fail("Voice audio was interrupted. Start voice again to resume.") }
    }
    nonisolated func audioSession(_ session: RTCAudioSession, audioUnitStartFailedWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.fail("The native voice audio device could not start. Start voice again.") }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let track = stream.audioTracks.first else { return }
        track.isEnabled = false
        DispatchQueue.main.async { [weak self] in self?.acceptSpeaker(track) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCAudioTrack else { return }
        track.isEnabled = false
        DispatchQueue.main.async { [weak self] in self?.acceptSpeaker(track) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async { [weak self] in self?.changedConnection() }
    }
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let closed = dataChannel.readyState == .closed
        DispatchQueue.main.async { [weak self] in
            guard let self, !stopped else { return }
            if closed { fail("The native voice event channel closed. Start voice again.") } else { readyIfPossible() }
        }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = Data(buffer.data)
        DispatchQueue.main.async { [weak self] in self?.received(data) }
    }
}
