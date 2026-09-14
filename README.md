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
- Apple Speech transcription available for the selected language. MeetMe lists the languages
  supported by the current Mac; it automatically asks macOS to install required speech assets
  when transcription starts. The optional Settings download action can install them earlier.
  After installation, processing uses the system's on-device assets.

## Install for personal use

From this project directory:

1. Open `brave://extensions`, enable **Developer mode**, choose **Load unpacked**, and
   select the `extension` folder. Copy the extension's ID.
2. Build and register the helper:

   ```sh
   ./install/install.sh --extension-id YOUR_32_CHARACTER_EXTENSION_ID
   ```

3. Reload the extension in Brave. Open MeetMe's **Settings**, choose your recording
   folder, configure microphone access, and select a supported transcription language. You
   may optionally download that language's Apple speech assets before your first recording.
4. Open a meeting tab. Invoke MeetMe and click **Record**. Click **Stop** when finished;
   leave Brave running while local processing completes. Open **Library** for playback,
   transcript, summary and retry controls.

The installer registers `com.meetme.helper` in Brave's Chrome-compatible native-messaging
host directory, `~/Library/Application Support/Google/Chrome/NativeMessagingHosts`. It copies
the `MeetMeHelper` product and any SwiftPM `.bundle` resources to
`~/Library/Application Support/MeetMe/bin`, then ad-hoc signs the copied binary. It does not
install a daemon. Brave launches the helper on demand. Re-run the installer after helper
changes; reload the extension after extension changes. If the unpacked extension ID changes,
run the installer with the new ID.

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
- Transcripts contain timestamps but do not automatically identify speakers by name.
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
- **Transcription unavailable:** select a language listed in Settings and let macOS finish
  installing its Apple speech assets. Check free disk space and that FFmpeg/FFprobe are
  present at the paths configured by the installer.
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
