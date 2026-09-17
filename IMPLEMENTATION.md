# MeetMe implementation and validation

Validated on 2026-09-15 with macOS 26.6, Swift 6.3.3, macOS SDK 26.5,
Node.js 26.7 and FFmpeg 9.0.1. Transcription offers two user-selectable on-device engines:
Apple's SpeechAnalyzer (30 locales, no download) and WhisperKit via argmax-oss-swift 1.1.0
(~100 languages, one-time model download, automatic language detection).

## Implemented

- Brave MV3 extension with manual tab recording, an offscreen media document, independent
  microphone selection/mute, restored remote audio, recording badges and in-tab indicators.
- Bounded uploads with SHA-256, sequence numbers, duplicate-safe retries, final-blob draining
  and failure cleanup. Native storage acknowledges durable chunks and retains interrupted data.
- Swift native messaging host, authenticated loopback HTTP server, scoped playback URLs,
  byte-range playback, FFmpeg finalization/audio extraction, and persistent sequential jobs.
- Local Apple SpeechAnalyzer transcription using system-managed, locale-specific speech assets.
  Assets are requested automatically when processing begins; Settings can request them early.
- Local WhisperKit transcription for languages Apple ships no assets for, with per-variant
  model download, an offline tokenizer ready-marker, and automatic language detection.
- Apple Foundation Models summaries with context budgeting, recursive reduction, evidence
  timestamp checks, checkpoints and actionable availability/service errors. Transcripts in
  languages Foundation Models cannot read are summarised from a Whisper English translation
  of the same audio; on the Apple engine the summary is skipped with a recorded reason.
- Settings and library UI with engine/language/model selection, download status, search,
  pagination, transcript seeking, rendered summaries with seekable citations,
  playback renewal, recovery, cleanup, re-transcription and re-summary controls.
- Single-command installer (`Install MeetMe.command` / `install/install.sh`, no arguments)
  that builds, signs and installs the helper and registers it in both Brave's and Chrome's
  native-messaging host directories. The extension ID is pinned by the public key in
  `extension/manifest.json`, so registration no longer waits on a hand-copied ID, and
  `--uninstall` reverses everything except the recordings.
- Model download progress reporting with a cancel action, surfaced as a determinate bar in
  Settings; Apple asset installs report no fraction and render an indeterminate bar.

## Checks that passed

| Check | Result |
| --- | --- |
| Debug Swift build | Passed |
| Release Swift build | Passed |
| Six JavaScript lifecycle/queue tests | Passed: sender boundary, failed-start cleanup, duplicate starts, stale completion, final-blob draining, out-of-order checksum completion |
| Native media integration | Passed: synthetic WebM upload, authentication/checksum/order errors, retries, verified finalization, duration, byte ranges and restart recovery |
| Native security integration | Passed: isolated home path canonicalization, work-directory symlink rejection and oversized native frames |
| Real Brave integration in a temporary profile/home | Passed: extension loading, installed native-host connection, random-port CSP access, library listing and capture-state wiring |
| Apple SpeechAnalyzer transcription and summary | Passed: a real user recording was transcribed with Apple SpeechAnalyzer and summarized by Apple Foundation Models |
| Engine catalogue and validation | Passed: `settings` advertises both engines, Whisper exposes Hindi/Malayalam and ~100 deduplicated language codes, and Apple rejects unsupported languages and auto-detect before any download |
| Whisper transcription, detection and translation | **Not run.** The code builds and the model-readiness path reports correctly, but no Whisper model has been downloaded on this Mac, so inference, auto-detection and the translate-then-summarise path are unverified |
| Installer | Shell validation, invalid-input checks and isolated installation passed |
| Settings/library visual inspection | Screenshots inspected; default controls styled and overflow/focus states addressed |

## Remaining acceptance gates and known limitations

- **Live capture remains unverified.** The headless synthetic capture attempt correctly
  failed Chromium's extension-invocation permission check; programmatically opening the
  popup does not grant `activeTab`. Test by clicking the actual extension action on a meeting
  tab. The automated browser smoke does not claim to test media capture and runs muted.
- Verify local mic permission, independent mute behavior, both audio sides, tab/background
  behavior and a one-hour recording in actual Meet, Teams and Zoom web calls.
- Apple SpeechAnalyzer transcription and Apple Foundation Models summary generation have
  completed successfully for a real recording. Broader quality, long-transcript runtime and
  multilingual acceptance testing remain pending.
- **The Whisper engine has never transcribed audio here.** Download a model in Settings, then
  verify: a Hindi or Malayalam recording transcribes in the native script; auto-detect picks
  the right language; and the translate-then-summarise path writes `transcript.en.txt` plus a
  summary whose `[HH:MM:SS]` citations still line up with the recording.
- Measured Whisper model sizes are not yet confirmed; the figures shown in Settings are the
  published approximations for each variant.
- Processing after Apple speech assets are installed, representative accents/languages,
  overlapping speech, peak memory and one-hour timestamp alignment still need acceptance tests.
- `swift test` cannot run with this installed Command Line Tools environment because it lacks
  XCTest. The Swift storage/configuration tests are included for a full Xcode toolchain; the standalone
  executable tests above ran successfully here.
- Platform hints and visible participant-label extraction are advisory and need validation
  against current meeting UIs. Names may be absent when no supported DOM labels are visible.
  On Google Meet, the content script logs who the page shows as speaking (class-name activity under each `data-participant-id` element) and the helper labels transcript segments from that log (`speakers.jsonl`). This is the page's indicator, not voice recognition; Teams and Zoom are not covered.
- Personal installation is ad-hoc signed, not notarized or submitted to an extension store.
  The native helper was subsequently registered for the user's installed MeetMe extension
  during first-run troubleshooting.

## Commands

```sh
swift build --package-path helper
swift build --package-path helper --configuration release --product MeetMeHelper
node --test tests/background_state.test.mjs tests/offscreen_capture.test.mjs
python3 tests/smoke_helper.py
python3 tests/native_security_smoke.py
node tests/smoke_browser.mjs
```

For installation and first-run setup, see [README.md](README.md).

## First-run folder picker fix

The helper now runs a synchronous AppKit application event loop and opens NSOpenPanel
asynchronously. A real folder selection returned successfully, a subsequent native request
on the same process succeeded, and debug/release builds plus native media/security checks
passed. The corrected release helper is installed. Settings allow up to ten minutes for
folder selection and pause background status polling while the picker is open.
