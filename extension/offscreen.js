const MAX_QUEUE_BYTES = 64 * 1024 * 1024;
const MAX_CHUNK_BYTES = 32 * 1024 * 1024;
const TIMESLICE_MS = 4_000;
const UPLOAD_TIMEOUT_MS = 20_000;
let session;
const send = message => chrome.runtime.sendMessage({ target: 'background', ...message });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function checksum(blob) { const hash = await crypto.subtle.digest('SHA-256', await blob.arrayBuffer()); return [...new Uint8Array(hash)].map(x => x.toString(16).padStart(2, '0')).join(''); }
function mimeType() { return ['video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm'].find(MediaRecorder.isTypeSupported) || ''; }
async function native(command, params, timeout = 30_000) {
  const reply = await chrome.runtime.sendMessage({ target: 'background', type: 'native-request', command, params, timeout });
  if (!reply?.ok) throw new Error(reply?.error || `Native ${command} failed`);
  return reply.result;
}
async function fetchWithTimeout(url, options, timeout = UPLOAD_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error('Chunk upload timed out')), timeout);
  try { return await fetch(url, { ...options, signal: controller.signal }); }
  finally { clearTimeout(timer); }
}
async function postChunk(item, capture) {
  let lastError;
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      if (session !== capture || capture.completing) throw new Error('Capture ended during upload');
      const hello = await native('hello', {}, UPLOAD_TIMEOUT_MS);
      const response = await fetchWithTimeout(`${hello.baseURL}/recordings/${encodeURIComponent(capture.recordingId)}/chunks/${item.sequence}`, { method: 'POST', headers: { Authorization: `Bearer ${hello.token}`, 'X-Content-SHA256': item.sha256, 'X-Chunk-Length': String(item.blob.size), 'Content-Type': 'application/octet-stream' }, body: item.blob });
      if (!response.ok) throw new Error(`Chunk upload failed (${response.status})`);
      const ack = await response.json();
      if (ack.sequence !== item.sequence) throw new Error('Chunk acknowledgement sequence mismatch');
      return ack;
    } catch (error) { if (session !== capture || capture.completing) throw error; lastError = error; await delay(500 * 2 ** attempt); }
  }
  throw lastError;
}
async function drain() {
  const capture = session;
  if (!capture || capture.uploading) return;
  capture.uploading = true;
  try {
    while (session === capture && capture.queue.length && capture.queue[0].sequence === capture.nextUploadSequence) {
      const item = capture.queue[0]; await postChunk(item, capture);
      if (session !== capture) return;
      capture.queue.shift(); capture.queuedBytes -= item.blob.size; capture.committedBytes += item.blob.size;
      capture.nextUploadSequence += 1;
    }
    if (session === capture && capture.stopped && capture.pendingData === 0) await complete();
  } catch (error) { await fail(error, capture); }
  finally { capture.uploading = false; }
}
async function complete() {
  if (!session || session.completing || session.queue.length || session.pendingData) return;
  session.completing = true;
  const result = { type: 'offscreen-finished', recordingId: session.recordingId, chunkCount: session.sequence, totalBytes: session.totalBytes };
  cleanup(); await send(result);
}
function cleanup() {
  if (!session) return;
  if (session.recorder?.state === 'recording') session.recorder.stop();
  for (const stream of [session.tabStream, session.micStream]) stream?.getTracks().forEach(track => track.stop());
  session.audioContext?.close().catch(() => {}); session = undefined;
}
async function fail(error, expectedSession = session) {
  if (!expectedSession || expectedSession !== session || expectedSession.completing) return;
  expectedSession.completing = true;
  const result = { type: 'offscreen-finished', recordingId: expectedSession.recordingId, error: error.message || String(error) };
  cleanup();
  await send(result);
}
async function start({ recordingId, streamId, micEnabled, microphoneDeviceId }) {
  if (session) throw new Error('Offscreen capture already running');
  let tabStream;
  let micStream;
  let audioContext;
  try {
    tabStream = await navigator.mediaDevices.getUserMedia({ audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } }, video: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId, maxWidth: 1280, maxHeight: 720, maxFrameRate: 15 } } });
    audioContext = new AudioContext();
    const destination = audioContext.createMediaStreamDestination();
    const remote = audioContext.createMediaStreamSource(tabStream); remote.connect(destination); remote.connect(audioContext.destination);
    await audioContext.resume();
    let warning;
    if (micEnabled) {
      try { micStream = await navigator.mediaDevices.getUserMedia({ audio: { ...(microphoneDeviceId ? { deviceId: { exact: microphoneDeviceId } } : {}), echoCancellation: true, noiseSuppression: true, autoGainControl: true }, video: false }); audioContext.createMediaStreamSource(micStream).connect(destination); }
      catch (error) { warning = `Microphone unavailable; recording remote audio only: ${error.message}`; }
    }
    const output = new MediaStream([...tabStream.getVideoTracks(), ...destination.stream.getAudioTracks()]);
    session = { recordingId, tabStream, micStream, audioContext, destination, queue: [], queuedBytes: 0, pendingBytes: 0, pendingData: 0, totalBytes: 0, committedBytes: 0, sequence: 0, nextUploadSequence: 0, uploading: false, stopped: false, completing: false };
    const recorder = new MediaRecorder(output, { mimeType: mimeType(), videoBitsPerSecond: 2_000_000 });
    session.recorder = recorder;
    const activeSession = session;
    for (const track of tabStream.getTracks()) {
      track.addEventListener?.('ended', () => {
        if (session === activeSession && !activeSession.completing && recorder.state !== 'inactive') recorder.stop();
      }, { once: true });
    }
    for (const track of micStream?.getAudioTracks() || []) {
      track.addEventListener?.('ended', () => {
        if (session === activeSession && !activeSession.completing) {
          send({ type: 'offscreen-status', warning: 'Microphone disconnected; recording remote audio only.', micEnabled: false }).catch(() => {});
        }
      }, { once: true });
    }
    recorder.ondataavailable = async ({ data }) => {
      const capture = session;
      if (!data.size || !capture || capture.completing) return;
      if (data.size > MAX_CHUNK_BYTES) return fail(new Error('Recorder produced a chunk larger than 32 MiB.'), capture);
      if (capture.queuedBytes + capture.pendingBytes + data.size > MAX_QUEUE_BYTES) return fail(new Error('Upload queue reached 64 MiB; recording stopped to preserve disk-backed data.'), capture);
      capture.pendingData += 1; capture.pendingBytes += data.size;
      try {
        const item = { blob: data, sequence: capture.sequence++, sha256: await checksum(data) };
        if (session !== capture || capture.completing) return;
        capture.totalBytes += data.size; capture.queuedBytes += data.size; capture.queue.push(item); capture.queue.sort((a, b) => a.sequence - b.sequence);
      } catch (error) { await fail(error, capture); return; }
      finally { capture.pendingData -= 1; capture.pendingBytes -= data.size; }
      drain();
    };
    recorder.onerror = event => { void fail(event.error || new Error('Media recorder error')); };
    recorder.onstop = () => { if (session) { session.stopped = true; drain(); } };
    recorder.start(TIMESLICE_MS);
    return { micEnabled: !!micStream, warning };
  } catch (error) {
    if (session?.tabStream === tabStream) session = undefined;
    for (const stream of [tabStream, micStream]) stream?.getTracks().forEach(track => track.stop());
    await audioContext?.close().catch(() => {});
    throw error;
  }
}
chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message?.target !== 'offscreen') return false;
  (async () => {
    if (message.type === 'offscreen-start') return start(message);
    if (message.type === 'offscreen-stop') {
      if (!session?.recorder) throw new Error('No active offscreen capture');
      if (session.recorder.state !== 'inactive') session.recorder.stop();
      return { stopping: true };
    }
    if (message.type === 'offscreen-mic') {
      if (!session?.micStream) return { micEnabled: false, warning: 'Microphone is unavailable for this recording.' };
      session.micStream.getAudioTracks().forEach(track => { track.enabled = !!message.enabled; });
      return { micEnabled: !!message.enabled };
    }
    throw new Error('Unknown offscreen message');
  })().then(result => respond({ ok: true, result })).catch(error => respond({ ok: false, error: error.message }));
  return true;
});
