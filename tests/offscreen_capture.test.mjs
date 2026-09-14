import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../extension/offscreen.js', import.meta.url), 'utf8');

function makeTrack() { return { enabled: true, stop() {} }; }
function makeStream({ video = false } = {}) {
  const audio = makeTrack();
  const videoTrack = video ? makeTrack() : undefined;
  return {
    getTracks: () => [audio, ...(videoTrack ? [videoTrack] : [])],
    getAudioTracks: () => [audio],
    getVideoTracks: () => videoTrack ? [videoTrack] : [],
  };
}

async function loadOffscreen({ microphoneAvailable = false } = {}) {
  let listener;
  const messages = [];
  const uploads = [];
  const recorders = [];
  class FakeRecorder {
    static isTypeSupported() { return true; }
    constructor() { this.state = 'inactive'; recorders.push(this); }
    start() { this.state = 'recording'; }
    stop() { this.state = 'inactive'; this.onstop?.(); }
  }
  class FakeAudioContext {
    createMediaStreamDestination() { return { stream: makeStream() }; }
    createMediaStreamSource() { return { connect() {} }; }
    get destination() { return {}; }
    async resume() {}
    async close() {}
  }
  const chrome = {
    runtime: {
      onMessage: { addListener(fn) { listener = fn; } },
      async sendMessage(message) {
        if (message.type === 'native-request') return { ok: true, result: { baseURL: 'http://127.0.0.1:1', token: 'test' } };
        messages.push(message);
        return { ok: true, result: {} };
      },
    },
  };
  const context = vm.createContext({
    AbortController, Blob, Error, MediaRecorder: FakeRecorder, MediaStream: class { constructor(tracks) { this.tracks = tracks; } },
    AudioContext: FakeAudioContext, Uint8Array, crypto: webcrypto, chrome, console, encodeURIComponent,
    fetch: async (url, options) => { const sequence = Number(url.split('/').at(-1)); uploads.push(sequence); return { ok: true, json: async () => ({ sequence }) }; },
    navigator: { mediaDevices: { getUserMedia: async constraints => {
      if (constraints.video) return makeStream({ video: true });
      if (!microphoneAvailable) throw new Error('Denied');
      return makeStream();
    } } },
    setTimeout, clearTimeout,
  });
  vm.runInContext(source, context, { filename: 'offscreen.js' });
  const dispatch = message => new Promise((resolve, reject) => {
    const keepAlive = listener(message, {}, response => response?.ok ? resolve(response.result) : reject(new Error(response?.error)));
    if (!keepAlive) resolve(undefined);
  });
  return { dispatch, messages, recorders, listener, uploads };
}

test('waits for an asynchronously checksummed final blob before finalizing', async () => {
  const app = await loadOffscreen();
  const start = await app.dispatch({ target: 'offscreen', type: 'offscreen-start', recordingId: 'rec-1', streamId: 'stream', micEnabled: false });
  assert.equal(start.micEnabled, false);
  const recorder = app.recorders[0];
  const finalBlob = new Blob(['final media']);
  const pendingChunk = recorder.ondataavailable({ data: finalBlob });
  recorder.state = 'inactive';
  recorder.onstop();
  await pendingChunk;
  await new Promise(resolve => setTimeout(resolve, 0));
  const finished = app.messages.filter(message => message.type === 'offscreen-finished');
  assert.equal(finished.length, 1);
  assert.equal(finished[0].target, 'background');
  assert.equal(finished[0].chunkCount, 1);
  assert.equal(finished[0].totalBytes, finalBlob.size);
});

test('routes only explicitly addressed offscreen commands and reports an unavailable microphone', async () => {
  const app = await loadOffscreen();
  assert.equal(app.listener({ target: 'background', type: 'offscreen-start' }, {}, () => {}), false);
  const start = await app.dispatch({ target: 'offscreen', type: 'offscreen-start', recordingId: 'rec-2', streamId: 'stream', micEnabled: true });
  assert.match(start.warning, /remote audio only/);
  assert.equal(start.micEnabled, false);
  const mic = await app.dispatch({ target: 'offscreen', type: 'offscreen-mic', enabled: true });
  assert.equal(mic.micEnabled, false);
});


test('uploads blobs in recorder order even when checksums finish out of order', async () => {
  const app = await loadOffscreen();
  await app.dispatch({ target: 'offscreen', type: 'offscreen-start', recordingId: 'rec-order', streamId: 'stream', micEnabled: false });
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  class DelayedBlob extends Blob {
    async arrayBuffer() { await blocked; return super.arrayBuffer(); }
  }
  const first = app.recorders[0].ondataavailable({ data: new DelayedBlob(['first']) });
  await app.recorders[0].ondataavailable({ data: new Blob(['second']) });
  assert.deepEqual(app.uploads, []);
  app.recorders[0].stop();
  release();
  await first;
  for (let i = 0; i < 20 && app.messages.length === 0; i++) await new Promise(resolve => setTimeout(resolve, 5));
  assert.deepEqual(app.uploads, [0, 1]);
  const finished = app.messages.find(message => message.type === 'offscreen-finished');
  assert.equal(finished?.recordingId, 'rec-order');
  assert.equal(finished?.chunkCount, 2);
  assert.equal(finished?.totalBytes, 11);
});
