import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = (await readFile(new URL('../extension/background.js', import.meta.url), 'utf8')).replace('export async function native', 'async function native');
const extensionId = 'a'.repeat(32);
const extensionURL = `chrome-extension://${extensionId}/`;
const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });
function harness({ offscreenFailure = false } = {}) {
  const commands = [];
  const onMessage = event();
  const port = {
    onMessage: event(), onDisconnect: event(),
    postMessage(message) {
      commands.push(message);
      const result = message.command === 'create' ? { id: 'recording-1', title: 'Test' } : {};
      queueMicrotask(() => port.onMessage.listeners.forEach(fn => fn({ id: message.id, ok: true, result })));
    },
    disconnect() { port.onDisconnect.listeners.forEach(fn => fn()); },
  };
  const chrome = {
    runtime: {
      id: extensionId, getURL: path => extensionURL + path, onMessage, onConnect: event(), onStartup: event(),
      connectNative: () => port, getContexts: async () => [],
      sendMessage: async message => message.target === 'offscreen' ? { ok: true, result: { micEnabled: message.micEnabled } } : undefined,
    },
    storage: { session: { get: async () => ({}), set: async () => {} }, local: { get: async () => ({}) } },
    tabs: { query: async () => [{ id: 10 }], get: async id => ({ id, title: 'Test', url: 'https://meet.google.com/test' }), sendMessage: async () => {}, onRemoved: event() },
    action: { setBadgeText() {}, setBadgeBackgroundColor() {} },
    offscreen: { createDocument: async () => { if (offscreenFailure) throw new Error('Offscreen creation failed'); } },
    tabCapture: { getMediaStreamId: async () => 'stream-id' },
  };
  const context = vm.createContext({ chrome, crypto: webcrypto, console, clearTimeout,
    setTimeout: (callback, milliseconds) => { const timer = setTimeout(callback, milliseconds); timer.unref(); return timer; },
  });
  vm.runInContext(source, context, { filename: 'background.js' });
  const dispatch = (message, sender = { id: extensionId, url: extensionURL + 'popup.html' }) => new Promise(resolve => {
    const listening = onMessage.listeners[0](message, sender, resolve);
    if (listening === false) resolve(undefined);
  });
  return { commands, dispatch };
}

test('rejects content-script native requests without exposing helper credentials', async () => {
  const app = harness();
  const result = await app.dispatch({ type: 'native-request', command: 'hello' }, { id: extensionId, url: 'https://meet.google.com/test', tab: { id: 10 } });
  assert.equal(result.ok, false);
  assert.equal(app.commands.length, 0);
});

test('aborts the allocated native recording when offscreen setup fails', async () => {
  const app = harness({ offscreenFailure: true });
  const result = await app.dispatch({ type: 'start-capture', tabId: 10, micEnabled: false });
  assert.equal(result.ok, false);
  assert.match(result.error, /Offscreen creation failed/);
  assert.deepEqual(app.commands.map(command => command.command), ['create', 'abort']);
  const state = await app.dispatch({ type: 'get-capture-state' });
  assert.equal(state.result.phase, 'idle');
  assert.equal(state.result.recording, null);
});

test('serializes duplicate starts and ignores stale recording completion', async () => {
  const app = harness();
  const results = await Promise.all([
    app.dispatch({ type: 'start-capture', tabId: 10, micEnabled: true }),
    app.dispatch({ type: 'start-capture', tabId: 10, micEnabled: true }),
  ]);
  assert.equal(results.filter(result => result.ok).length, 1);
  assert.equal(app.commands.filter(command => command.command === 'create').length, 1);
  const stale = await app.dispatch({ type: 'offscreen-finished', recordingId: 'old-recording', chunkCount: 1, totalBytes: 2 }, { id: extensionId, url: extensionURL + 'offscreen.html' });
  assert.equal(stale.ok, true);
  assert.equal(stale.result.phase, 'recording');
  assert.equal(stale.result.micEnabled, true);
  assert.equal(app.commands.filter(command => command.command === 'finalize').length, 0);
});
