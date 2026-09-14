const $ = s => document.querySelector(s);
const keepAlive = chrome.runtime.connect({ name: 'meetme-ui' });
let polling;

async function native(command, params = {}) {
  const reply = await chrome.runtime.sendMessage({ type: 'native-request', command, params });
  if (!reply?.ok) throw new Error(reply?.error || 'The MeetMe helper did not respond.');
  return reply.result;
}
function modelLabel(model) { return String(model || '').replace('openai_whisper-', 'Whisper '); }
function modelMessage(state) {
  if (state.downloadError) return `Download failed: ${state.downloadError}`;
  if (state.downloading) return `Downloading ${modelLabel($('#model').value)}…`;
  return state.modelReady ? `${modelLabel($('#model').value)} is downloaded.` : `${modelLabel($('#model').value)} has not been downloaded.`;
}
async function loadDevices() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  $('#device').replaceChildren(new Option('Default microphone', ''), ...devices.filter(d => d.kind === 'audioinput').map(d => new Option(d.label || `Microphone ${d.deviceId.slice(0, 6)}`, d.deviceId)));
}
async function refreshStatus() {
  try {
    const state = await native('status');
    $('#model-status').textContent = modelMessage(state);
    $('#download').disabled = !!state.downloading || !!state.processing || !!state.recordingId;
    $('#summary-status').textContent = state.summaryAvailable === 'available' ? 'On-device summaries are available.' : `On-device summaries unavailable: ${state.summaryAvailable || 'unknown reason'}`;
  } catch (error) {
    $('#model-status').textContent = `Helper unavailable: ${error.message}`;
    $('#download').disabled = true;
  }
}
async function run(button, operation, onError) {
  button.disabled = true;
  try { await operation(); }
  catch (error) { onError(error); }
  finally { button.disabled = false; }
}

$('#folder').onclick = () => run($('#folder'), async () => {
  const result = await native('chooseFolder');
  $('#library').textContent = result.libraryPath || 'No folder selected';
}, error => { $('#library').textContent = `Folder selection failed: ${error.message}`; });
$('#grant').onclick = () => run($('#grant'), async () => {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  stream.getTracks().forEach(track => track.stop());
  await loadDevices();
  $('#mic-status').textContent = 'Microphone access granted.';
}, error => { $('#mic-status').textContent = `Microphone unavailable: ${error.message}`; });
$('#save').onclick = () => run($('#save'), async () => {
  const result = await native('settings', { model: $('#model').value });
  $('#model').value = result.model;
  $('#model-status').textContent = `Saved ${modelLabel(result.model)}.`;
  await refreshStatus();
}, error => { $('#model-status').textContent = `Could not save model: ${error.message}`; });
$('#device').onchange = async () => {
  try { await chrome.storage.local.set({ microphoneDeviceId: $('#device').value }); }
  catch (error) { $('#mic-status').textContent = `Could not save microphone: ${error.message}`; }
};
$('#download').onclick = async () => {
  $('#download').disabled = true;
  try {
    const result = await native('downloadModel');
    $('#model-status').textContent = result.queued ? `Downloading ${modelLabel($('#model').value)}…` : 'Download unavailable.';
    await refreshStatus();
  } catch (error) {
    $('#model-status').textContent = `Could not download model: ${error.message}`;
    $('#download').disabled = false;
  }
};

(async () => {
  try {
    const [hello, settings, local] = await Promise.all([native('hello'), native('settings'), chrome.storage.local.get('microphoneDeviceId')]);
    $('#library').textContent = settings.libraryPath || hello.libraryPath || 'No folder selected';
    $('#model').value = settings.model || hello.model || 'openai_whisper-base';
    try { await loadDevices(); }
    catch (error) { $('#mic-status').textContent = `Microphone list unavailable: ${error.message}`; }
    $('#device').value = local.microphoneDeviceId || '';
    await refreshStatus();
    polling = setInterval(refreshStatus, 3_000);
  } catch (error) {
    $('#library').textContent = `Helper unavailable: ${error.message}`;
    $('#model-status').textContent = 'Processing settings cannot be loaded.';
    $('#download').disabled = true;
  }
})();
window.addEventListener('unload', () => clearInterval(polling));
