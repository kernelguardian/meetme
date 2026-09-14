# MeetMe — Implementation Plan

Browser-based meeting capture + on-device transcription and summary, for macOS.

> **Status:** implemented locally, including the MV3 extension, Swift helper, native-host
> installer and automated smoke coverage. Runtime acceptance validation is still required.
> **Target machine (as recorded in the original plan):** Apple **M1 Pro**, **16 GB** RAM,
> **macOS 26.6 (Tahoe)**, browser = **Brave** (Chromium).
> **Feasibility:** the architecture is viable. Validate capture, long-recording storage,
> playback, and the native audio/AI pipeline before expanding platform coverage.

---

## 1. Goal and scope

A personal tool to:

1. Join **Google Meet / Microsoft Teams (web) / Zoom (web)** in Brave and click **Record**
   to capture the meeting tab's video and remote audio, plus an optional local microphone.
2. **Later** (batch, not real-time) transcribe and summarise recordings **on-device**.
   MeetMe does not upload meeting content for processing. Initial model downloads need
   network access; processing must work offline once the required models are available.
3. Save `video + transcript + summary` per meeting under **one folder chosen once**.
4. Browse recordings through a **local extension UI** with playback, transcripts,
   summaries, search, and reprocessing controls.

**Design decisions:**

- Record first; transcribe and summarise sequentially after recording ends.
- **One-click start per meeting.** Join detection may remind the user to invoke the
  extension; it cannot independently grant tab-capture permission. Unattended auto-start
  is outside this design.
- Use **WhisperKit** for local Whisper inference through Core ML and **Apple Foundation
  Models' on-device model** for summaries. Benchmark quality, processing time and peak
  memory on the target Mac; local execution does not inherently mean higher quality.
- No manually managed daemon. Brave launches the helper through a persistent native
  messaging connection. The extension manages its lifetime while work or playback is active.
- **Brave must remain running for processing.** Persist unfinished jobs and restart them
  when the extension reconnects. Continuing after browser exit would require a different
  native lifecycle and is outside the initial scope.
- Single active recording. Defer pending ML jobs while recording; if a job is already
  running, checkpoint/cancel it at a safe boundary before starting capture.

**Native footprint:** a Swift helper is needed to access the selected macOS frameworks.
It owns storage, job recovery, media preparation and ML. Include a local FFmpeg executable
for WebM finalization and audio extraction, plus downloaded Whisper models. This is more
than a minimal messaging bridge, but remains locally managed.

---

## 2. Architecture

```
Brave (Chromium / MV3 extension)             Swift native helper
───────────────────────────────             ───────────────────
content scripts                             Native Messaging: control + small text
  join/leave hints, title/participant data      folder pick, recording sessions, jobs
  recording + microphone indicators           library queries, playback URL issuance
service worker
  user-invoked capture, native port          Localhost HTTP: bulk bytes
  recording state and reconnection            ordered chunk upload + acknowledgements
offscreen document                            authenticated, range-served video
  tab + optional mic → Web Audio
  MediaRecorder → bounded upload queue      Disk + post-recording jobs
extension full-tab UI                         finalize/remux WebM → extract WAV
  library, player, transcript, summary         WhisperKit → timestamped transcript
  search, re-run and recovery controls         Foundation Models → cited summary
```

### 2.1 Transport, authentication and helper lifetime

- Use `chrome.runtime.connectNative()` from the service worker, not one-shot
  `sendNativeMessage()` for ongoing work. Retain one shared port during recording,
  processing or library playback. A native connection keeps the service worker alive
  on supported Chromium versions; handle host failures through `onDisconnect`.
- Use native messaging for control and bounded text responses. Paginate library and
  transcript responses to stay below the **1 MiB host-to-browser message limit**.
  Keep stdout exclusively for framed protocol messages; send logs to stderr.
- Bind HTTP to **127.0.0.1**, use a random port and a cryptographically random token per
  launch, and send connection details over native messaging. Authenticate uploads/API
  requests with bearer headers. Keep tokens in trusted extension contexts.
- A normal `<video src>` cannot attach a custom bearer header. Issue a **short-lived,
  recording-scoped playback URL token** for range requests. Make it valid for repeated
  range requests during playback, renew it when needed, and avoid logging token URLs.
- Restrict CORS to the extension origin where applicable; validate Host and request paths.
  Use opaque recording IDs mapped by the helper to files, never client-supplied paths.
  Configure extension permissions/CSP for the chosen localhost requests and media source.
- On host restart, mint fresh credentials, reconcile recording/job state, and refresh
  playback URLs. Disconnect when idle. On stdin EOF, the helper must stop accepting work
  and exit; also assume abrupt termination can happen and persist state accordingly.
- Closing the popup must not stop capture or processing. Quitting Brave stops this
  browser-bound workflow; completed files and durable job state remain on disk.

### 2.2 Capture and microphone behavior

- Complete folder selection and microphone onboarding before the first recording.
  Request microphone access from a visible extension page and verify offscreen access
  in Brave. Support remote-audio-only capture if microphone access is declined.
- Following the user invoking the extension on the meeting tab, call
  `chrome.tabCapture.getMediaStreamId({ targetTabId })` and immediately consume its
  short-lived ID in the **offscreen document**. This service-worker/offscreen flow
  requires Chromium 116 or later; verify behavior in the installed Brave version.
- Create the offscreen document with `USER_MEDIA`; service workers cannot hold the
  recording's `MediaStream` or `MediaRecorder`. Consume the ID using `getUserMedia`
  with `chromeMediaSource: 'tab'` and `chromeMediaSourceId` for video and audio.
- Obtain the selected mic through a separate `getUserMedia({ audio: ... })` stream.
  Mix remote audio and mic through Web Audio into a `MediaStreamAudioDestinationNode`,
  then combine the mixed audio track with the tab video track.
- **Restore remote-audio playback:** tab capture suppresses the tab's normal audio.
  Connect the remote source to both the recording mix and `AudioContext.destination`.
  Do not connect the local mic to speaker output. Verify headphones and speakers for
  echo, duplicate audio and clipping; apply suitable mic constraints and mix gain.
- **MeetMe mic mute is independent of meeting mute.** Show a persistent recording and
  microphone state indicator, with an explicit MeetMe mic toggle. Muting in Meet/Teams/
  Zoom does not mute MeetMe's separate stream. Explain this during onboarding.
- Prefer WebM with VP9/Opus only after `MediaRecorder.isTypeSupported()` and runtime
  validation; provide a tested VP8/Opus fallback. Start with a capped resolution, frame
  rate and bitrate (for example 720p at 15 fps) and benchmark CPU use during a real call.
- Manual Record/Stop must work without content-script scraping. Join/leave detection is
  advisory; never discard or finalize data solely because a selector disappeared.

### 2.3 Durable upload and recording finalization

- Allocate a unique recording ID and persist its initial metadata before capture starts.
- `MediaRecorder.start(timeslice)` emits blobs into a **serialized, bounded upload queue**.
  Each request includes recording ID, sequence number, byte length and checksum.
  The helper acknowledges a chunk only after durable storage.
- Make retries idempotent: acknowledge identical repeated chunks without appending them
  again; reject conflicting duplicates and unexpected sequence numbers. Persist the
  last committed chunk so reconnection can reconcile state.
- `timeslice` does not guarantee precise timing, small blobs, or bounded total memory.
  Set explicit queue byte limits and upload timeouts. If the helper/disk cannot keep up,
  stop capture with a visible error before unbounded growth, retain committed data and
  label the recording incomplete. Do not silently drop chunks or pause away speech.
- On Stop, wait for the recorder's final `dataavailable`/`stop` sequence, drain and
  acknowledge all queued chunks, then finalize with the expected chunk count and bytes.
  Do not enqueue transcription until finalization succeeds.
- Individual MediaRecorder blobs need not be independently playable. Assemble all chunks
  from the same recording in order. Preserve temporary data until assembly is verified.
- **Remux locally with FFmpeg without re-encoding** to produce a finalized `video.webm`
  with usable duration and seeking metadata. Write a temporary output, validate it and
  atomically promote it. HTTP range support alone does not establish seekability.
- On a crash, recover committed data where possible. Missing final data can leave an
  unrepairable recording; show incomplete/recoverable/failed status honestly. Never
  promise that an in-progress recording survives browser exit without data loss.

### 2.4 Native audio, transcription and summary pipeline

1. **Prepare audio:** extract the finalized WebM's mixed audio using local FFmpeg into
   mono 16 kHz WAV. Do not assume WebM/Opus can be passed directly to WhisperKit. Preserve
   the recording timeline and verify timestamp alignment against the final video.
2. **Transcribe:** use a pinned WhisperKit package version supporting incremental audio
   loading, configured explicitly for bounded-memory loading. Start by benchmarking
   base/small models; choose the default using representative meeting speech. Save
   timestamped segments, SRT and plain text. Release transcription resources before summary.
3. **Summarise:** check `SystemLanguageModel.default.availability` and explicitly use the
   on-device model. If unavailable, retain the transcript and show a retryable summary
   status. Do not fall back to a cloud provider.
4. **Manage context:** use the runtime context size/token-count APIs where available,
   with a conservative budget for the macOS 26 model's approximately 4,096-token window.
   Budget instructions, schemas, source text and generated output together. Split by
   token budget at segment boundaries, retain timestamps, and start a fresh session for
   each chunk. Recursively reduce summaries if their combined size still exceeds budget.
5. **Ground summaries:** request decisions, action items, open questions and supporting
   timestamps. Retain evidence through every reduction stage; use “unspecified” for
   missing owners/dates. Treat transcript text as source data, not instructions. Validate
   output and handle context errors, refusals and unsupported language gracefully.

A mixed transcript does **not** automatically identify individual speakers. Scraped
participant names are metadata, not evidence of who spoke. Speaker diarization and mapping
voices to names are separate future work; do not assign names based on the attendee list.

### 2.5 Storage and job recovery

```
<library>/
  <timestamp>_<title>_<unique-id>/
    video.webm
    transcript.json     # timestamped segments for UI and summary evidence
    transcript.srt
    transcript.txt
    summary.md
    meta.json           # ID, title, platform, participants, times, duration,
                        # capture/mic settings, model versions, artifact/job states
    work/               # committed chunks, temporary outputs, audio.wav,
                        # durable processing checkpoints; cleaned after success
```

- The helper owns the chosen folder. Persist the location; re-prompt only if it becomes
  unavailable or access is lost. If sandboxing is introduced, persist the appropriate
  security-scoped access rather than assuming a path alone is sufficient.
- Use atomic metadata/artifact replacement. Persist job states such as `queued`, `running`,
  `completed`, `failed` and `interrupted`, separately from recording completeness.
- On reconnect, requeue interrupted processing from a validated checkpoint, or restart
  the stage safely. Preserve the recording and previous successful artifacts on failure.
- Re-run commands are idempotent and serialized per recording. Cache completed summary
  chunks with source/model/prompt-version identity before reusing them after interruption.
- Check free space for capture plus temporary remux/audio files. Offer cleanup/retry for
  failed work; remove recovery inputs only after the corresponding output is verified.

---

## 3. Components / files

| Path | Purpose |
| --- | --- |
| `extension/manifest.json` | MV3; `activeTab`, `tabCapture`, `offscreen`, `storage`, `nativeMessaging`; narrow meeting and localhost host permissions. Verify actual Teams/Zoom web origins in integration testing. |
| `extension/background.js` | User-invoked capture, shared native port, offscreen lifecycle, state reconciliation and job scheduling. |
| `extension/offscreen.{html,js}` | Tab/mic streams, audio monitoring and mixing, mic toggle, MediaRecorder, bounded chunk queue and final drain. |
| `extension/content/{meet,teams,zoom}.js` | Advisory join/leave detection, title/participant metadata and visible recording/mic state. |
| `extension/popup.{html,js}` | Primary Record/Stop and MeetMe mic controls; capture independent of scraping. |
| `extension/options.{html,js}` | Folder selection, visible microphone permission onboarding, device selection, join reminders and model settings. |
| `extension/webui/` | Vanilla JS/CSS library, authenticated player, transcript seeking, summaries, search, re-run and recovery status. |
| `helper/Package.swift` | SwiftPM; pinned WhisperKit dependency, macOS 26 FoundationModels framework, chosen HTTP-server dependency if required. |
| `helper/Sources/App/NativeMessaging.swift` | Length-prefixed JSON protocol, bounded responses, stdout discipline and EOF shutdown. |
| `helper/Sources/App/HTTPServer.swift` | Loopback authentication, recording-scoped playback tokens, range responses and chunk endpoints. |
| `helper/Sources/App/RecordingStore.swift` | Durable chunk acknowledgements, deduplication, finalization and incomplete-recording recovery. |
| `helper/Sources/App/MediaPrepare.swift` | FFmpeg discovery/invocation, WebM remux/validation and mono 16 kHz WAV extraction. |
| `helper/Sources/App/Transcribe.swift` | Incremental WhisperKit input and timestamped JSON/SRT/text output. |
| `helper/Sources/App/Summarize.swift` | On-device availability, context budgeting, recursive map-reduce and source timestamps. |
| `helper/Sources/App/Jobs.swift` | Persistent sequential queue, interruption handling, checkpoints and retries. |
| `helper/Sources/App/Library.swift` | Folder configuration, IDs, metadata, artifact writes and library queries. |
| `install/com.meetme.helper.json.template` | Native-host manifest template with the exact extension ID in `allowed_origins`; the installer writes the resolved manifest. |
| `install/install.sh` | Build product `MeetMeHelper`, stage any SwiftPM `.bundle` resources, ad-hoc sign the copied binary, and register the host in Brave's Chrome-compatible `~/Library/Application Support/Google/Chrome/NativeMessagingHosts` directory. |

---

## 4. Build phases and acceptance gates

1. **Capture/storage proof — Meet only.** Manual Record/Stop, microphone onboarding and
   toggle, offscreen mixing with remote monitoring, native folder picker, durable uploads,
   finalization and a minimal authenticated range player. Verify both audio sides and
   MeetMe mute behavior, then record a one-hour call and seek near the beginning, middle
   and end. Exercise upload failure, disk failure and helper disconnection. This gate
   precedes AI work and polished UI.
2. **Audio preparation and transcription.** Extract WAV, run incremental WhisperKit,
   produce timestamped outputs and add persistent processing jobs/backfill. Verify speech
   accuracy and timestamp alignment, record processing time and peak memory, and quit/
   reopen Brave during processing to verify recovery. Benchmark on representative accents,
   languages, technical terms and overlapping speech.
3. **Local summaries.** Implement availability handling, budgeted recursive map-reduce,
   evidence timestamps and retry/checkpoints. Verify a one-hour transcript, an input
   requiring multiple reduction levels, and transcript-only operation when the model is
   unavailable. Check action items and decisions against the actual transcript.
4. **Library UI.** Add browsing, transcript click-to-seek, summaries, search, re-runs,
   recovery/error states and token renewal. Verify playback after a helper restart and
   ensure closing the popup does not interrupt work.
5. **Teams + Zoom web.** Validate their real web origins, tab capture, mic behavior and
   audio quality in Brave. Add platform metadata/reminder scripts. Manual recording
   remains the primary path. Native desktop clients are outside this capture scope.
6. **Polish and install experience.** Join reminders, resilient participant scraping,
   settings, model onboarding, cleanup and distribution packaging. Essential recording,
   microphone and failure indicators must already exist in Phase 1.

---

## 5. Risks and constraints

- **Browser/platform behavior:** Chromium documentation supports the core flow, but Brave
  permissions, offscreen mic access, background tabs and each meeting platform need real
  tests. Tab capture records the tab's rendered content and audible output, not separate
  remote video/audio tracks or content the platform never renders.
- **Meeting UI changes:** selectors can break. Keep metadata optional and Record/Stop
  independent of scraping; show unknown metadata instead of guessing.
- **Performance:** 16 GB is a reasonable target, not a guarantee. Limit recording quality,
  bound queues and audio loading, serialize processing, and measure memory with Brave open.
- **Availability:** Apple Intelligence must be enabled and its on-device model ready.
  Handle model downloads, unsupported settings/languages and temporary unavailability.
  Whisper download size depends on the chosen model; do not assume one fixed small size.
- **Reliability:** committed chunks can be retained, but browser crashes, sleep, disk-full
  events and missing final blobs can truncate recordings. Clearly surface incomplete data.
- **Packaging:** personal local builds and distributed installs have different signing
  needs. Ad-hoc signing alone is not a general Gatekeeper/distribution solution. For
  distribution, plan signing/notarization and review the selected FFmpeg build's license.
- **Privacy:** choose a non-synced local folder for a strictly local library; a folder
  managed by cloud-sync software may upload files independently of MeetMe. Never send
  transcripts to a cloud fallback. Clearly show when the independent local mic is recorded.
- **Recording consent:** provide a reminder to obtain any required participant consent
  and follow applicable meeting policies before recording.

---

## 6. Verification

- **Real calls:** Meet first, then Teams/Zoom web; both audio sides, speakers/headphones,
  mic denied, MeetMe mic mute versus platform mute, device changes, tab switches and closure.
- **Long recordings:** at least one hour; monitor queue size, CPU, memory, disk use, audio/
  video sync, finalized duration and seeking without downloading the entire file first.
- **Failure injection:** slow uploads, duplicate/retried chunks, missing chunks, helper
  crash, browser quit, sleep/wake and disk-write failure. Preserve successful artifacts
  and mark incomplete recordings; verify processing retries after reconnect.
- **Helper tests:** native framing and payload limits; ordered/deduplicated chunks and
  finalization; valid/invalid playback tokens; normal, partial and unsatisfiable HTTP ranges;
  path validation; job recovery; timestamp/SRT formatting; summary budgets/checkpoints.
- **AI checks:** representative speech and language samples, silence/overlap, summary
  evidence, missing owners/dates, long inputs and unsupported/unavailable model behavior.
- **Offline check:** after model setup, process a saved recording with network disabled
  and confirm transcript and summary generation do not require an external service.

---

## 7. Prerequisites and first run

- Verify the actual macOS/Brave versions and required APIs on the target Mac.
- Install a Swift toolchain and macOS SDK supporting FoundationModels/macOS 26; use
  compatible Xcode/Command Line Tools and verify the selected SDK before building.
- Install or bundle the selected FFmpeg build and verify executable discovery.
- Load the unpacked extension; register its exact ID in the native-host manifest and run
  the installer. Keep that ID stable across local development installations.
- Launch onboarding: choose a local library folder, request mic access if wanted, select
  the device, explain independent MeetMe mute, and check Apple Intelligence availability.
- Download the chosen Whisper model, verify cached offline loading, and run a short
  recording → playback → transcription → summary smoke test.

---

## 8. API references and implementation notes

- [Chrome tabCapture](https://developer.chrome.com/docs/extensions/reference/api/tabCapture):
  user invocation, target-tab access, stream IDs and restoring captured audio playback.
- [Chrome background capture example](https://developer.chrome.com/docs/extensions/how-to/web-platform/screen-capture):
  Chromium 116+ service-worker → offscreen flow with `USER_MEDIA`.
- [Native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
  and [service-worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle):
  persistent `connectNative()`, host lifecycle and connection recovery. Framing uses a
  32-bit length in native byte order (little-endian on the target Mac) plus UTF-8 JSON;
  the host-to-browser message limit is 1 MiB.
- [MediaStream Recording specification](https://www.w3.org/TR/mediastream-recording/):
  individual blobs need not be playable; the complete ordered recording must be.
- [HTML media specification](https://html.spec.whatwg.org/multipage/media.html):
  media URL and credentials behavior; no custom bearer-header parameter on `<video>`.
- [FFmpeg formats](https://ffmpeg.org/ffmpeg-formats.html): WebM/Matroska muxing and seek cues.
- [WhisperKit / Argmax Swift](https://github.com/argmaxinc/argmax-oss-swift): supported
  audio examples and `AudioInputOptions(audioLoadingMode: .incremental)`. Pin and validate
  a package version that contains the selected APIs; the old WhisperKit repo redirects here.
- [Apple context management](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
  and [Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels):
  availability, session budgets and newer token-count/context-size APIs. Check availability
  for the deployment target and revalidate prompts after system model updates.
