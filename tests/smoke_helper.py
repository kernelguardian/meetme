#!/usr/bin/env python3
"""Exercise the real native/HTTP helper with synthetic media and an isolated library.

No microphone, meeting content, personal configuration or Apple speech-asset download is used.
Usage: python3 tests/smoke_helper.py [helper/.build/debug/MeetMeHelper]
"""
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'chrome-extension://' + 'a' * 32 + '/'


class Host:
    def __init__(self, binary, env, log):
        self.process = subprocess.Popen([str(binary), ORIGIN], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=log, env=env)
        self.number = 0

    def read(self, count, timeout=45):
        result = bytearray()
        deadline = time.monotonic() + timeout
        while len(result) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise TimeoutError('Native helper response timed out')
            block = os.read(self.process.stdout.fileno(), count - len(result))
            if not block:
                raise RuntimeError(f'Native helper closed stdout (exit={self.process.poll()})')
            result.extend(block)
        return result

    def request(self, command, expect_ok=True, **params):
        self.number += 1
        identifier = str(self.number)
        body = json.dumps(dict(id=identifier, command=command, **params)).encode()
        self.process.stdin.write(struct.pack('<I', len(body)) + body)
        self.process.stdin.flush()
        while True:
            length, = struct.unpack('<I', self.read(4))
            assert 0 < length <= 1024 * 1024, f'Invalid native frame length: {length}'
            response = json.loads(self.read(length))
            if response.get('id') == identifier:
                break
        assert bool(response.get('ok')) == expect_ok, response
        return response.get('result') if expect_ok else response

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError('Helper did not exit after stdin EOF')


def http(url, method='GET', data=None, headers=None):
    request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        response = urllib.request.urlopen(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, dict(response.headers), response.read()


def main():
    binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'helper/.build/debug/MeetMeHelper'
    assert binary.is_file(), f'Build the helper first: {binary}'
    ffmpeg = shutil.which('ffmpeg')
    assert ffmpeg, 'FFmpeg is required'
    completed = []
    host = None
    with tempfile.TemporaryDirectory(prefix='meetme-smoke-') as temporary:
        temporary = Path(temporary)
        fixture = temporary / 'fixture.webm'
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                        'color=c=navy:s=320x180:r=10', '-f', 'lavfi', '-i',
                        'sine=frequency=440:sample_rate=48000', '-t', '2', '-c:v', 'libvpx',
                        '-c:a', 'libopus', '-shortest', str(fixture)], check=True)
        media = fixture.read_bytes()
        env = {**os.environ, 'MEETME_CONFIG_DIR': str(temporary / 'config'),
               'MEETME_LIBRARY_DIR': str(temporary / 'library'), 'MEETME_FFMPEG': ffmpeg,
               'MEETME_FFPROBE': shutil.which('ffprobe') or ''}
        log_path = temporary / 'helper.log'
        with log_path.open('wb') as log:
            try:
                host = Host(binary, env, log)
                hello = host.request('hello')
                base, token = hello['baseURL'], hello['token']
                assert urllib.parse.urlparse(base).hostname == '127.0.0.1'
                assert hello['model'] == 'en-US'
                settings = host.request('settings')
                assert settings['model'] == 'en-US'
                assert settings['engine'] == 'apple'
                engines = {engine['id']: engine for engine in settings['engines']}
                assert set(engines) == {'apple', 'whisper'}
                apple = engines['apple']['languages']
                assert any(language['id'] == 'en-US' for language in apple)
                assert all('_' not in language['id'] for language in apple)
                assert engines['apple']['supportsAutoDetect'] is False
                # Whisper exists to reach the languages Apple ships no assets for.
                whisper = {language['id'] for language in engines['whisper']['languages']}
                assert {'hi', 'ml'} <= whisper
                assert engines['whisper']['supportsAutoDetect'] is True
                assert any(variant['id'].startswith('openai_whisper-') for variant in settings['whisperVariants'])
                invalid_language = host.request('settings', expect_ok=False, model='not-a-supported-locale')
                assert 'transcription' in invalid_language['error'].lower()
                # Apple cannot do Malayalam or auto-detect; both must be refused up front.
                assert not host.request('settings', expect_ok=False, engine='apple', model='ml')['ok']
                assert not host.request('settings', expect_ok=False, engine='apple', model='auto')['ok']
                assert host.request('hello')['model'] == 'en-US'
                whisper_saved = host.request('settings', engine='whisper', model='auto')
                assert whisper_saved['engine'] == 'whisper' and whisper_saved['model'] == 'auto'
                restored = host.request('settings', engine='apple', model='en-US')
                assert restored['engine'] == 'apple' and restored['model'] == 'en-US'
                completed.append('engine catalogue exposes Whisper languages Apple lacks, and rejects unsupported engine/language pairs without downloading models')
                recording = host.request('create', title='Synthetic smoke test', platform='test', micEnabled=False)
                identifier = recording['id']
                chunks = [media[i:i + 4096] for i in range(0, len(media), 4096)]

                def upload(seq, data, auth=token, checksum=None):
                    return http(f'{base}/recordings/{identifier}/chunks/{seq}', 'POST', data, {
                        'Authorization': 'Bearer ' + auth,
                        'X-Content-SHA256': checksum or hashlib.sha256(data).hexdigest(),
                        'X-Chunk-Length': str(len(data)), 'Content-Type': 'application/octet-stream',
                        'Origin': ORIGIN.rstrip('/'),
                    })

                assert upload(0, chunks[0], auth='invalid')[0] in (401, 403)
                assert upload(0, chunks[0], checksum='0' * 64)[0] >= 400
                assert upload(1, chunks[0])[0] >= 400
                assert upload(0, chunks[0])[0] == 200
                assert upload(0, chunks[0])[0] == 200
                assert upload(0, b'conflicting duplicate')[0] >= 400
                for seq, data in enumerate(chunks[1:], 1):
                    assert upload(seq, data)[0] == 200
                completed.append('authenticated, ordered uploads; checksums; duplicate-safe retries')

                host.request('finalize', expect_ok=False, recordingId=identifier,
                             chunkCount=len(chunks) + 1, totalBytes=len(media))
                finalized = host.request('finalize', recordingId=identifier,
                                         chunkCount=len(chunks), totalBytes=len(media))
                assert finalized['status'] == 'ready', finalized
                assert 1.5 <= finalized['duration'] <= 3.0, finalized
                host.request('finalize', recordingId=identifier,
                             chunkCount=len(chunks), totalBytes=len(media))
                completed.append('final chunk count validation, FFmpeg remux, duration and idempotent finalize')

                playback = host.request('playback', recordingId=identifier)
                url = playback['url']
                code, headers, full = http(url)
                assert code == 200 and full, (code, headers)
                code, headers, partial = http(url, headers={'Range': 'bytes=10-99'})
                assert code == 206 and partial == full[10:100], (code, headers)
                assert headers.get('Content-Range', headers.get('content-range')) == f'bytes 10-99/{len(full)}'
                code, _, suffix = http(url, headers={'Range': 'bytes=-32'})
                assert code == 206 and suffix == full[-32:]
                assert http(url, headers={'Range': f'bytes={len(full) + 1}-'})[0] == 416
                parsed = urllib.parse.urlsplit(url)
                assert http(urllib.parse.urlunsplit(parsed._replace(query='')))[0] in (401, 403)
                assert http(url, headers={'Host': 'untrusted.example'})[0] >= 400
                completed.append('full playback, exact byte ranges, suffix/unsatisfiable ranges, URL and Host authentication')

                interrupted = host.request('create', title='Interrupted test', platform='test', micEnabled=False)
                identifier = interrupted['id']
                for seq, data in enumerate(chunks):
                    assert upload(seq, data)[0] == 200
                host.close()
                host = Host(binary, env, log)
                restarted = host.request('hello')
                assert restarted['token'] != token, 'Token did not rotate on restart'
                recovered = host.request('recover', recordingId=identifier)
                assert recovered['status'] == 'ready', recovered
                completed.append('stdin EOF exit, credential rotation and committed-media recovery after restart')
                host.close()
                host = None
            except BaseException:
                if host and host.process.poll() is None:
                    host.process.kill()
                    host.process.wait()
                log.flush()
                print(log_path.read_text(errors='replace')[-12000:], file=sys.stderr)
                raise
    for item in completed:
        print('PASS ' + item)
    print(f'PASS {len(completed)} integration groups; all data isolated and removed')


if __name__ == '__main__':
    main()
