// Credential-free audio transport, hosted on an HTTPS origin for microphone access.
// UI, credentials, transcript presentation and subject retrieval stay native.
export function subjectVoiceHTML(nonce: string) {
  return String.raw`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body><audio id="audio" autoplay playsinline></audio><script nonce="${nonce}">
(() => {
  const audio = document.getElementById('audio');
  const bridge = body => window.webkit.messageHandlers.subjectVoice.postMessage(body);
  let peer, stream, events, timer, closeTimer, lostTimer, run = 0, ready = false, ending = false;
  const seen = new Set();
  function cleanup() {
    run++; ready = false; ending = false;
    clearTimeout(timer); clearTimeout(closeTimer); clearTimeout(lostTimer);
    stream?.getTracks().forEach(track => track.stop()); stream = null;
    if (events) { events.onclose = null; events.close(); events = null; }
    if (peer) { peer.onconnectionstatechange = null; peer.close(); peer = null; }
    audio.pause(); audio.srcObject = null;
  }
  function report(type, fields = {}) { return bridge({ type, ...fields }).catch(() => {}); }
  function fail(message) { report('error', { message }); cleanup(); }
  function send(value) { if (events?.readyState === 'open') events.send(JSON.stringify(value)); }
  function stop(immediate = false) {
    if (ending) { if (immediate) cleanup(); return; }
    ending = true;
    stream?.getTracks().forEach(track => track.stop()); audio.pause();
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
    cleanup(); const current = run; seen.clear();
    timer = setTimeout(() => { if (current === run) fail('Voice connection timed out. Try starting voice again.'); }, 60000);
    try {
      const captured = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }, video: false });
      if (current !== run) { captured.getTracks().forEach(track => track.stop()); return; }
      stream = captured; const connection = new RTCPeerConnection(); peer = connection;
      connection.ontrack = event => {
        if (current !== run) return;
        audio.srcObject = event.streams[0] || new MediaStream([event.track]);
        audio.play().catch(() => { if (current === run) fail('Voice playback could not start. Check the audio output and try again.'); });
      };
      connection.onconnectionstatechange = () => {
        if (current !== run) return;
        clearTimeout(lostTimer);
        if (connection.connectionState === 'failed') fail('Voice connection failed.');
        if (connection.connectionState === 'disconnected') lostTimer = setTimeout(() => { if (current === run) fail('Voice connection was lost.'); }, 10000);
      };
      stream.getTracks().forEach(track => connection.addTrack(track, stream));
      events = connection.createDataChannel('oai-events');
      events.onmessage = message => {
        if (current !== run) return;
        try {
          const event = JSON.parse(message.data);
          if (event.type === 'session.started') { ready = true; clearTimeout(timer); report('started'); }
          if (event.type === 'session.input_transcript.delta' || event.type === 'session.output_transcript.delta')
            report('transcript', { role: event.type === 'session.input_transcript.delta' ? 'user' : 'assistant', delta: event.delta, start: event.start_ms, end: event.end_ms });
          if (event.type === 'session.delegation.created') void delegate(event, current);
          if (event.type === 'error') fail(event.error?.message || 'The voice session reported an error.');
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
  window.subjectVoice = { start, stop };
  window.addEventListener('pagehide', () => stop(true));
  document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); });
})();
</script></body></html>`;
}
