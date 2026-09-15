// Content scripts are deliberately advisory. Recording always starts from the extension UI.
(() => {
  const activePhases = new Set(['starting', 'recording', 'stopping']);
  const INDICATOR_ID = 'meetme-recording-indicator';
  const HINT_ID = 'meetme-hint';
  const HEALTH_INTERVAL_MS = 4000;
  let indicator;
  let detail;
  let dismissed = false;
  let healthTimer;

  const connected = () => {
    try { return !!chrome.runtime?.id; } catch { return false; }
  };

  function removeIndicator() {
    indicator?.remove();
    indicator = undefined;
    detail = undefined;
  }

  // Reloading the extension orphans this script: its runtime context dies while the
  // node it appended stays in the page, and no message can ever reach it again. The
  // script has to notice that on its own and clean up after itself.
  function cleanUpIfOrphaned() {
    if (connected()) return false;
    clearInterval(healthTimer);
    removeIndicator();
    document.getElementById(HINT_ID)?.remove();
    return true;
  }

  function buildIndicator() {
    const node = document.createElement('aside');
    node.id = INDICATOR_ID;
    node.setAttribute('role', 'status');

    const text = document.createElement('div');
    text.className = 'meetme-recording-text';
    const title = document.createElement('strong');
    title.textContent = 'MeetMe recording';
    detail = document.createElement('span');
    detail.className = 'meetme-recording-detail';
    text.append(title, detail);

    const stop = document.createElement('button');
    stop.className = 'meetme-recording-stop';
    stop.textContent = 'Stop';
    stop.onclick = () => {
      stop.disabled = true;
      chrome.runtime.sendMessage({ type: 'stop-capture' }).catch(() => removeIndicator());
    };

    const dismiss = document.createElement('button');
    dismiss.className = 'meetme-recording-dismiss';
    dismiss.setAttribute('aria-label', 'Hide this indicator');
    dismiss.title = 'Hide this indicator. Recording continues.';
    dismiss.textContent = '×';
    dismiss.onclick = () => { dismissed = true; removeIndicator(); };

    node.append(text, stop, dismiss);
    document.documentElement.append(node);
    return node;
  }

  function renderCaptureState(state) {
    if (!activePhases.has(state?.phase) || !state.recording) {
      dismissed = false;
      removeIndicator();
      return;
    }
    if (dismissed) return;
    if (!indicator?.isConnected) indicator = buildIndicator();
    detail.textContent = state.phase === 'stopping'
      ? 'Stopping and saving…'
      : state.micEnabled ? 'Recording this tab + your microphone' : 'Recording this tab (microphone off)';
  }

  function sync() {
    if (cleanUpIfOrphaned()) return;
    chrome.runtime.sendMessage({ type: 'get-capture-state' }).then(reply => {
      if (reply?.ok) renderCaptureState(reply.result);
    }).catch(() => {});
  }

  function installHint(platform) {
    // Clear anything stranded in the page by a previous extension context.
    document.getElementById(INDICATOR_ID)?.remove();
    document.getElementById(HINT_ID)?.remove();

    let shown = false;
    const likelyJoined = () => document.visibilityState === 'visible' && document.body?.innerText?.length > 200;
    const show = () => {
      if (shown || !likelyJoined() || !connected()) return;
      shown = true;
      const node = document.createElement('aside');
      node.id = HINT_ID;
      const dismiss = document.createElement('button');
      dismiss.setAttribute('aria-label', 'Dismiss');
      dismiss.textContent = '×';
      const title = document.createElement('strong');
      title.textContent = 'MeetMe';
      const text = document.createElement('span');
      text.textContent = `Use the extension to record this ${platform} meeting. Make sure participants have consented.`;
      dismiss.onclick = () => node.remove();
      node.append(dismiss, title, text);
      document.documentElement.append(node);
      chrome.runtime.sendMessage({ type: 'meeting-hint', platform, title: document.title }).catch(() => {});
    };
    setTimeout(show, 3000);
    new MutationObserver(show).observe(document.documentElement, { childList: true, subtree: true });

    chrome.runtime.onMessage.addListener((message, _sender, respond) => {
      if (message?.type === 'meeting-metadata') {
        // These are best-effort visible DOM labels, never speaker attribution.
        const selectors = '[data-participant-name], [data-display-name], [data-tid="participant-display-name"], .participants-item__display-name';
        const names = [...document.querySelectorAll(selectors)]
          .filter(node => node.getClientRects().length > 0)
          .map(node => (node.getAttribute('data-participant-name') || node.getAttribute('data-display-name') || node.textContent || '').trim().slice(0, 80))
          .filter(Boolean);
        respond({ title: document.title, participants: [...new Set(names)].slice(0, 64) });
        return false;
      }
      if (message?.type === 'capture-state' && (!message.target || message.target === 'content')) renderCaptureState(message.state);
    });

    healthTimer = setInterval(cleanUpIfOrphaned, HEALTH_INTERVAL_MS);
    // A broadcast missed while the service worker was torn down leaves the badge
    // stale; re-ask whenever the tab comes back to the foreground.
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') sync();
    });
    sync();
  }

  globalThis.MeetMeContent = { installHint };
})();
