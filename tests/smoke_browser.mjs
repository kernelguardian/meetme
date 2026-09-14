#!/usr/bin/env node
// Isolated Brave + native-host integration. No access to a real browser profile or mic.
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, mkdir, realpath, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const brave = process.env.MEETME_BRAVE || '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';
const temporary = await realpath(await mkdtemp(join(tmpdir(), 'meetme-browser-')));
const profile = join(temporary, 'profile');
await mkdir(profile);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
let browser;
let stderr = '';
const sockets = [];

class CDP {
  constructor(socket) {
    this.socket = socket; this.next = 0; this.pending = new Map();
    socket.addEventListener('message', event => {
      const value = JSON.parse(event.data);
      const pending = this.pending.get(value.id);
      if (pending) {
        this.pending.delete(value.id); clearTimeout(pending.timer);
        value.error ? pending.reject(new Error(JSON.stringify(value.error))) : pending.resolve(value.result);
      }
    });
  }
  static async connect(url) {
    const socket = new WebSocket(url); sockets.push(socket);
    await new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, { once: true });
      socket.addEventListener('error', reject, { once: true });
    });
    return new CDP(socket);
  }
  call(method, params = {}) {
    const id = ++this.next;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`CDP timed out: ${method}`)); }, 45000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async evaluate(expression) {
    const result = await this.call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
}

try {
  browser = spawn(brave, [
    `--user-data-dir=${profile}`, '--headless=new', '--no-first-run', '--no-default-browser-check',
    '--disable-sync', '--disable-background-networking', '--remote-debugging-port=0', '--mute-audio',
    `--disable-extensions-except=${join(root, 'extension')}`, `--load-extension=${join(root, 'extension')}`, 'about:blank',
  ], { env: { ...process.env, CFFIXED_USER_HOME: temporary, MEETME_CONFIG_DIR: join(temporary, 'config'), MEETME_LIBRARY_DIR: join(temporary, 'library') }, stdio: ['ignore', 'ignore', 'pipe'] });
  browser.stderr.on('data', data => { stderr = (stderr + data.toString()).slice(-12000); });
  let port;
  for (let i = 0; i < 100; i++) {
    try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; break; } catch {}
    if (browser.exitCode !== null) throw new Error(`Brave exited: ${browser.exitCode}\n${stderr}`);
    await delay(100);
  }
  assert.ok(port, 'Brave did not expose a debugging port');
  const endpoint = `http://127.0.0.1:${port}`;
  let targets, worker;
  for (let i = 0; i < 100; i++) {
    targets = await (await fetch(`${endpoint}/json/list`)).json();
    worker = targets.find(target => target.type === 'service_worker' && target.url.endsWith('/background.js'));
    if (worker) break;
    await delay(100);
  }
  assert.ok(worker, `MeetMe service worker did not load: ${JSON.stringify(targets)}`);
  const extensionId = new URL(worker.url).hostname;
  const install = spawnSync(join(root, 'install/install.sh'), [
    '--extension-id', extensionId, '--configuration', 'debug', '--skip-build',
    '--install-root', join(temporary, 'installed'), '--host-dir', join(temporary, 'Library/Application Support/Google/Chrome/NativeMessagingHosts'),
  ], { encoding: 'utf8' });
  assert.equal(install.status, 0, install.stdout + install.stderr);
  const version = await (await fetch(`${endpoint}/json/version`)).json();
  const browserCDP = await CDP.connect(version.webSocketDebuggerUrl);
  async function openPage(path) {
    const { targetId } = await browserCDP.call('Target.createTarget', { url: `chrome-extension://${extensionId}/${path}` });
    for (let i = 0; i < 100; i++) {
      const tabs = await (await fetch(`${endpoint}/json/list`)).json();
      const target = tabs.find(tab => tab.id === targetId);
      if (target?.webSocketDebuggerUrl) {
        const cdp = await CDP.connect(target.webSocketDebuggerUrl);
        for (let j = 0; j < 100; j++) {
          if (await cdp.evaluate('document.readyState') === 'complete') return cdp;
          await delay(50);
        }
      }
      await delay(50);
    }
    throw new Error(`Could not load ${path}`);
  }
  const options = await openPage('options.html');
  const hello = await options.evaluate(`chrome.runtime.sendMessage({type:'native-request', command:'hello', params:{}})`);
  assert.equal(hello.ok, true, JSON.stringify(hello));
  assert.equal(new URL(hello.result.baseURL).hostname, '127.0.0.1');
  assert.equal(hello.result.libraryPath, join(temporary, 'library'));
  console.log('PASS unpacked extension, native-host installation and real Brave native messaging');

  const cspCheck = await options.evaluate(`fetch(${JSON.stringify(hello.result.baseURL + '/recordings/invalid/video')}).then(r => r.status)`);
  assert.ok(cspCheck >= 400, 'Expected an authenticated media endpoint error, not a blocked connection');
  console.log('PASS extension CSP permits the helper random port');

  const library = await openPage('webui/index.html');
  const list = await library.evaluate(`chrome.runtime.sendMessage({type:'native-request', command:'list', params:{offset:0,limit:50}})`);
  assert.equal(list.ok, true, JSON.stringify(list));
  assert.equal(list.result.total, 0);
  const state = await library.evaluate(`chrome.runtime.sendMessage({type:'get-capture-state'})`);
  assert.equal(state.ok, true, JSON.stringify(state));
  assert.equal(state.result.phase, 'idle');
  console.log('PASS library page, native listing and capture-state wiring');
  if (process.env.MEETME_SCREENSHOTS === '1') {
    const artifacts = join(root, '.test-artifacts');
    await mkdir(artifacts, { recursive: true });
    for (const [name, page] of [['settings', options], ['library', library]]) {
      const screenshot = await page.call('Page.captureScreenshot', { format: 'png' });
      await writeFile(join(artifacts, `${name}.png`), Buffer.from(screenshot.data, 'base64'));
    }
  }
  await browserCDP.call('Browser.close').catch(() => {});
} catch (error) {
  console.error(stderr);
  throw error;
} finally {
  for (const socket of sockets) socket.close();
  if (browser && browser.exitCode === null) {
    browser.kill('SIGTERM');
    for (let i = 0; i < 50 && browser.exitCode === null; i++) await delay(100);
    if (browser.exitCode === null) browser.kill('SIGKILL');
  }
  await rm(temporary, { recursive: true, force: true });
}
