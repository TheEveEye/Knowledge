// Credential-free audio transport, hosted on an HTTPS origin for microphone access.
// UI, credentials, transcript presentation and subject retrieval stay native.
export function subjectVoiceHTML(nonce: string, recall = false) {
  return String.raw`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body><audio id="audio" autoplay playsinline></audio><script nonce="${nonce}">
(() => {
  const audio = document.getElementById('audio');
  const bridge = body => window.webkit.messageHandlers.subjectVoice.postMessage(body);
  const recall = ${recall};
  let peer, stream, events, timer, closeTimer, lostTimer, run = 0, ready = false, ending = false;
  let outputAllowed = true, paused = false, userMuted = false;
  let serverListening = !recall, localSpeaking = false, interrupted = false, expectedTurn = '', drainTimer;
  let diagnosticTimer, diagnosticPending = false, diagnosticStarted = 0;
  const responseTurns = new Map();
  audio.muted = recall;
  function updateMic() {
    stream?.getAudioTracks().forEach(track => { track.enabled = !userMuted && !paused && (!recall || serverListening); });
  }
  const seen = new Set();
  function cleanup() {
    run++; ready = false; ending = false;
    clearTimeout(timer); clearTimeout(closeTimer); clearTimeout(lostTimer); clearTimeout(drainTimer);
    clearInterval(diagnosticTimer); diagnosticTimer = null; diagnosticPending = false;
    localSpeaking = false; responseTurns.clear();
    stream?.getTracks().forEach(track => track.stop()); stream = null;
    if (events) { events.onclose = null; events.close(); events = null; }
    if (peer) { peer.onconnectionstatechange = null; peer.close(); peer = null; }
    audio.pause(); audio.srcObject = null;
  }
  function report(type, fields = {}) { return bridge({ type, ...fields }).catch(() => {}); }
  async function diagnoseAudio(phase) {
    if (!recall || ending || !stream || diagnosticPending) return;
    const current = run, connection = peer, track = stream.getAudioTracks()[0];
    if (!track) return;
    diagnosticPending = true;
    try {
      const settings = track.getSettings(), supported = navigator.mediaDevices.getSupportedConstraints();
      const numeric = value => typeof value === 'number' && Number.isFinite(value) ? value : null;
      const boolean = value => typeof value === 'boolean' ? value : null;
      const diagnostics = {
        phase, elapsedMs: Math.round(performance.now() - diagnosticStarted),
        echoCancellationRequested: true, noiseSuppressionRequested: true, autoGainControlRequested: true,
        echoCancellationSupported: supported.echoCancellation === true,
        noiseSuppressionSupported: supported.noiseSuppression === true,
        autoGainControlSupported: supported.autoGainControl === true,
        echoCancellation: ['all', 'remote-only'].includes(settings.echoCancellation) ? settings.echoCancellation : boolean(settings.echoCancellation),
        noiseSuppression: boolean(settings.noiseSuppression), autoGainControl: boolean(settings.autoGainControl),
        sampleRate: numeric(settings.sampleRate), channelCount: numeric(settings.channelCount),
        captureLatency: numeric(settings.latency), microphoneEnabled: track.enabled, microphoneMuted: track.muted,
        tutorPlaying: localSpeaking, outputMuted: audio.muted, paused, userMuted, serverListening,
        statsAvailable: false, statsFailed: false,
        microphoneLevel: null, remoteLevel: null, echoReturnLoss: null, echoReturnLossEnhancement: null,
      };
      try {
        if (connection) {
          const stats = await connection.getStats();
          for (const stat of stats.values()) {
            if (stat.type === 'media-source' && stat.kind === 'audio') {
              diagnostics.statsAvailable = true;
              diagnostics.microphoneLevel = numeric(stat.audioLevel);
              diagnostics.echoReturnLoss = numeric(stat.echoReturnLoss);
              diagnostics.echoReturnLossEnhancement = numeric(stat.echoReturnLossEnhancement);
            } else if (stat.type === 'inbound-rtp' && stat.kind === 'audio') {
              diagnostics.statsAvailable = true;
              diagnostics.remoteLevel = numeric(stat.audioLevel);
            }
          }
        }
      } catch { diagnostics.statsFailed = true; }
      // Only allowlisted settings and aggregate measurements cross the bridge.
      // Never send device names/IDs, SDP, IP addresses, speech or audio samples.
      if (current === run && !ending) await report('audioDiagnostics', { diagnostics });
    } catch {
      // Optional diagnostics must never break capture or playback.
      if (current === run && !ending) await report('audioDiagnostics', { diagnostics: { phase, diagnosticsFailed: true } });
    } finally { if (current === run) diagnosticPending = false; }
  }
  function startRecallIfReady(current) {
    if (!recall || current !== run || ready || ending || events?.readyState !== 'open' || peer?.connectionState !== 'connected' || !audio.srcObject) return;
    ready = true; clearTimeout(timer); report('started');
    void diagnoseAudio('connected');
  }
  function fail(message) { report('error', { message }); cleanup(); }
  function send(value) { if (events?.readyState === 'open') events.send(JSON.stringify(value)); }
  function stop(immediate = false) {
    if (ending) { if (immediate) cleanup(); return; }
    ending = true;
    stream?.getTracks().forEach(track => track.stop()); audio.pause();
    // Recall's authenticated backend hangs up the Realtime call. Close local
    // capture immediately; session.close belongs to GPT-Live subject chat only.
    if (recall) { report('ended'); cleanup(); return; }
    if (ready && events?.readyState === 'open') {
      try { send({ type: 'session.close' }); } catch { cleanup(); return; }
      closeTimer = setTimeout(() => { report('ended'); cleanup(); }, 5000);
      if (immediate) cleanup();
    } else { report('ended'); cleanup(); }
  }
  // Every append is <=450 UTF-8 bytes, also bounding it below the 500-token API limit.
  function chunks(text) {
    const result = []; let part = '';
    for (const character of text) {
      if (new TextEncoder().encode(part + character).length > 450) { result.push(part); part = ''; }
      part += character;
    }
    if (part) result.push(part);
    return result;
  }
  async function delegate(event, current) {
    const id = event.delegation?.id;
    if (!id || seen.has(id) || ending) return;
    seen.add(id);
    try {
      // Give transcript fragments in flight a short opportunity to arrive. The
      // native side uses timestamps, never an inferred silent turn boundary.
      await new Promise(resolve => setTimeout(resolve, 350));
      if (current !== run || ending) return;
      const result = await bridge({ type: 'delegate', id, offset: event.offset_ms || 0 });
      if (current !== run || ending) return;
      // Feed the complete result as context before requesting speech. Individual
      // transport chunks are not independently meaningful spoken answers.
      for (const content of chunks(result.text)) send({ type: 'session.thinking.append', event_id: crypto.randomUUID(), delegation_id: id, content });
      send({ type: 'session.commentary.append', event_id: crypto.randomUUID(), delegation_id: id,
        content: 'The subject lookup has finished. Answer the user using the complete grounded result just provided. Preserve its qualifications; do not read citation URLs aloud.' });
    } catch (error) {
      if (current !== run || ending) return;
      report('error', { message: String(error.message || error) });
      send({ type: 'session.commentary.append', event_id: crypto.randomUUID(), delegation_id: id,
        content: 'The subject lookup failed. Tell the user that you could not check the saved material. Do not guess an answer.' });
    }
  }
  async function start() {
    cleanup(); const current = run; seen.clear(); diagnosticStarted = performance.now();
    timer = setTimeout(() => { if (current === run) fail('Voice connection timed out. Try starting voice again.'); }, 60000);
    try {
      const captured = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }, video: false });
      if (current !== run) { captured.getTracks().forEach(track => track.stop()); return; }
      stream = captured; updateMic(); const connection = new RTCPeerConnection(); peer = connection;
      void diagnoseAudio('capture');
      if (recall) diagnosticTimer = setInterval(() => { if (current === run && localSpeaking) void diagnoseAudio('playback_sample'); }, 2000);
      connection.ontrack = event => {
        if (current !== run) return;
        audio.srcObject = event.streams[0] || new MediaStream([event.track]);
        audio.play().catch(() => { if (current === run) fail('Voice playback could not start. Check the audio output and try again.'); });
        startRecallIfReady(current);
      };
      connection.onconnectionstatechange = () => {
        if (current !== run) return;
        clearTimeout(lostTimer);
        if (connection.connectionState === 'failed') fail('Voice connection failed.');
        if (connection.connectionState === 'disconnected') lostTimer = setTimeout(() => { if (current === run) fail('Voice connection was lost.'); }, 10000);
        startRecallIfReady(current);
      };
      stream.getTracks().forEach(track => connection.addTrack(track, stream));
      events = connection.createDataChannel('oai-events');
      events.onopen = () => {
        startRecallIfReady(current);
      };
      events.onmessage = message => {
        if (current !== run) return;
        try {
          const event = JSON.parse(message.data);
          if (recall && event.type === 'input_audio_buffer.speech_started' && serverListening && !paused && !userMuted) {
            void diagnoseAudio('speech_started');
            // Stop the phone's playback immediately. The authenticated sideband
            // receives the same event and cancels/clears the tutor response.
            interrupt();
          }
          if (recall && event.type === 'response.created') {
            responseTurns.set(event.response.id, event.response.metadata?.utteranceID || '');
            if (responseTurns.size > 100) responseTurns.delete(responseTurns.keys().next().value);
          }
          if (recall && event.type === 'output_audio_buffer.started') {
            clearTimeout(drainTimer); localSpeaking = true; updateMic();
            audio.muted = paused || !outputAllowed || interrupted || responseTurns.get(event.response_id) !== expectedTurn;
            void diagnoseAudio('playback_started');
          }
          if (recall && (event.type === 'output_audio_buffer.stopped' || event.type === 'output_audio_buffer.cleared')) {
            clearTimeout(drainTimer);
            drainTimer = setTimeout(() => { if (current === run) { localSpeaking = false; updateMic(); } }, 250);
          }
          if (!recall && event.type === 'session.started') { ready = true; clearTimeout(timer); report('started'); }
          if (!recall && (event.type === 'session.input_transcript.delta' || event.type === 'session.output_transcript.delta'))
            report('transcript', { role: event.type === 'session.input_transcript.delta' ? 'user' : 'assistant', delta: event.delta, start: event.start_ms, end: event.end_ms });
          if (!recall && event.type === 'session.delegation.created') void delegate(event, current);
          if (event.type === 'error' && !['response_cancel_not_active', 'response_already_in_progress'].includes(event.error?.code)) fail(event.error?.message || 'The voice session reported an error.');
          if (event.type === 'session.closed') { report('ended'); cleanup(); }
        } catch { fail('The voice session returned an unreadable event.'); }
      };
      events.onclose = () => { if (current === run) fail('Voice connection closed.'); };
      await connection.setLocalDescription(await connection.createOffer());
      await new Promise((resolve, reject) => {
        if (connection.iceGatheringState === 'complete') { resolve(); return; }
        const timeout = setTimeout(() => { connection.removeEventListener('icegatheringstatechange', changed); reject(new Error('Voice connection negotiation timed out.')); }, 10000);
        function changed() { if (connection.iceGatheringState === 'complete') { clearTimeout(timeout); connection.removeEventListener('icegatheringstatechange', changed); resolve(); } }
        connection.addEventListener('icegatheringstatechange', changed);
      });
      if (current !== run) return;
      const result = await bridge({ type: 'connect', sdp: connection.localDescription.sdp });
      if (current !== run) return;
      await connection.setRemoteDescription({ type: 'answer', sdp: result.sdp });
    } catch (error) { if (current === run) fail(String(error.message || error)); }
  }
  function mute(value) { userMuted = value; updateMic(); }
  function listen(value, turnID) {
    serverListening = value;
    if (turnID !== expectedTurn) { expectedTurn = turnID; interrupted = false; audio.muted = true; }
    updateMic();
  }
  function interrupt() { interrupted = true; audio.muted = true; localSpeaking = false; updateMic(); }
  function preparePlayback(turnID) {
    if (!recall || ending || !ready || !turnID || turnID !== expectedTurn || paused || interrupted || !outputAllowed || !audio.srcObject || peer?.connectionState !== 'connected') return false;
    // The native owner awaits this before acknowledging presentation to the
    // server. RTP audio can precede data-channel output_audio_buffer.started;
    // open the approved turn's playback gate before speech is generated.
    audio.muted = false;
    return true;
  }
  function output(enabled) { outputAllowed = enabled; audio.muted = paused || !enabled; }
  function pause(value) { paused = value; updateMic(); audio.muted = value || !outputAllowed || interrupted; }
  window.subjectVoice = { start, stop, mute, pause, output, listen, interrupt, preparePlayback };
  window.addEventListener('pagehide', () => stop(true));
  document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); });
})();
</script></body></html>`;
}
