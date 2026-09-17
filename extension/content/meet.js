// Meet tags every participant's video tile and people-panel row with the same
// data-participant-id, so activity in either place counts towards one person.
(() => {
  const PARTICIPANT = '[data-participant-id]';
  const clean = text => (text || '').replace(/\s+/g, ' ').replace(/\s*\((You|Presentation|Host)\)\s*$/i, '').trim().slice(0, 80);

  function nameOf(id) {
    for (const node of document.querySelectorAll(`[data-participant-id="${CSS.escape(id)}"]`)) {
      const label = node.querySelector('[data-self-name]') || node.querySelector('.notranslate');
      const name = clean(label?.textContent) || clean(node.getAttribute('aria-label'));
      if (name) return name;
    }
    return '';
  }

  globalThis.MeetMeContent.installHint('Google Meet', {
    participantId: target => target.closest?.(PARTICIPANT)?.getAttribute('data-participant-id') || '',
    nameOf,
  });
})();
