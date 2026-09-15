#!/bin/bash
# Install MeetMe: builds and registers the native helper, and prepares the browser
# extension for loading. No daemon, no administrator access.
#
# The extension's ID is derived from the public key pinned in extension/manifest.json,
# so it is known before the extension is ever loaded. That is what lets one command
# register the native host and set up the extension together.
set -euo pipefail

meetme_repo="$(cd "$(dirname "$0")/.." && pwd)"
meetme_id=""
meetme_configuration="release"
meetme_skip_build=0
meetme_dry_run=0
meetme_uninstall=0
meetme_open=1
meetme_install_root="$HOME/Library/Application Support/MeetMe"
meetme_host_dir=""
meetme_ffmpeg="${MEETME_FFMPEG:-}"
meetme_ffprobe="${MEETME_FFPROBE:-}"
meetme_extension_dir="$meetme_repo/extension"

meetme_brave_hosts="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
meetme_chrome_hosts="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"

usage() {
  cat <<'USAGE'
Usage: install/install.sh [options]

Installs both halves of MeetMe. Run it with no options for a normal install.

Options:
  --extension-id ID       Override the ID derived from extension/manifest.json
  --configuration MODE    release (default) or debug
  --skip-build            Install an existing build
  --ffmpeg PATH           Absolute path to ffmpeg
  --ffprobe PATH          Absolute path to ffprobe
  --host-dir PATH         Register in one directory instead of Brave's and Chrome's
  --install-root PATH     Override helper installation directory
  --no-open               Do not open brave://extensions at the end
  --dry-run               Check prerequisites and print destinations; change nothing
  --uninstall             Remove the helper and its registrations
  -h, --help              Show this help

Recordings live in the folder chosen inside MeetMe and are never touched by this script.
USAGE
}
say() { printf 'MeetMe: %s\n' "$*"; }
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
    --uninstall) meetme_uninstall=1; shift ;;
    --no-open) meetme_open=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = Darwin ] || fail "MeetMe requires macOS."
command -v python3 >/dev/null || fail "Python 3 is required."

if [ -n "$meetme_host_dir" ]; then
  meetme_host_dirs=("$meetme_host_dir")
else
  meetme_host_dirs=("$meetme_brave_hosts" "$meetme_chrome_hosts")
fi
for meetme_destination in "$meetme_install_root" "${meetme_host_dirs[@]}"; do
  case "$meetme_destination" in /*) ;; *) fail "Destination paths must be absolute." ;; esac
done

if [ "$meetme_uninstall" = 1 ]; then
  for meetme_dir in "${meetme_host_dirs[@]}"; do
    rm -f "$meetme_dir/com.meetme.helper.json" && say "Removed registration in $meetme_dir"
  done
  rm -rf "$meetme_install_root/bin"
  say "Removed the helper from $meetme_install_root/bin"
  say "Remove the extension yourself in brave://extensions. Recordings were not touched."
  exit 0
fi

# Pin the extension's identity. A manifest without a key would take an ID derived from
# whatever folder it happens to be loaded from, which no installer can predict.
meetme_id_from_manifest="$(python3 - "$meetme_extension_dir/manifest.json" <<'PY'
import base64, hashlib, json, pathlib, subprocess, sys, collections, tempfile, os

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(), object_pairs_hook=collections.OrderedDict)
key = data.get('key')

if not key:
    with tempfile.TemporaryDirectory() as work:
        pem, der = os.path.join(work, 'k.pem'), os.path.join(work, 'k.der')
        subprocess.run(['openssl', 'genrsa', '-out', pem, '2048'], check=True, capture_output=True)
        subprocess.run(['openssl', 'rsa', '-in', pem, '-pubout', '-outform', 'DER', '-out', der],
                       check=True, capture_output=True)
        key = base64.b64encode(pathlib.Path(der).read_bytes()).decode()
    out = collections.OrderedDict()
    for name, value in data.items():
        out[name] = value
        if name == 'description':
            out['key'] = key
    if 'key' not in out:
        out['key'] = key
    path.write_text(json.dumps(out, indent=2) + '\n')
    print('generated', file=sys.stderr)

der = base64.b64decode(key)
print(''.join(chr(ord('a') + int(c, 16)) for c in hashlib.sha256(der).hexdigest()[:32]))
PY
)" || fail "Could not read the extension ID from extension/manifest.json"

if [ -z "$meetme_id" ]; then
  meetme_id="$meetme_id_from_manifest"
elif [ "$meetme_id" != "$meetme_id_from_manifest" ]; then
  say "Note: using --extension-id $meetme_id, not the manifest's $meetme_id_from_manifest."
fi
[[ "$meetme_id" =~ ^[a-p]{32}$ ]] || fail "Invalid extension ID: $meetme_id"

command -v swift >/dev/null || fail "Install compatible Xcode Command Line Tools first."
command -v codesign >/dev/null || fail "macOS codesign is required."
if [ -z "$meetme_ffmpeg" ]; then meetme_ffmpeg="$(command -v ffmpeg || true)"; fi
if [ -z "$meetme_ffprobe" ]; then meetme_ffprobe="$(command -v ffprobe || true)"; fi
for meetme_executable in "$meetme_ffmpeg" "$meetme_ffprobe"; do
  case "$meetme_executable" in /*) ;; *) fail "Install FFmpeg (including ffprobe), or pass both absolute paths." ;; esac
  [ -x "$meetme_executable" ] || fail "Executable not found: $meetme_executable"
done
case "$meetme_configuration" in debug|release) ;; *) fail "Configuration must be debug or release." ;; esac
meetme_source="$meetme_repo/helper/.build/$meetme_configuration/MeetMeHelper"
if [ "$meetme_skip_build" = 1 ]; then
  [ -x "$meetme_source" ] || fail "Build missing: $meetme_source"
fi

if [ "$meetme_dry_run" = 1 ]; then
  printf 'Extension: %s\nExtension ID: %s\nBuild: %s\nHelper: %s/bin/MeetMeHelper\nFFmpeg: %s\nFFprobe: %s\n' \
    "$meetme_extension_dir" "$meetme_id" "$meetme_source" "$meetme_install_root" "$meetme_ffmpeg" "$meetme_ffprobe"
  for meetme_dir in "${meetme_host_dirs[@]}"; do printf 'Manifest: %s/com.meetme.helper.json\n' "$meetme_dir"; done
  exit 0
fi

if [ "$meetme_skip_build" = 0 ]; then
  say "Building the helper (this takes a few minutes the first time)…"
  swift build --package-path "$meetme_repo/helper" --configuration "$meetme_configuration" --product MeetMeHelper
fi
[ -x "$meetme_source" ] || fail "Build did not produce $meetme_source"

umask 077
mkdir -p "$meetme_install_root/bin"
meetme_temporary="$(mktemp "$meetme_install_root/bin/.MeetMeHelper.XXXXXX")"
trap 'rm -f "$meetme_temporary"' EXIT
cp "$meetme_source" "$meetme_temporary"
chmod 700 "$meetme_temporary"
codesign --force --sign - "$meetme_temporary"
mv -f "$meetme_temporary" "$meetme_install_root/bin/MeetMeHelper"
# SwiftPM dependencies may bundle resources alongside the product; WhisperKit does.
for meetme_bundle in "$meetme_repo/helper/.build/$meetme_configuration/"*.bundle; do
  [ -d "$meetme_bundle" ] || continue
  rm -rf "$meetme_install_root/bin/$(basename "$meetme_bundle")"
  ditto "$meetme_bundle" "$meetme_install_root/bin/$(basename "$meetme_bundle")"
done

for meetme_dir in "${meetme_host_dirs[@]}"; do mkdir -p "$meetme_dir"; done
python3 - "$meetme_install_root" "$meetme_id" "$meetme_ffmpeg" "$meetme_ffprobe" "${meetme_host_dirs[@]}" <<'PY'
import json, os, shlex, sys
from pathlib import Path

root, extension_id, ffmpeg, ffprobe, *host_dirs = sys.argv[1:]
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
for host_dir in host_dirs:
    manifest_path = Path(host_dir) / 'com.meetme.helper.json'
    temporary = manifest_path.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(manifest, indent=2) + '\n')
    temporary.chmod(0o600)
    os.replace(temporary, manifest_path)
    print(f'MeetMe: registered in {host_dir}')
PY

# Chromium records installed extensions per profile; use that to tell the user whether
# the one remaining manual step is still outstanding.
meetme_already_loaded=0
if [ -d "$HOME/Library/Application Support/BraveSoftware/Brave-Browser" ]; then
  while IFS= read -r meetme_prefs; do
    if grep -q "$meetme_id" "$meetme_prefs" 2>/dev/null; then meetme_already_loaded=1; break; fi
  done < <(find "$HOME/Library/Application Support/BraveSoftware/Brave-Browser" -maxdepth 2 \
             \( -name Preferences -o -name 'Secure Preferences' \) 2>/dev/null)
fi

say "Helper installed at $meetme_install_root/bin/MeetMeHelper"
say "Extension ID: $meetme_id"
if [ "$meetme_already_loaded" = 1 ]; then
  say "The extension is already loaded. Reload it in brave://extensions to pick up this build."
else
  cat <<EOF

MeetMe: one step left, which only a person can do — Brave does not allow a script
to install an extension.

  1. Open  brave://extensions
  2. Turn on  Developer mode
  3. Choose  Load unpacked  and select:
     $meetme_extension_dir

The native helper is already registered for this extension, so nothing else is needed.
EOF
  if [ "$meetme_open" = 1 ] && [ -d "/Applications/Brave Browser.app" ]; then
    open -a "Brave Browser" "brave://extensions" >/dev/null 2>&1 || true
  fi
fi
say "Then open MeetMe's Settings to choose a recordings folder and a transcription engine."
