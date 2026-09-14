#!/bin/bash
# Register the locally built helper for Brave. No daemon or administrator access.
set -euo pipefail

meetme_repo="$(cd "$(dirname "$0")/.." && pwd)"
meetme_id=""
meetme_configuration="release"
meetme_skip_build=0
meetme_dry_run=0
meetme_install_root="$HOME/Library/Application Support/MeetMe"
meetme_host_dir="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
meetme_ffmpeg="${MEETME_FFMPEG:-}"
meetme_ffprobe="${MEETME_FFPROBE:-}"

usage() {
  cat <<'USAGE'
Usage: install/install.sh --extension-id ID [options]

Load extension/ in brave://extensions first, then copy its 32-character ID.

Options:
  --extension-id ID        Brave's unpacked extension ID (required)
  --configuration MODE    release (default) or debug
  --skip-build            Install an existing build
  --ffmpeg PATH           Absolute path to ffmpeg
  --ffprobe PATH          Absolute path to ffprobe
  --dry-run               Check prerequisites and print destinations; change nothing
  --install-root PATH     Override helper installation directory
  --host-dir PATH         Override Brave NativeMessagingHosts directory
  -h, --help              Show this help

To unregister, remove only com.meetme.helper.json from NativeMessagingHosts.
Recordings are stored in the folder selected in MeetMe, separately from registration.
USAGE
}
fail() { printf 'MeetMe: %s\n' "$*" >&2; exit 1; }
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || fail "Missing value for $1"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --extension-id) need_value "$@"; meetme_id="$2"; shift 2 ;;
    --configuration) need_value "$@"; meetme_configuration="$2"; shift 2 ;;
    --ffmpeg) need_value "$@"; meetme_ffmpeg="$2"; shift 2 ;;
    --ffprobe) need_value "$@"; meetme_ffprobe="$2"; shift 2 ;;
    --install-root) need_value "$@"; meetme_install_root="$2"; shift 2 ;;
    --host-dir) need_value "$@"; meetme_host_dir="$2"; shift 2 ;;
    --skip-build) meetme_skip_build=1; shift ;;
    --dry-run) meetme_dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ "$meetme_id" =~ ^[a-p]{32}$ ]] || fail "Pass --extension-id with Brave's 32 lowercase a–p characters."
case "$meetme_configuration" in debug|release) ;; *) fail "Configuration must be debug or release." ;; esac
[ "$(uname -s)" = Darwin ] || fail "The helper requires macOS."
command -v swift >/dev/null || fail "Install compatible Xcode Command Line Tools first."
command -v python3 >/dev/null || fail "Python 3 is required to generate the native-host manifest."
command -v codesign >/dev/null || fail "macOS codesign is required."
for meetme_destination in "$meetme_install_root" "$meetme_host_dir"; do
  case "$meetme_destination" in /*) ;; *) fail "Destination paths must be absolute." ;; esac
done
if [ -z "$meetme_ffmpeg" ]; then meetme_ffmpeg="$(command -v ffmpeg || true)"; fi
if [ -z "$meetme_ffprobe" ]; then meetme_ffprobe="$(command -v ffprobe || true)"; fi
for meetme_executable in "$meetme_ffmpeg" "$meetme_ffprobe"; do
  case "$meetme_executable" in /*) ;; *) fail "Install FFmpeg (including ffprobe), or specify both absolute paths." ;; esac
  [ -x "$meetme_executable" ] || fail "Executable not found: $meetme_executable"
done
meetme_source="$meetme_repo/helper/.build/$meetme_configuration/MeetMeHelper"
if [ "$meetme_skip_build" = 1 ]; then
  [ -x "$meetme_source" ] || fail "Build missing: $meetme_source"
fi
if [ "$meetme_dry_run" = 1 ]; then
  printf 'Build: %s\nHelper: %s/bin/MeetMeHelper\nManifest: %s/com.meetme.helper.json\nOrigin: chrome-extension://%s/\nFFmpeg: %s\nFFprobe: %s\n' \
    "$meetme_source" "$meetme_install_root" "$meetme_host_dir" "$meetme_id" "$meetme_ffmpeg" "$meetme_ffprobe"
  exit 0
fi
if [ "$meetme_skip_build" = 0 ]; then
  swift build --package-path "$meetme_repo/helper" --configuration "$meetme_configuration" --product MeetMeHelper
fi
[ -x "$meetme_source" ] || fail "Build did not produce $meetme_source"
umask 077
mkdir -p "$meetme_install_root/bin" "$meetme_host_dir"
meetme_temporary="$(mktemp "$meetme_install_root/bin/.MeetMeHelper.XXXXXX")"
trap 'rm -f "$meetme_temporary"' EXIT
cp "$meetme_source" "$meetme_temporary"
chmod 700 "$meetme_temporary"
codesign --force --sign - "$meetme_temporary"
mv -f "$meetme_temporary" "$meetme_install_root/bin/MeetMeHelper"
# SwiftPM dependencies may bundle resources alongside the product.
for meetme_bundle in "$meetme_repo/helper/.build/$meetme_configuration/"*.bundle; do
  [ -d "$meetme_bundle" ] || continue
  ditto "$meetme_bundle" "$meetme_install_root/bin/$(basename "$meetme_bundle")"
done
python3 - "$meetme_install_root" "$meetme_host_dir" "$meetme_id" "$meetme_ffmpeg" "$meetme_ffprobe" <<'PY'
import json
import os
from pathlib import Path
import shlex
import sys

root, host_dir, extension_id, ffmpeg, ffprobe = sys.argv[1:]
root = Path(root)
launcher = root / 'bin' / 'meetme-launcher'
launcher_text = '\n'.join([
    '#!/bin/bash',
    'set -euo pipefail',
    'export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"',
    'export MEETME_FFMPEG=' + shlex.quote(ffmpeg),
    'export MEETME_FFPROBE=' + shlex.quote(ffprobe),
    'exec ' + shlex.quote(str(root / 'bin' / 'MeetMeHelper')) + ' "$@"',
    '',
])
launcher_tmp = launcher.with_suffix('.tmp')
launcher_tmp.write_text(launcher_text)
launcher_tmp.chmod(0o700)
os.replace(launcher_tmp, launcher)
manifest = {
    'name': 'com.meetme.helper',
    'description': 'MeetMe local recording storage and on-device transcription',
    'path': str(launcher),
    'type': 'stdio',
    'allowed_origins': [f'chrome-extension://{extension_id}/'],
}
manifest_path = Path(host_dir) / 'com.meetme.helper.json'
temporary = manifest_path.with_suffix('.json.tmp')
temporary.write_text(json.dumps(manifest, indent=2) + '\n')
temporary.chmod(0o600)
os.replace(temporary, manifest_path)
print(f'Registered MeetMe for {extension_id}.')
print(f'Manifest: {manifest_path}')
print('Reload the MeetMe extension, then open its Settings page to finish setup.')
PY
