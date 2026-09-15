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
    stat('#language-status', 'On-device transcription is not available on this Mac.', 'bad');
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
function stat(selector, text, level = '') {
  const node = $(selector);
  node.textContent = text;
  node.className = level ? `stat-row stat-${level}` : 'stat-row';
}
function languageMessage(state) {
  if (state.downloadError) return [`Language asset download failed: ${state.downloadError}`, 'bad'];
  if (state.downloading) return [`Downloading language assets for ${languageLabel(configuredLanguage)}…`, 'busy'];
  return state.modelReady
    ? [`Language assets for ${languageLabel(configuredLanguage)} are downloaded.`, 'ok']
    : [`Language assets for ${languageLabel(configuredLanguage)} will download automatically when processing starts. You can also download them now.`, 'warn'];
}
async function loadDevices() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  $('#device').replaceChildren(new Option('Default microphone', ''), ...devices.filter(d => d.kind === 'audioinput').map(d => new Option(d.label || `Microphone ${d.deviceId.slice(0, 6)}`, d.deviceId)));
}
async function refreshStatus() {
  if (choosingFolder) return;
  try {
    const state = await native('status');
    stat('#language-status', ...languageMessage(state));
    $('#download-language').disabled = !!state.downloading || !!state.processing || !!state.recordingId || $('#language').disabled;
    if (state.summaryAvailable === 'available') stat('#summary-status', 'On-device summaries are available.', 'ok');
    else stat('#summary-status', `On-device summaries unavailable: ${state.summaryAvailable || 'unknown reason'}`, 'warn');
  } catch (error) {
    stat('#language-status', `Helper unavailable: ${error.message}`, 'bad');
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
  stat('#mic-status', 'Microphone access granted.', 'ok');
}, error => { stat('#mic-status', `Microphone unavailable: ${error.message}`, 'bad'); });
$('#save-language').onclick = () => run($('#save-language'), async () => {
  const result = await native('settings', { model: $('#language').value });
  configuredLanguage = result.model;
  if (Array.isArray(result.languages)) populateLanguages(result.languages, configuredLanguage);
  stat('#language-status', `Saved ${languageLabel(configuredLanguage)}.`, 'ok');
  await refreshStatus();
}, error => { stat('#language-status', `Could not save language: ${error.message}`, 'bad'); });
$('#device').onchange = async () => {
  try { await chrome.storage.local.set({ microphoneDeviceId: $('#device').value }); }
  catch (error) { stat('#mic-status', `Could not save microphone: ${error.message}`, 'bad'); }
};
$('#download-language').onclick = async () => {
  $('#download-language').disabled = true;
  try {
    const result = await native('downloadModel');
    if (result.queued) stat('#language-status', `Downloading language assets for ${languageLabel(configuredLanguage)}…`, 'busy');
    else stat('#language-status', 'Language asset download unavailable.', 'warn');
    await refreshStatus();
  } catch (error) {
    stat('#language-status', `Could not download language assets: ${error.message}`, 'bad');
    $('#download-language').disabled = false;
  }
};

(async () => {
  try {
    const [hello, settings, local] = await Promise.all([native('hello'), native('settings'), chrome.storage.local.get('microphoneDeviceId')]);
    $('#library').textContent = settings.libraryPath || hello.libraryPath || 'No folder selected';
    if (!populateLanguages(settings.languages, settings.model || hello.model || 'en-US')) return;
    try { await loadDevices(); }
    catch (error) { stat('#mic-status', `Microphone list unavailable: ${error.message}`, 'bad'); }
    $('#device').value = local.microphoneDeviceId || '';
    await refreshStatus();
    polling = setInterval(refreshStatus, 3_000);
  } catch (error) {
    $('#library').textContent = `Helper unavailable: ${error.message}`;
    stat('#language-status', 'Transcription settings cannot be loaded.', 'bad');
    $('#download-language').disabled = true;
  }
})();
window.addEventListener('unload', () => clearInterval(polling));
