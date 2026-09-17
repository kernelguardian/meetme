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
    stopSpeakerTracking();
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

  // ---- Speaker log ------------------------------------------------------------
  // Meeting pages animate a per-participant audio indicator by rewriting class names
  // many times a second while that person talks. Counting those rewrites under each
  // participant's element says who is speaking without depending on the page's
  // obfuscated class names; only the participant selector and name lookup are
  // platform-specific. Times are seconds since the recorder started.
  const SPEAKER_TICK_MS = 250;
  const SPEAKER_MIN_MUTATIONS = 2;   // per tick, to ignore one-off hover/layout changes
  const SPEAKER_CONFIRM_S = 0.4;     // sustained activity before a turn opens
  const SPEAKER_RELEASE_S = 1.0;     // quiet time before a turn closes
  const SPEAKER_SPLIT_S = 30;        // long turns are cut so they reach disk while recording
  const SPEAKER_SEND_MS = 10_000;
  let speakerPlatform;
  let tracker;

  function stopSpeakerTracking() {
    if (!tracker) return;
    tracker.observer.disconnect();
    clearInterval(tracker.tick);
    clearInterval(tracker.sender);
    tracker = undefined;
  }

  function closeTurn(entry, end) {
    if (entry.open === undefined) return;
    const name = entry.name || speakerPlatform.nameOf(entry.id);
    if (name && end - entry.open >= 0.3) tracker.done.push({ start: +entry.open.toFixed(2), end: +end.toFixed(2), name });
    if (tracker.done.length > 4000) tracker.done.splice(0, tracker.done.length - 4000);
    entry.open = undefined;
  }

  function speakerTick() {
    if (cleanUpIfOrphaned()) return;
    const now = (Date.now() - tracker.startedAt) / 1000;
    for (const entry of tracker.people.values()) {
      const active = entry.count >= SPEAKER_MIN_MUTATIONS;
      entry.count = 0;
      if (active) {
        entry.since ??= Math.max(0, now - SPEAKER_TICK_MS / 1000);
        entry.last = now;
        entry.name ||= speakerPlatform.nameOf(entry.id);
        if (entry.open === undefined && now - entry.since >= SPEAKER_CONFIRM_S) entry.open = entry.since;
        if (entry.open !== undefined && now - entry.open >= SPEAKER_SPLIT_S) { closeTurn(entry, now); entry.open = now; }
      } else if (entry.since !== undefined && now - entry.last > SPEAKER_RELEASE_S) {
        closeTurn(entry, entry.last + SPEAKER_TICK_MS / 1000);
        entry.since = undefined;
      }
    }
  }

  // Closes turns in progress so nothing is held back, then lets them continue.
  function takeSpeakerIntervals() {
    if (!tracker) return [];
    const now = (Date.now() - tracker.startedAt) / 1000;
    for (const entry of tracker.people.values()) {
      if (entry.open !== undefined) { closeTurn(entry, Math.min(now, entry.last + SPEAKER_TICK_MS / 1000)); entry.open = now; }
    }
    return tracker.done.splice(0, 400);
  }

  function sendSpeakerIntervals() {
    if (!tracker?.done.length || !connected()) return;
    const intervals = tracker.done.splice(0, 400);
    const active = tracker;
    chrome.runtime.sendMessage({ type: 'speaker-intervals', intervals })
      .then(reply => { if (!reply?.ok && tracker === active) tracker.done.unshift(...intervals); })
      .catch(() => { if (tracker === active) tracker.done.unshift(...intervals); });
  }

  function syncSpeakerTracking(state) {
    const startedAt = state?.recording?.startedAt;
    const wanted = speakerPlatform && state?.phase === 'recording' && Number.isFinite(startedAt);
    if (!wanted) {
      // While stopping, the background still collects the tail through speaker-flush.
      if (state?.phase !== 'stopping') stopSpeakerTracking();
      return;
    }
    if (tracker?.startedAt === startedAt) return;
    stopSpeakerTracking();
    const people = new Map();
    const observer = new MutationObserver(mutations => {
      for (const mutation of mutations) {
        const id = speakerPlatform.participantId(mutation.target);
        if (!id) continue;
        let entry = people.get(id);
        if (!entry) { entry = { id, count: 0 }; people.set(id, entry); }
        entry.count += 1;
      }
    });
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class'], subtree: true });
    tracker = { startedAt, people, observer, done: [], tick: setInterval(speakerTick, SPEAKER_TICK_MS), sender: setInterval(sendSpeakerIntervals, SPEAKER_SEND_MS) };
  }

  function renderCaptureState(state) {
    syncSpeakerTracking(state);
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

  function installHint(platform, speakers) {
    speakerPlatform = speakers;
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
      if (message?.type === 'speaker-flush') {
        respond({ intervals: takeSpeakerIntervals() });
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
