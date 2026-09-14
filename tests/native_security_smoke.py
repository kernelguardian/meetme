#!/usr/bin/env python3
"""Targeted native-helper boundary checks; no real media, microphone, or model work."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'chrome-extension://' + 'a' * 32 + '/'


def frame(process, payload):
    data = json.dumps(payload).encode()
    process.stdin.write(struct.pack('<I', len(data)) + data)
    process.stdin.flush()
    size = struct.unpack('<I', process.stdout.read(4))[0]
    return json.loads(process.stdout.read(size))


def main():
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'helper/.build/debug/MeetMeHelper'
    ffmpeg = shutil.which('ffmpeg')
    assert binary.is_file() and ffmpeg
    with tempfile.TemporaryDirectory(prefix='meetme-security-') as temp:
        root = Path(temp).resolve()
        outside = root / 'outside'
        outside.mkdir()
        env = {**os.environ, 'CFFIXED_USER_HOME': str(root), 'MEETME_CONFIG_DIR': str(root / 'config'), 'MEETME_LIBRARY_DIR': str(root / 'library'), 'MEETME_FFMPEG': ffmpeg, 'MEETME_FFPROBE': shutil.which('ffprobe') or ''}
        process = subprocess.Popen([str(binary), ORIGIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        hello = frame(process, {'id': '1', 'command': 'hello'})['result']
        created = frame(process, {'id': '2', 'command': 'create', 'title': 'Boundary', 'platform': 'test', 'micEnabled': False})['result']
        recording_dir = next((root / 'library').iterdir())
        chunks = recording_dir / 'work' / 'chunks'
        chunks.rmdir()
        chunks.symlink_to(outside, target_is_directory=True)
        data = b'not media'
        request = urllib.request.Request(f"{hello['baseURL']}/recordings/{created['id']}/chunks/0", data=data, method='POST', headers={'Authorization': 'Bearer ' + hello['token'], 'Origin': ORIGIN.rstrip('/'), 'X-Content-SHA256': hashlib.sha256(data).hexdigest(), 'X-Chunk-Length': str(len(data)), 'Content-Type': 'application/octet-stream'})
        try:
            urllib.request.urlopen(request, timeout=10)
            raise AssertionError('symlinked work directory was accepted')
        except urllib.error.HTTPError as error:
            assert error.code == 409, error.code
        assert not (outside / '0.bin').exists(), 'chunk escaped the recording work directory'
        process.stdin.close(); process.wait(timeout=10)

        malformed = subprocess.Popen([str(binary), ORIGIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        malformed.stdin.write(struct.pack('<I', 256 * 1024 + 1)); malformed.stdin.flush(); malformed.stdin.close()
        malformed.wait(timeout=10)
        assert malformed.returncode == 0
    print('PASS canonical temp-home library; rejects work-directory symlink escapes and oversized native frames')


if __name__ == '__main__':
    main()
