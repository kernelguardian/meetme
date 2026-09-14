// Content scripts are deliberately advisory. Recording always starts from the extension UI.
(() => {
  const activePhases = new Set(['starting', 'recording', 'stopping']);
  let indicator;
  function renderCaptureState(state) {
    if (!activePhases.has(state?.phase) || !state.recording) {
      indicator?.remove();
      indicator = undefined;
      return;
    }
    if (!indicator) {
      indicator = document.createElement('aside');
      indicator.id = 'meetme-recording-indicator';
      indicator.setAttribute('role', 'status');
      const title = document.createElement('strong');
      title.textContent = 'MeetMe recording';
      const detail = document.createElement('span');
      detail.className = 'meetme-recording-detail';
      indicator.append(title, detail);
      document.documentElement.append(indicator);
    }
    indicator.querySelector('.meetme-recording-detail').textContent = state.phase === 'stopping'
      ? 'Stopping and saving…'
      : state.micEnabled ? 'Recording this tab + your microphone' : 'Recording this tab (microphone off)';
  }
  function installHint(platform) {
    let shown = false;
    const likelyJoined = () => document.visibilityState === 'visible' && document.body?.innerText?.length > 200;
    const show = () => {
      if (shown || !likelyJoined()) return;
      shown = true;
      const node = document.createElement('aside');
      node.id = 'meetme-hint';
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
    chrome.runtime.sendMessage({ type: 'get-capture-state' }).then(reply => {
      if (reply?.ok) renderCaptureState(reply.result);
    }).catch(() => {});
  }
  globalThis.MeetMeContent = { installHint };
})();
