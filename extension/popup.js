const $ = s => document.querySelector(s);
const keepAlive = chrome.runtime.connect({ name: 'meetme-ui' });
let current = { phase: 'idle', recording: null, micEnabled: false, error: null };
let preferredMic = true;
let elapsedTimer;
const PHASES = {
  idle: { label: 'Ready', pill: '' },
  starting: { label: 'Starting', pill: 'pill-busy' },
  recording: { label: 'Recording', pill: 'pill-rec' },
  stopping: { label: 'Saving', pill: 'pill-busy' },
  error: { label: 'Attention', pill: 'pill-bad' },
};
function clock(seconds) {
  const parts = [Math.floor(seconds / 3600), Math.floor((seconds % 3600) / 60), seconds % 60];
  return (parts[0] ? parts : parts.slice(1)).map((part, index) => index ? String(part).padStart(2, '0') : String(part)).join(':');
}
function renderElapsed() {
  const startedAt = Date.parse(current.recording?.createdAt ?? '');
  const field = $('#elapsed');
  if (current.phase !== 'recording' || !Number.isFinite(startedAt)) { field.hidden = true; return; }
  field.hidden = false;
  field.textContent = clock(Math.max(0, Math.round((Date.now() - startedAt) / 1000)));
}
function show(state) {
  current = { ...current, ...state };
  const captureActive = ['starting', 'recording', 'stopping'].includes(current.phase);
  $('#mic').checked = captureActive ? !!current.micEnabled : preferredMic;
  $('#mic').disabled = !['idle', 'recording'].includes(current.phase);
  $('#record').textContent = current.phase === 'recording' ? 'Stop recording' : current.phase === 'stopping' ? 'Stopping…' : current.phase === 'starting' ? 'Starting…' : 'Record this tab';
  $('#record').disabled = ['starting', 'stopping'].includes(current.phase);
  $('#record').classList.toggle('btn-danger', current.phase === 'recording');
  $('#record').classList.toggle('btn-primary', current.phase !== 'recording');
  // The phase pill already says what is happening, so the line names the meeting.
  $('#status').textContent = current.phase === 'recording' ? (current.recording?.title || 'Untitled meeting') : current.phase === 'error' ? 'Recording needs attention' : 'Ready to record this tab';
  const phase = PHASES[current.phase] || PHASES.idle;
  $('#phase').textContent = phase.label;
  $('#phase').className = `pill ${phase.pill}`.trim();
  $('#error').hidden = !current.error; $('#error').textContent = current.error || '';
  clearInterval(elapsedTimer);
  if (current.phase === 'recording') elapsedTimer = setInterval(renderElapsed, 1000);
  renderElapsed();
}
async function request(type, extra = {}) { const reply = await chrome.runtime.sendMessage({ type, ...extra }); if (!reply?.ok) throw new Error(reply?.error || 'MeetMe did not respond.'); return reply.result; }
$('#record').addEventListener('click', async () => {
  const stopping = current.phase === 'recording';
  const micEnabled = $('#mic').checked;
  try {
    show({ phase: stopping ? 'stopping' : 'starting', error: null });
    const result = await request(stopping ? 'stop-capture' : 'start-capture', { micEnabled });
    show(result || {});
  } catch (error) { show({ phase: 'error', error: error.message }); }
});
$('#mic').addEventListener('change', async () => {
  const enabled = $('#mic').checked;
  if (current.phase !== 'recording') {
    preferredMic = enabled;
    try { await chrome.storage.local.set({ includeMyMicrophone: preferredMic }); }
    catch (error) { show({ error: `Could not save microphone preference: ${error.message}` }); }
    return;
  }
  try {
    const result = await request('toggle-mic', { enabled });
    preferredMic = !!result?.micEnabled;
    await chrome.storage.local.set({ includeMyMicrophone: preferredMic });
    show(result);
  } catch (error) { show({ error: error.message }); }
});
chrome.runtime.onMessage.addListener(message => { if (message.type === 'capture-state') show(message.state); });
chrome.storage.local.get('includeMyMicrophone').then(({ includeMyMicrophone }) => {
  if (typeof includeMyMicrophone === 'boolean') preferredMic = includeMyMicrophone;
  if (!['starting', 'recording', 'stopping'].includes(current.phase)) show(current);
}).catch(() => {});
request('get-capture-state').then(show).catch(error => show({ phase: 'error', error: error.message }));
