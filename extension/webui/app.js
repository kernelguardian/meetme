const $ = selector => document.querySelector(selector);
const keepAlive = chrome.runtime.connect({ name: 'meetme-ui' });
const RECORDING_PAGE_SIZE = 30;
const SEGMENT_PAGE_SIZE = 100;
let selected;
let segmentOffset = 0;
let recordingOffset = 0;
let recordingTotal = 0;
let playback;
let playbackRefreshInFlight = false;
let playbackRetries = 0;
let statusPoll;
let wasProcessing = false;
let activeSegment;
let knownLibraryPath;

async function native(command, params = {}) {
  const reply = await chrome.runtime.sendMessage({ type: 'native-request', command, params });
  if (!reply?.ok) throw new Error(reply?.error || 'The MeetMe helper did not respond.');
  return reply.result;
}
function notice(text) { $('#notice').textContent = text; }
function stamp(seconds) {
  seconds = Number(seconds || 0);
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = String(Math.floor(seconds % 60)).padStart(2, '0');
  return hours ? `${hours}:${String(minutes).padStart(2, '0')}:${secs}` : `${minutes}:${secs}`;
}
const displayNames = (() => {
  try { return new Intl.DisplayNames(undefined, { type: 'language' }); } catch { return null; }
})();
function languageName(code) {
  if (!code) return '';
  try { return displayNames?.of(code) || code; } catch { return code; }
}
function metaParts(recording) {
  const parts = [];
  if (recording.platform) parts.push(recording.platform);
  if (recording.createdAt) parts.push(new Date(recording.createdAt).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }));
  if (Number(recording.duration) > 0) parts.push(stamp(recording.duration));
  if (recording.language) parts.push(languageName(recording.language));
  return parts;
}
// jobStage names the work still outstanding, and advances as the job runs.
const STAGE_LABEL = { all: 'Transcribing…', transcribe: 'Transcribing…', summary: 'Summarising…' };
function statusPill(recording) {
  const { status, jobStatus, jobStage } = recording;
  if (jobStatus === 'running') return [STAGE_LABEL[jobStage] || 'Processing…', 'pill-busy'];
  if (jobStatus === 'queued') return ['Queued', 'pill-busy'];
  if (jobStatus === 'failed' || status === 'failed') return ['Failed', 'pill-bad'];
  if (status === 'incomplete') return ['Incomplete', 'pill-warn'];
  if (status === 'finalizing') return ['Finalizing…', 'pill-busy'];
  if (status === 'recording') return ['Recording', 'pill-rec'];
  if (status === 'ready') return ['Ready', 'pill-ok'];
  return [status || 'Unknown', ''];
}
function pill(recording) {
  const [label, variant] = statusPill(recording);
  const node = document.createElement('span');
  node.className = variant ? `pill ${variant}` : 'pill';
  node.textContent = label;
  return node;
}
function metaLine(recording, className = 'rec-meta') {
  const line = document.createElement('span');
  line.className = className;
  metaParts(recording).forEach((part, index) => {
    if (index) {
      const sep = document.createElement('span');
      sep.className = 'sep';
      sep.textContent = '·';
      line.append(sep);
    }
    const span = document.createElement('span');
    span.textContent = part;
    line.append(span);
  });
  return line;
}
function item(recording) {
  const card = document.createElement('button');
  card.type = 'button';
  card.className = 'rec';
  card.onclick = () => openRecording(recording.id);
  const title = document.createElement('span');
  title.className = 'rec-title';
  title.textContent = recording.title || 'Untitled meeting';
  card.append(title, pill(recording), metaLine(recording));
  if (recording.error) {
    const snippet = document.createElement('span');
    snippet.className = 'rec-snippet';
    snippet.textContent = recording.error;
    card.append(snippet);
  }
  return card;
}
function emptyState(query) {
  const box = document.createElement('div');
  box.className = 'empty';
  const heading = document.createElement('strong');
  heading.textContent = query ? 'No matching recordings' : 'No recordings yet';
  const hint = document.createElement('span');
  hint.textContent = query
    ? 'Try a different search term, or clear the search to see everything.'
    : 'Open a meeting tab, then click Record this tab in the MeetMe popup.';
  box.append(heading, hint);
  return box;
}
function skeletons(count = 3) {
  return Array.from({ length: count }, () => {
    const row = document.createElement('div');
    row.className = 'skeleton';
    return row;
  });
}
function seek(time) {
  if (!Number.isFinite(time)) return;
  const video = $('#video');
  video.currentTime = time;
  video.play().catch(() => notice('Use the player controls to start playback.'));
}
async function list(reset = true) {
  const query = $('#query').value.trim();
  try {
    if (reset) {
      recordingOffset = 0;
      recordingTotal = 0;
      $('#list').replaceChildren(...skeletons());
    }
    notice(recordingOffset ? 'Loading more recordings…' : 'Loading library…');
    const result = await native('list', { offset: recordingOffset, limit: RECORDING_PAGE_SIZE, query });
    const items = result.items || [];
    if (reset) $('#list').replaceChildren();
    $('#list').append(...items.map(item));
    recordingOffset += items.length;
    recordingTotal = Number(result.total || 0);
    if (!recordingTotal) $('#list').replaceChildren(emptyState(query));
    $('#more-recordings').classList.toggle('hidden', recordingOffset >= recordingTotal);
    notice(recordingTotal ? `${recordingTotal} recording${recordingTotal === 1 ? '' : 's'}` : '');
  } catch (error) {
    if (reset) $('#list').replaceChildren();
    notice(`Library unavailable: ${error.message}`);
  }
}
function restorePlayback(time, shouldPlay) {
  const video = $('#video');
  const restore = () => {
    video.removeEventListener('loadedmetadata', restore);
    if (Number.isFinite(time) && time > 0) video.currentTime = Math.min(time, Number.isFinite(video.duration) ? video.duration : time);
    if (shouldPlay) video.play().catch(() => notice('Playback was renewed. Press play to continue.'));
  };
  video.addEventListener('loadedmetadata', restore, { once: true });
}
async function playbackURL({ preserve = false } = {}) {
  const video = $('#video');
  const time = preserve && Number.isFinite(video.currentTime) ? video.currentTime : 0;
  const shouldPlay = preserve && !video.paused;
  playback = await native('playback', { recordingId: selected });
  if (preserve) restorePlayback(time, shouldPlay);
  video.src = playback.url;
  video.load();
}
function appendSegments(segments) {
  const box = $('#segments');
  for (const segment of segments || []) {
    const start = Number(segment.start ?? segment.startTime ?? 0);
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'seg';
    row.dataset.start = String(start);
    const time = document.createElement('span');
    time.className = 'seg-time';
    time.textContent = stamp(start);
    const text = document.createElement('span');
    text.textContent = segment.text || '';
    row.append(time, text);
    row.onclick = () => seek(start);
    box.append(row);
  }
}

// Summary markdown is on-device model output derived from meeting audio. It is
// rendered by building nodes so a transcript can never inject markup.
const INLINE = /\*\*([^*]+)\*\*|\[(\d{1,2}:[0-5]\d:[0-5]\d)\]/g;
function citeSeconds(text) {
  const [hours, minutes, secs] = text.split(':').map(Number);
  return hours * 3600 + minutes * 60 + secs;
}
function inline(parent, text) {
  let last = 0;
  for (const match of text.matchAll(INLINE)) {
    if (match.index > last) parent.append(text.slice(last, match.index));
    if (match[1] !== undefined) {
      const bold = document.createElement('strong');
      bold.textContent = match[1];
      parent.append(bold);
    } else {
      const start = citeSeconds(match[2]);
      const cite = document.createElement('button');
      cite.type = 'button';
      cite.className = 'cite';
      cite.textContent = stamp(start);
      cite.title = 'Jump to this moment';
      cite.onclick = () => seek(start);
      parent.append(cite);
    }
    last = match.index + match[0].length;
  }
  if (last < text.length) parent.append(text.slice(last));
}
function renderSummary(markdown, recording = {}) {
  const box = $('#summary');
  box.replaceChildren();
  if (!markdown?.trim()) {
    // A skipped summary is an expected outcome, not a failure, so say why.
    box.textContent = recording.summarySkipped || 'No summary yet.';
    return;
  }
  if (recording.hasTranslation) {
    const note = document.createElement('p');
    note.className = 'summary-note';
    note.textContent = `Apple Intelligence cannot read ${languageName(recording.language) || 'this language'}, so this summary was written from an English translation of the recording.`;
    box.append(note);
  }
  let bullets;
  let seen = false;
  for (const raw of markdown.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) { bullets = null; continue; }
    const heading = /^#{1,6}\s+(.*)$/.exec(line) || /^\*\*(.+?):?\*\*:?$/.exec(line);
    const bullet = /^[*+-]\s+(.*)$/.exec(line);
    if (heading) {
      bullets = null;
      // The panel is already titled Summary; drop the document's own title line.
      if (!seen) { seen = true; continue; }
      const node = document.createElement('h3');
      node.textContent = heading[1];
      box.append(node);
    } else if (bullet) {
      if (!bullets) { bullets = document.createElement('ul'); box.append(bullets); }
      const entry = document.createElement('li');
      inline(entry, bullet[1]);
      bullets.append(entry);
    } else {
      bullets = null;
      const paragraph = document.createElement('p');
      inline(paragraph, line);
      box.append(paragraph);
    }
    seen = true;
  }
}
function setActionAvailability(recording) {
  const ready = recording?.status === 'ready';
  const busy = ['queued', 'running'].includes(recording?.jobStatus);
  $('#retry-all').disabled = !ready || busy;
  $('#retry-transcript').disabled = !ready || busy;
  $('#retry-summary').disabled = !ready || busy || !recording?.hasTranscript;
  $('#recover').disabled = !['incomplete', 'failed'].includes(recording?.status);
  $('#cleanup').disabled = !ready || busy;
}
async function loadDetail(reset = false) {
  if (!selected) return;
  if (reset) {
    segmentOffset = 0;
    activeSegment = undefined;
    $('#segments').replaceChildren();
  }
  const detail = await native('detail', { recordingId: selected, offset: segmentOffset, limit: SEGMENT_PAGE_SIZE });
  const recording = detail.recording || {};
  $('#recording').replaceChildren();
  const heading = document.createElement('h2');
  heading.textContent = recording.title || 'Recording';
  const info = document.createElement('p');
  info.className = 'meta row';
  info.append(pill(recording), metaLine(recording));
  $('#recording').append(heading, info);
  if (recording.error) {
    const problem = document.createElement('p');
    problem.className = 'error';
    problem.textContent = recording.error;
    $('#recording').append(problem);
  }
  if (recording.participants?.length) {
    const people = document.createElement('p');
    people.className = 'meta';
    people.textContent = `Visible participant labels at start: ${recording.participants.join(', ')}. These do not identify transcript speakers.`;
    $('#recording').append(people);
  }
  renderSummary(detail.summary, recording);
  appendSegments(detail.segments);
  segmentOffset += (detail.segments || []).length;
  $('#more').hidden = segmentOffset >= Number(detail.totalSegments || 0);
  setActionAvailability(recording);
}
async function openRecording(id) {
  selected = id;
  playbackRetries = 0;
  $('#list').classList.add('hidden');
  $('#more-recordings').classList.add('hidden');
  $('#detail').classList.remove('hidden');
  try {
    await Promise.all([playbackURL(), loadDetail(true)]);
    notice('');
  } catch (error) {
    notice(`Could not open recording: ${error.message}`);
  }
}
async function action(command, params = {}) {
  const button = document.activeElement instanceof HTMLButtonElement ? document.activeElement : null;
  let completed = false;
  try {
    if (button) button.disabled = true;
    await native(command, { recordingId: selected, ...params });
    await loadDetail(true);
    if (command === 'recover') await playbackURL();
    if (command === 'reprocess') wasProcessing = true;
    notice(command === 'reprocess' ? 'Processing request queued.' : 'Request completed.');
    completed = true;
  } catch (error) {
    notice(error.message);
  } finally {
    if (!completed && button) button.disabled = false;
  }
}
async function pollStatus() {
  try {
    const status = await native('status');
    // Choosing a different folder in Settings swaps the whole library underneath us.
    if (status.libraryPath !== undefined && status.libraryPath !== knownLibraryPath) {
      const firstReading = knownLibraryPath === undefined;
      knownLibraryPath = status.libraryPath;
      if (!firstReading) {
        selected = undefined;
        $('#detail').classList.add('hidden');
        $('#list').classList.remove('hidden');
        await list(true);
        notice(recordingTotal ? `${recordingTotal} recording${recordingTotal === 1 ? '' : 's'} in the new library folder` : 'The new library folder has no recordings yet.');
        return;
      }
    }
    if (status.processing || status.downloading) {
      notice(status.downloading ? 'Language asset download is in progress.' : 'Processing is in progress.');
      if (selected) await loadDetail(true);
    } else if (wasProcessing) {
      if (selected) await loadDetail(true);
      else await list(true);
      notice('Processing finished. Check the recording status for results.');
    }
    wasProcessing = !!(status.processing || status.downloading);
  } catch {
    // The next user action presents a helper error; avoid replacing useful UI with a polling error.
  }
}

$('#refresh').onclick = () => selected ? loadDetail(true).catch(error => notice(error.message)) : list(true);
$('#query').addEventListener('search', () => list(true));
$('#query').addEventListener('change', () => list(true));
$('#more-recordings').onclick = () => list(false);
$('#back').onclick = () => {
  const video = $('#video');
  video.pause();
  video.removeAttribute('src');
  video.load();
  $('#detail').classList.add('hidden');
  $('#list').classList.remove('hidden');
  selected = undefined;
  list(true);
};
$('#more').onclick = () => loadDetail().catch(error => notice(error.message));
$('#retry-all').onclick = () => action('reprocess', { stage: 'all' });
$('#retry-transcript').onclick = () => action('reprocess', { stage: 'transcribe' });
$('#retry-summary').onclick = () => action('reprocess', { stage: 'summary' });
$('#recover').onclick = () => action('recover');
$('#cleanup').onclick = () => action('cleanup');
$('#video').addEventListener('loadeddata', () => { playbackRetries = 0; });
$('#video').addEventListener('timeupdate', () => {
  const time = $('#video').currentTime;
  let found;
  for (const row of $('#segments').children) {
    if (Number(row.dataset.start) <= time) found = row;
    else break;
  }
  if (found === activeSegment) return;
  activeSegment?.classList.remove('is-active');
  activeSegment = found;
  activeSegment?.classList.add('is-active');
});
$('#video').addEventListener('error', async () => {
  if (!selected || playbackRefreshInFlight || playbackRetries >= 1) {
    if (selected) notice('Playback failed. Refresh the recording to request a new local playback URL.');
    return;
  }
  playbackRefreshInFlight = true;
  playbackRetries += 1;
  try {
    await playbackURL({ preserve: true });
  } catch (error) {
    notice(`Could not renew playback: ${error.message}`);
  } finally {
    playbackRefreshInFlight = false;
  }
});
statusPoll = setInterval(pollStatus, 5_000);
window.addEventListener('unload', () => clearInterval(statusPoll));
list();
