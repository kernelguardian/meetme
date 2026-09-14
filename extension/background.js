const HOST = 'com.meetme.helper';
const OFFSCREEN = 'offscreen.html';
let nativePort;
let nativeReady;
let state = { phase: 'idle', recording: null, micEnabled: false, error: null };
const restored = chrome.storage.session.get('captureState').then(({ captureState }) => {
  if (!captureState || typeof captureState !== 'object') return;
  const active = ['starting', 'recording', 'stopping'].includes(captureState.phase) && captureState.recording?.id;
  state = {
    phase: active ? captureState.phase : 'idle',
    recording: active ? captureState.recording : null,
    micEnabled: active && !!captureState.micEnabled,
    error: typeof captureState.error === 'string' ? captureState.error : null,
  };
});
const pending = new Map();
const uiPorts = new Set();
let idleTimer;
function scheduleIdleCheck() {
  clearTimeout(idleTimer);
  if (!nativePort) return;
  idleTimer = setTimeout(async () => {
    if (uiPorts.size || pending.size || state.phase !== 'idle') { scheduleIdleCheck(); return; }
    try {
      const status = await native('status');
      if (status.processing || status.downloading || status.recordingId) { scheduleIdleCheck(); return; }
      if (!uiPorts.size && !pending.size && state.phase === 'idle') nativePort?.disconnect();
    } catch { /* The next user operation reconnects after helper failure. */ }
  }, 15_000);
}
chrome.runtime.onConnect.addListener(port => {
  if (port.name !== 'meetme-ui' || !port.sender?.url?.startsWith(chrome.runtime.getURL(''))) return;
  uiPorts.add(port);
  port.onDisconnect.addListener(() => { uiPorts.delete(port); scheduleIdleCheck(); });
});

const uid = () => crypto.randomUUID();
const persist = () => chrome.storage.session.set({ captureState: state });
async function setState(next) { const previousTabId = state.recording?.tabId; state = { ...state, ...next }; await persist(); broadcastState(previousTabId); scheduleIdleCheck(); }
function broadcastState(previousTabId) {
  const active = state.phase === 'recording' || state.phase === 'stopping';
  chrome.action.setBadgeText({ text: active ? 'REC' : '' });
  if (active) chrome.action.setBadgeBackgroundColor({ color: state.micEnabled ? '#c62828' : '#6b7280' });
  // Broadcasts intentionally have no responder.  Without a target, a service worker
  // can answer its own message before the intended extension document sees it.
  chrome.runtime.sendMessage({ target: 'ui', type: 'capture-state', state }).catch(() => {});
  for (const tabId of new Set([previousTabId, state.recording?.tabId].filter(Number.isInteger))) {
    chrome.tabs.sendMessage(tabId, { type: 'capture-state', state }).catch(() => {});
  }
}

function connectNative() {
  if (nativeReady) return nativeReady;
  nativeReady = new Promise((resolve, reject) => {
    try { nativePort = chrome.runtime.connectNative(HOST); } catch (error) { nativeReady = null; reject(error); return; }
    nativePort.onMessage.addListener(message => {
      if (!message || typeof message.id !== 'string') return;
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id); clearTimeout(request.timer); scheduleIdleCheck();
      message.ok ? request.resolve(message.result) : request.reject(new Error(message.error || 'Native helper rejected request'));
    });
    nativePort.onDisconnect.addListener(() => {
      const error = new Error(chrome.runtime.lastError?.message || 'Native helper disconnected');
      nativePort = undefined; nativeReady = undefined; clearTimeout(idleTimer);
      for (const [, request] of pending) { clearTimeout(request.timer); request.reject(error); }
      pending.clear();
      if (state.phase !== 'idle') setState({ error: error.message }).catch(() => {});
    });
    resolve();
  });
  return nativeReady;
}
export async function native(command, params = {}, timeout = 30_000) {
  await connectNative();
  const id = uid();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${command} timed out`)); }, timeout);
    pending.set(id, { resolve, reject, timer });
    try { nativePort.postMessage({ id, command, ...params }); }
    catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
  });
}
async function ensureOffscreen() {
  const contexts = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'], documentUrls: [chrome.runtime.getURL(OFFSCREEN)] });
  if (!contexts.length) await chrome.offscreen.createDocument({ url: OFFSCREEN, reasons: ['USER_MEDIA'], justification: 'Capture a user-selected meeting tab and optional microphone.' });
}
async function captureTabId(candidate) {
  if (Number.isInteger(candidate) && candidate >= 0) return candidate;
  const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const tab = tabs.find(item => Number.isInteger(item.id));
  if (!tab) throw new Error('Open the meeting tab, then use Record this tab.');
  return tab.id;
}
async function platformMetadata(tab) {
  const url = tab.url || '';
  const metadata = await chrome.tabs.sendMessage(tab.id, { type: 'meeting-metadata' }).catch(() => null);
  return { participants: Array.isArray(metadata?.participants) ? metadata.participants : [], platform: /meet\.google/.test(url) ? 'Google Meet' : /teams\.microsoft/.test(url) ? 'Microsoft Teams' : /zoom\.us/.test(url) ? 'Zoom' : 'Browser tab', title: metadata?.title || tab.title || 'Untitled meeting' };
}
async function startCapture(tabId, micEnabled) {
  if (state.phase !== 'idle') throw new Error('A recording is already active.');
  await setState({ phase: 'starting', recording: null, micEnabled: false, error: null });
  let recording;
  try {
    tabId = await captureTabId(tabId);
    const tab = await chrome.tabs.get(tabId);
    const meta = await platformMetadata(tab);
    recording = await native('create', { title: meta.title, platform: meta.platform, participants: meta.participants, micEnabled: !!micEnabled });
    await ensureOffscreen();
    const { microphoneDeviceId = '' } = await chrome.storage.local.get('microphoneDeviceId');
    await setState({ recording: { ...recording, tabId }, micEnabled: !!micEnabled });
    const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });
    const reply = await chrome.runtime.sendMessage({ target: 'offscreen', type: 'offscreen-start', recordingId: recording.id, streamId, micEnabled: !!micEnabled, microphoneDeviceId });
    if (!reply?.ok) throw new Error(reply?.error || 'Offscreen capture could not start');
    if (state.recording?.id === recording.id) {
      await setState({ phase: 'recording', micEnabled: !!reply.result?.micEnabled, error: reply.result?.warning || null });
    }
  } catch (error) {
    if (recording) await native('abort', { recordingId: recording.id, error: error.message }).catch(() => {});
    await setState({ phase: 'idle', recording: null, micEnabled: false, error: error.message });
    throw error;
  }
}
async function stopCapture() {
  if (!state.recording || !['recording', 'starting', 'stopping'].includes(state.phase)) return;
  await setState({ phase: 'stopping' });
  try {
    const reply = await chrome.runtime.sendMessage({ target: 'offscreen', type: 'offscreen-stop' });
    if (!reply?.ok) throw new Error(reply?.error || 'Offscreen capture did not acknowledge Stop');
  } catch (error) {
    const recordingId = state.recording?.id;
    if (recordingId) await native('abort', { recordingId, error: error.message }).catch(() => {});
    await setState({ phase: 'idle', recording: null, micEnabled: false, error: error.message });
  }
}
async function finishCapture({ recordingId: finishedId, chunkCount, totalBytes, error }) {
  const recordingId = state.recording?.id;
  if (!recordingId || (finishedId && finishedId !== recordingId)) return;
  try {
    if (error) await native('abort', { recordingId, error });
    else await native('finalize', { recordingId, chunkCount, totalBytes }, 90_000);
    await setState({ phase: 'idle', recording: null, micEnabled: false, error: error || null });
  } catch (err) { await setState({ phase: 'idle', recording: null, micEnabled: false, error: err.message }); }
}
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // Messages addressed to another extension context must not receive a competing
  // response from the service worker.
  if (message?.target && message.target !== 'background') return false;
  const extensionSender = sender.id === chrome.runtime.id && sender.url?.startsWith(chrome.runtime.getURL(''));
  if (!extensionSender && !['meeting-hint', 'get-capture-state'].includes(message?.type)) {
    sendResponse({ ok: false, error: 'This action is only available in MeetMe extension pages.' });
    return false;
  }
  if (message?.type?.startsWith('offscreen-') && sender.url !== chrome.runtime.getURL(OFFSCREEN)) {
    sendResponse({ ok: false, error: 'Invalid capture event source.' });
    return false;
  }
  (async () => {
    await restored;
    if (message.type === 'native-request') return native(message.command, message.params || {}, Math.min(Math.max(Number(message.timeout) || 30_000, 1_000), message.command === 'chooseFolder' ? 600_000 : 90_000));
    if (message.type === 'get-capture-state') {
      if (!extensionSender && state.recording?.tabId !== sender.tab?.id) return { phase: 'idle', recording: null, micEnabled: false, error: null };
      return state;
    }
    if (message.type === 'start-capture') { await startCapture(message.tabId ?? sender.tab?.id, message.micEnabled); return state; }
    if (message.type === 'stop-capture') { await stopCapture(); return state; }
    if (message.type === 'toggle-mic') {
      if (state.phase !== 'recording') throw new Error('Microphone controls are available only while recording.');
      const reply = await chrome.runtime.sendMessage({ target: 'offscreen', type: 'offscreen-mic', enabled: !!message.enabled });
      if (!reply?.ok) throw new Error(reply?.error || 'Could not change microphone state');
      await setState({ micEnabled: !!reply.result?.micEnabled, error: reply.result?.warning || null });
      return state;
    }
    if (message.type === 'offscreen-finished') { await finishCapture(message); return state; }
    if (message.type === 'offscreen-status') { if (message.warning) await setState({ error: message.warning, ...(typeof message.micEnabled === 'boolean' ? { micEnabled: message.micEnabled } : {}) }); return state; }
    if (message.type === 'meeting-hint') return state;
    throw new Error('Unknown message');
  })().then(result => sendResponse({ ok: true, result })).catch(error => sendResponse({ ok: false, error: error.message }));
  return true;
});
chrome.tabs.onRemoved.addListener(tabId => {
  restored.then(() => {
    if (state.recording?.tabId === tabId && ['starting', 'recording', 'stopping'].includes(state.phase)) stopCapture();
  });
});

chrome.runtime.onStartup.addListener(() => { native('hello').then(scheduleIdleCheck).catch(() => {}); });
