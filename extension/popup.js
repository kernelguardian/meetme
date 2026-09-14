const $ = s => document.querySelector(s);
const keepAlive = chrome.runtime.connect({ name: 'meetme-ui' });
let current = { phase: 'idle', recording: null, micEnabled: false, error: null };
let preferredMic = true;
function show(state) {
  current = { ...current, ...state }; $('#mic').checked = !!current.micEnabled;
  const captureActive = ['starting', 'recording', 'stopping'].includes(current.phase);
  $('#mic').checked = captureActive ? !!current.micEnabled : preferredMic;
  $('#mic').disabled = !['idle', 'recording'].includes(current.phase);
  $('#record').textContent = current.phase === 'recording' ? 'Stop recording' : current.phase === 'stopping' ? 'Stopping…' : current.phase === 'starting' ? 'Starting…' : 'Record this tab';
  $('#record').disabled = ['starting', 'stopping'].includes(current.phase);
  $('#status').textContent = current.phase === 'recording' ? `Recording ${current.recording?.title || 'meeting'}` : current.phase === 'error' ? 'Recording needs attention' : 'Ready to record this tab';
  $('#error').hidden = !current.error; $('#error').textContent = current.error || '';
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
