const $ = s => document.querySelector(s);
const keepAlive = chrome.runtime.connect({ name: 'meetme-ui' });
const AUTO = 'auto';
let polling;
let choosingFolder = false;
let engines = [];
let variants = [];
let configured = { engine: 'apple', model: 'en-US', whisperVariant: '' };

async function native(command, params = {}) {
  const reply = await chrome.runtime.sendMessage({ type: 'native-request', command, params, ...(command === 'chooseFolder' ? { timeout: 600_000 } : {}) });
  if (!reply?.ok) throw new Error(reply?.error || 'The MeetMe helper did not respond.');
  return reply.result;
}
function stat(selector, text, level = '') {
  const node = $(selector);
  node.textContent = text;
  node.className = level ? `stat-row stat-${level}` : 'stat-row';
}
function selectedEngine() {
  return engines.find(engine => engine.id === $('#engine').value) || engines[0];
}
function languageLabel(id) {
  return Array.from($('#language').options).find(option => option.value === id)?.textContent || id;
}
function variantLabel(id) {
  return variants.find(variant => variant.id === id)?.name?.split('—')[0].trim() || id;
}
function populateEngines() {
  $('#engine').replaceChildren(...engines.map(engine => new Option(engine.name, engine.id)));
  $('#engine').value = engines.some(engine => engine.id === configured.engine) ? configured.engine : engines[0]?.id;
}
function populateVariants() {
  $('#whisper-variant').replaceChildren(...variants.map(variant => new Option(`${variant.name} · ${variant.size}`, variant.id)));
  if (variants.some(variant => variant.id === configured.whisperVariant)) $('#whisper-variant').value = configured.whisperVariant;
}
function populateLanguages(preferred) {
  const engine = selectedEngine();
  const menu = $('#language');
  if (!engine?.languages?.length) {
    menu.replaceChildren(new Option('No languages available', ''));
    menu.disabled = true;
    $('#save-language').disabled = true;
    return false;
  }
  const choices = [
    ...(engine.supportsAutoDetect ? [new Option('Detect automatically', AUTO)] : []),
    ...engine.languages.map(language => new Option(language.name, language.id)),
  ];
  menu.replaceChildren(...choices);
  const ids = choices.map(option => option.value);
  menu.value = ids.includes(preferred) ? preferred
    : engine.supportsAutoDetect ? AUTO
    : ids.includes('en-US') ? 'en-US' : ids[0];
  menu.disabled = false;
  $('#save-language').disabled = false;
  return true;
}
function syncEngineUI() {
  const engine = selectedEngine();
  $('#engine-detail').textContent = engine?.detail || '';
  $('#variant-row').hidden = engine?.id !== 'whisper';
  $('#download-language').textContent = engine?.id === 'whisper' ? 'Download model' : 'Download language assets';
}
function languageMessage(state) {
  if (state.downloadError) return [`Download failed: ${state.downloadError}`, 'bad'];
  const whisper = configured.engine === 'whisper';
  const what = whisper ? `The ${variantLabel(configured.whisperVariant)} model` : `Language assets for ${languageLabel(configured.model)}`;
  if (state.downloading) return [`Downloading ${whisper ? variantLabel(configured.whisperVariant) : languageLabel(configured.model)}…`, 'busy'];
  if (state.modelReady) return [`${what} ${whisper ? 'is' : 'are'} downloaded.`, 'ok'];
  // Whisper refuses to run without its model; Apple fetches assets on demand.
  return whisper
    ? [`${what} must be downloaded before recordings can be processed.`, 'warn']
    : [`${what} will download automatically when processing starts. You can also download them now.`, 'warn'];
}
async function loadDevices() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  $('#device').replaceChildren(new Option('Default microphone', ''), ...devices.filter(d => d.kind === 'audioinput').map(d => new Option(d.label || `Microphone ${d.deviceId.slice(0, 6)}`, d.deviceId)));
}
function summaryMessage(state) {
  if (state.summaryAvailable !== 'available') return [`On-device summaries unavailable: ${state.summaryAvailable || 'unknown reason'}`, 'warn'];
  if (configured.engine === 'whisper') return ['On-device summaries are available. Languages Apple Intelligence cannot read are translated to English first.', 'ok'];
  return ['On-device summaries are available.', 'ok'];
}
async function refreshStatus() {
  if (choosingFolder) return;
  try {
    const state = await native('status');
    stat('#language-status', ...languageMessage(state));
    $('#download-language').disabled = !!state.downloading || !!state.processing || !!state.recordingId || $('#language').disabled;
    stat('#summary-status', ...summaryMessage(state));
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
$('#engine').onchange = () => {
  syncEngineUI();
  populateLanguages(configured.engine === $('#engine').value ? configured.model : undefined);
  stat('#language-status', 'Unsaved changes. Choose Save to apply them.', 'warn');
};
$('#whisper-variant').onchange = () => stat('#language-status', 'Unsaved changes. Choose Save to apply them.', 'warn');
$('#language').onchange = () => stat('#language-status', 'Unsaved changes. Choose Save to apply them.', 'warn');
$('#save-language').onclick = () => run($('#save-language'), async () => {
  const result = await native('settings', {
    engine: $('#engine').value,
    model: $('#language').value,
    whisperVariant: $('#whisper-variant').value,
  });
  applySettings(result);
  stat('#language-status', 'Saved.', 'ok');
  await refreshStatus();
}, error => { stat('#language-status', `Could not save: ${error.message}`, 'bad'); });
$('#device').onchange = async () => {
  try { await chrome.storage.local.set({ microphoneDeviceId: $('#device').value }); }
  catch (error) { stat('#mic-status', `Could not save microphone: ${error.message}`, 'bad'); }
};
$('#download-language').onclick = async () => {
  $('#download-language').disabled = true;
  try {
    const result = await native('downloadModel');
    if (result.queued) stat('#language-status', 'Download started.', 'busy');
    else stat('#language-status', 'Download unavailable.', 'warn');
    await refreshStatus();
  } catch (error) {
    stat('#language-status', `Could not download: ${error.message}`, 'bad');
    $('#download-language').disabled = false;
  }
};

function applySettings(settings) {
  engines = Array.isArray(settings.engines) ? settings.engines : [];
  variants = Array.isArray(settings.whisperVariants) ? settings.whisperVariants : [];
  configured = {
    engine: settings.engine || 'apple',
    model: settings.model || 'en-US',
    whisperVariant: settings.whisperVariant || variants[0]?.id || '',
  };
  populateEngines();
  populateVariants();
  syncEngineUI();
  return populateLanguages(configured.model);
}

(async () => {
  try {
    const [hello, settings, local] = await Promise.all([native('hello'), native('settings'), chrome.storage.local.get('microphoneDeviceId')]);
    $('#library').textContent = settings.libraryPath || hello.libraryPath || 'No folder selected';
    if (!applySettings(settings)) return;
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
