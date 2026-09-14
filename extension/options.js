const $ = s => document.querySelector(s);
const keepAlive = chrome.runtime.connect({ name: 'meetme-ui' });
let polling;
let choosingFolder = false;
let configuredLanguage = 'en-US';

async function native(command, params = {}) {
  const reply = await chrome.runtime.sendMessage({ type: 'native-request', command, params, ...(command === 'chooseFolder' ? { timeout: 600_000 } : {}) });
  if (!reply?.ok) throw new Error(reply?.error || 'The MeetMe helper did not respond.');
  return reply.result;
}
function languageLabel(id = configuredLanguage) {
  return Array.from($('#language').options).find(option => option.value === id)?.textContent || id;
}
function populateLanguages(languages, selected) {
  const choices = Array.isArray(languages) ? languages.filter(language => typeof language?.id === 'string' && typeof language?.name === 'string') : [];
  const menu = $('#language');
  menu.replaceChildren(...choices.map(language => new Option(language.name, language.id)));
  if (!choices.length) {
    menu.append(new Option('No supported languages found', ''));
    menu.disabled = true;
    $('#save-language').disabled = true;
    $('#download-language').disabled = true;
    $('#language-status').textContent = 'Apple native transcription is not available on this Mac.';
    return false;
  }
  const languageId = choices.some(language => language.id === selected) ? selected : choices[0].id;
  menu.value = languageId;
  configuredLanguage = languageId;
  menu.disabled = false;
  $('#save-language').disabled = false;
  $('#download-language').disabled = false;
  return true;
}
function languageMessage(state) {
  if (state.downloadError) return `Language asset download failed: ${state.downloadError}`;
  if (state.downloading) return `Downloading language assets for ${languageLabel(configuredLanguage)}…`;
  return state.modelReady ? `Language assets for ${languageLabel(configuredLanguage)} are downloaded.` : `Language assets for ${languageLabel(configuredLanguage)} will download automatically when processing starts. You can also download them now.`;
}
async function loadDevices() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  $('#device').replaceChildren(new Option('Default microphone', ''), ...devices.filter(d => d.kind === 'audioinput').map(d => new Option(d.label || `Microphone ${d.deviceId.slice(0, 6)}`, d.deviceId)));
}
async function refreshStatus() {
  if (choosingFolder) return;
  try {
    const state = await native('status');
    $('#language-status').textContent = languageMessage(state);
    $('#download-language').disabled = !!state.downloading || !!state.processing || !!state.recordingId || $('#language').disabled;
    $('#summary-status').textContent = state.summaryAvailable === 'available' ? 'On-device summaries are available.' : `On-device summaries unavailable: ${state.summaryAvailable || 'unknown reason'}`;
  } catch (error) {
    $('#language-status').textContent = `Helper unavailable: ${error.message}`;
    $('#download-language').disabled = true;
  }
}
async function run(button, operation, onError) {
  button.disabled = true;
  try { await operation(); }
  catch (error) { onError(error); }
  finally { button.disabled = false; }
}

$('#folder').onclick = () => run($('#folder'), async () => {
  choosingFolder = true;
  try {
    const result = await native('chooseFolder');
    $('#library').textContent = result.libraryPath || 'No folder selected';
  } finally { choosingFolder = false; }
}, error => { $('#library').textContent = `Folder selection failed: ${error.message}`; });
$('#grant').onclick = () => run($('#grant'), async () => {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  stream.getTracks().forEach(track => track.stop());
  await loadDevices();
  $('#mic-status').textContent = 'Microphone access granted.';
}, error => { $('#mic-status').textContent = `Microphone unavailable: ${error.message}`; });
$('#save-language').onclick = () => run($('#save-language'), async () => {
  const result = await native('settings', { model: $('#language').value });
  configuredLanguage = result.model;
  if (Array.isArray(result.languages)) populateLanguages(result.languages, configuredLanguage);
  $('#language-status').textContent = `Saved ${languageLabel(configuredLanguage)}.`;
  await refreshStatus();
}, error => { $('#language-status').textContent = `Could not save language: ${error.message}`; });
$('#device').onchange = async () => {
  try { await chrome.storage.local.set({ microphoneDeviceId: $('#device').value }); }
  catch (error) { $('#mic-status').textContent = `Could not save microphone: ${error.message}`; }
};
$('#download-language').onclick = async () => {
  $('#download-language').disabled = true;
  try {
    const result = await native('downloadModel');
    $('#language-status').textContent = result.queued ? `Downloading language assets for ${languageLabel(configuredLanguage)}…` : 'Language asset download unavailable.';
    await refreshStatus();
  } catch (error) {
    $('#language-status').textContent = `Could not download language assets: ${error.message}`;
    $('#download-language').disabled = false;
  }
};

(async () => {
  try {
    const [hello, settings, local] = await Promise.all([native('hello'), native('settings'), chrome.storage.local.get('microphoneDeviceId')]);
    $('#library').textContent = settings.libraryPath || hello.libraryPath || 'No folder selected';
    if (!populateLanguages(settings.languages, settings.model || hello.model || 'en-US')) return;
    try { await loadDevices(); }
    catch (error) { $('#mic-status').textContent = `Microphone list unavailable: ${error.message}`; }
    $('#device').value = local.microphoneDeviceId || '';
    await refreshStatus();
    polling = setInterval(refreshStatus, 3_000);
  } catch (error) {
    $('#library').textContent = `Helper unavailable: ${error.message}`;
    $('#language-status').textContent = 'Transcription settings cannot be loaded.';
    $('#download-language').disabled = true;
  }
})();
window.addEventListener('unload', () => clearInterval(polling));
