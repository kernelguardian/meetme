# MeetMe

Record a meeting tab in Brave, then transcribe and summarise it on your Mac. MeetMe is a
Manifest V3 extension plus a Swift native helper. Recordings and generated text are saved
in a folder you select. Meeting content is not sent to a transcription or summary service.

## Requirements

- Apple silicon Mac running macOS 26 or newer; the development target is M1 Pro / 16 GB.
- Brave with Chromium 116 or newer.
- A Swift toolchain and macOS SDK with FoundationModels support.
- FFmpeg and FFprobe available locally (for example, a Homebrew FFmpeg installation).
- Python 3 for the installer and helper smoke checks. Node.js 22 or newer is required
  for the JavaScript tests and browser integration check.
- Apple Intelligence enabled and its on-device model available for summaries.
- For the Apple transcription engine, Apple Speech assets for the selected language. MeetMe
  lists the languages the current Mac supports and asks macOS to install the assets when
  transcription starts; the Settings download action can install them earlier.
- For the Whisper engine, roughly 150 MB to 1.6 GB of disk for the chosen model. Whisper
  will not process a recording until its model has been downloaded in Settings.

## Choosing a transcription engine

Both engines run entirely on this Mac. Settings lets you pick per language.

| | Apple | Whisper |
|---|---|---|
| Languages | 30 locales | ~100, including Hindi, Malayalam, Tamil, Telugu, Bengali |
| Setup | No download | One-time model download |
| Speed | Faster | Slower |
| Auto-detect language | No | Yes |

Apple's `SpeechTranscriber` ships no assets for any Indic language other than English (India),
so Hindi, Malayalam and their neighbours require Whisper. Apple Intelligence summarises only
23 languages; when a transcript falls outside that set, MeetMe uses Whisper to produce an
English translation of the same audio and summarises that, keeping the `[HH:MM:SS]` citations
aligned with the recording. On the Apple engine the summary is skipped instead, and the
recording says why.

## Install for personal use

Double-click **`Install MeetMe.command`** in Finder, or run this from the project directory:

```sh
./install/install.sh
```

That builds the helper, signs it, installs it, and registers it for the extension. It takes
no arguments: the extension's ID is pinned by the public key in `extension/manifest.json`,
so the installer knows the ID before the extension has ever been loaded.

Brave does not let any script install an extension, so one manual step remains and the
installer walks you through it: open `brave://extensions`, turn on **Developer mode**, choose
**Load unpacked**, and select this project's `extension` folder. The installer opens that page
for you and detects on later runs whether the step is already done.

Then open MeetMe's **Settings** to choose a recordings folder, configure microphone access,
and pick a transcription engine and language. On the Apple engine you may optionally
pre-install that language's speech assets; on Whisper you must download the model first.

To record: open a meeting tab, invoke MeetMe and click **Record**. Click **Stop** when
finished and leave Brave running while local processing completes. Open **Library** for
playback, transcript, summary and retry controls.

`./install/install.sh --uninstall` removes the helper and its registrations, leaving your
recordings untouched. Run `--help` for the remaining options.

The installer registers `com.meetme.helper` in both Brave's own native-messaging host
directory and the Chrome-compatible one, so it works whichever Brave consults. It copies the
`MeetMeHelper` product and any SwiftPM `.bundle` resources (WhisperKit ships some) to
`~/Library/Application Support/MeetMe/bin`, then ad-hoc signs the copied binary. It does not
install a daemon. Brave launches the helper on demand. Re-run the installer after helper
changes; reload the extension after extension changes.

Because the extension ID is derived from the manifest's `key`, it no longer changes when the
folder moves and never needs to be copied by hand. If you previously loaded MeetMe before
that key existed, Brave still lists the old copy under its old ID: remove it and load the
folder again.

Preview installation without changing anything:

```sh
./install/install.sh --extension-id YOUR_32_CHARACTER_EXTENSION_ID --dry-run
```

For a debug build, add `--configuration debug`. After building manually, add `--skip-build`.
Use `--ffmpeg /absolute/path/to/ffmpeg --ffprobe /absolute/path/to/ffprobe` if the tools are
not on your shell's PATH. Run `./install/install.sh --help` for all options.

## Recording behavior

- Starting requires invoking the extension on the tab. Joining a call does not grant
  automatic recording permission.
- **MeetMe's microphone is independent of the meeting's mute button.** Muting yourself
  in Meet, Teams or Zoom does not mute MeetMe. Use MeetMe's mic control when recording.
- Remote audio is routed back to your speakers/headphones while also being recorded.
  Headphones help avoid echo. MeetMe does not play your own mic through the speakers.
- Closing the popup does not stop a recording. Closing the captured tab ends capture.
- Keep Brave open for processing. Interrupted jobs are saved for retry after reconnecting.
  A browser crash can lose uncommitted media; incomplete recordings are labelled accordingly.
- Capture covers the rendered browser tab, not native desktop meeting apps. Participants
  hidden by the meeting's layout are not captured as separate video feeds.
- On Google Meet, transcript lines are labelled with whoever Meet showed as speaking at that
  moment. This follows Meet's on-screen indicator rather than recognising voices, so overlapping
  speech goes to whoever spoke longest. Teams and Zoom transcripts have timestamps only.
- Choose a non-synced local folder if you want to prevent separate cloud-sync software
  from uploading your recordings. Obtain any required participant consent before recording.

## Development

```sh
swift build --package-path helper
```

`swift test --package-path helper` is appropriate on a full Xcode installation. Some Command
Line Tools-only macOS setups do not include the XCTest module, so that command can fail before
the package tests run. In that environment, build the executable and run the isolated checks
below instead:

```sh
python3 tests/smoke_helper.py
python3 tests/native_security_smoke.py
node --test tests/background_state.test.mjs tests/offscreen_capture.test.mjs
node tests/smoke_browser.mjs
```

The first two require a debug helper build plus FFmpeg/FFprobe. The last command requires
Node.js 22+, Brave, and a debug helper build; it uses `CFFIXED_USER_HOME` and temporary
configuration, library, profile, native-host and installation paths. These checks do not
register the helper in your personal home directory or use your recording library.

The native host communicates using length-prefixed JSON on stdin/stdout. Diagnostic output
belongs on stderr. Its loopback HTTP server carries media bytes; control messages and
credentials travel through native messaging. See [plan.md](plan.md) for the architecture
and acceptance gates.

The helper supports `MEETME_CONFIG_DIR` and `MEETME_LIBRARY_DIR` environment overrides for
isolated development. Do not point tests at your personal recording library.

The toolbar and app icons in `extension/icons/` are committed, and regenerated only when the
mark itself changes:

```sh
python3 tools/make-icons.py
```

It needs Pillow and writes both the idle and recording variants.

## Troubleshooting

- **Native host not found:** run the installer with the ID currently displayed in
  `brave://extensions`, then reload the extension. Confirm the manifest's absolute launcher
  path exists and is executable.
- **Microphone unavailable:** grant access in MeetMe Settings and macOS/Brave permissions.
  You can still record remote audio with the MeetMe mic disabled.
- **Summary unavailable:** check Apple Intelligence availability. A system may report the
  model as available while its local service still fails (observed ModelManager error 1013
  on the development Mac). Finish pending Apple Intelligence downloads and follow the
  displayed retry guidance. Keep the transcript and retry when the model service is ready.
- **Transcription unavailable:** on the Apple engine, select a language listed in Settings
  and let macOS finish installing its speech assets; on Whisper, download the model in
  Settings first, since processing will not start without it. Check free disk space and that
  FFmpeg/FFprobe are present at the paths configured by the installer.
- **Your language is missing:** Apple's engine only lists what macOS ships assets for, which
  excludes every Indic language except English (India). Switch the engine to Whisper, which
  covers about 100 languages and can also detect the language automatically.
- **Interrupted recording:** use the library recovery action. Only committed chunks can be
  recovered; a damaged or truncated source may not be repairable.

To unregister MeetMe, remove `com.meetme.helper.json` from
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts` and remove
the extension in Brave. This does not delete the library you selected. The local installer
uses ad-hoc signing; shipping to other Macs requires a proper distribution/signing process.

## Validation status

This is a local implementation, not a store-distributed or notarized release. Automated
checks cover the paths listed in [IMPLEMENTATION.md](IMPLEMENTATION.md). Real Meet/Teams/Zoom calls,
one-hour performance, microphone permissions, transcription quality and summary accuracy
still require acceptance testing on actual meeting content before relying on it for
important recordings.

The helper integration test generates a two-second clip in a temporary library. The browser
check uses a muted headless Brave instance with a temporary profile/home and removes its
temporary installation afterward. Neither uses a microphone or personal recording data.
