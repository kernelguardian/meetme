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
function recordingMeta(recording) {
  const created = recording.createdAt ? new Date(recording.createdAt).toLocaleString() : '';
  const job = recording.jobStatus && recording.jobStatus !== 'none' ? `${recording.jobStatus}${recording.jobStage ? ` (${recording.jobStage})` : ''}` : '';
  return [recording.platform, created, recording.status, job, recording.error].filter(Boolean).join(' · ');
}
function item(recording) {
  const card = document.createElement('article');
  card.className = 'card';
  const title = document.createElement('h2');
  title.textContent = recording.title || 'Untitled meeting';
  const meta = document.createElement('p');
  meta.className = 'meta';
  meta.textContent = recordingMeta(recording);
  const open = document.createElement('button');
  open.textContent = 'Open';
  open.onclick = () => openRecording(recording.id);
  card.append(title, meta, open);
  return card;
}
async function list(reset = true) {
  try {
    if (reset) {
      recordingOffset = 0;
      recordingTotal = 0;
      $('#list').replaceChildren();
    }
    notice(recordingOffset ? 'Loading more recordings…' : 'Loading library…');
    const result = await native('list', { offset: recordingOffset, limit: RECORDING_PAGE_SIZE, query: $('#query').value.trim() });
    const items = result.items || [];
    $('#list').append(...items.map(item));
    recordingOffset += items.length;
    recordingTotal = Number(result.total || 0);
    $('#more-recordings').classList.toggle('hidden', recordingOffset >= recordingTotal);
    notice(`${recordingTotal} recording${recordingTotal === 1 ? '' : 's'}`);
  } catch (error) {
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
    const button = document.createElement('button');
    const start = Number(segment.start ?? segment.startTime ?? 0);
    button.textContent = `[${stamp(start)}] ${segment.text || ''}`;
    button.onclick = () => {
      $('#video').currentTime = start;
      $('#video').play().catch(() => notice('Use the player controls to start playback.'));
    };
    box.append(button);
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
    $('#segments').replaceChildren();
  }
  const detail = await native('detail', { recordingId: selected, offset: segmentOffset, limit: SEGMENT_PAGE_SIZE });
  const recording = detail.recording || {};
  $('#recording').replaceChildren();
  const heading = document.createElement('h2');
  heading.textContent = recording.title || 'Recording';
  const meta = document.createElement('p');
  meta.className = 'meta';
  meta.textContent = recordingMeta(recording);
  $('#recording').append(heading, meta);
  if (recording.participants?.length) {
    const people = document.createElement('p');
    people.className = 'meta';
    people.textContent = `Visible participant labels at start: ${recording.participants.join(', ')}. These do not identify transcript speakers.`;
    $('#recording').append(people);
  }
  $('#summary').textContent = detail.summary || 'No summary yet.';
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
    if (status.processing || status.downloading) {
      notice(status.downloading ? 'Model download is in progress.' : 'Processing is in progress.');
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
