"""Production UDP transport -> bundled libmpv, with late join, loss and AAC.

Headless software decoding deliberately checks delivery/demux/decoding, not a
physical GPU, Flutter textures or achievable 1080p/120 rendering performance.
"""
import argparse
import ctypes as C
import json
import math
from pathlib import Path
import socket
import struct
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--ffmpeg', default='build/windows/x64/runner/Release/ffmpeg/bin/ffmpeg.exe')
parser.add_argument('--mpv', default='build/windows/x64/runner/Release/libmpv-2.dll')
parser.add_argument('--fixtures', default='build/encoder-fixtures')
parser.add_argument('--transport-exe', required=True)
opts = parser.parse_args()
fixtures = Path(opts.fixtures)
player = json.loads((fixtures / 'player.json').read_text())
command = json.loads((fixtures / 'commands.json').read_text())['audio']
logs, reports, encoded = [], {}, {}
encoder = transport = None
handle = None
stop = threading.Event()

def reserve_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def pcm(port):
    samples = [int(4000 * math.sin(2 * math.pi * 1000 * i / 48000))
               for i in range(480) for _ in range(2)]
    data = struct.pack('<' + 'h' * len(samples), *samples)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        deadline = time.monotonic()
        while not stop.is_set():
            sock.sendto(data, ('127.0.0.1', port))
            deadline += .01
            stop.wait(max(0, deadline - time.monotonic()))

def remember(line):
    logs.append(line.rstrip())
    del logs[:-25]

def stderr_reader(stream):
    for line in stream:
        remember(line)

try:
    # Load the actual DLL from the portable application, not system ffmpeg.
    library_path = str(Path(opts.mpv).resolve())
    mpv = C.CDLL(library_path)
    mpv.mpv_create.restype = C.c_void_p
    mpv.mpv_initialize.argtypes = [C.c_void_p]
    mpv.mpv_set_option_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    mpv.mpv_command.argtypes = [C.c_void_p, C.POINTER(C.c_char_p)]
    mpv.mpv_get_property_string.argtypes = [C.c_void_p, C.c_char_p]
    mpv.mpv_get_property_string.restype = C.c_void_p
    mpv.mpv_free.argtypes = [C.c_void_p]
    mpv.mpv_terminate_destroy.argtypes = [C.c_void_p]
    handle = mpv.mpv_create()
    if not handle:
        raise RuntimeError('mpv_create failed')
    for key, value in {**player['options'], 'vo': 'null', 'ao': 'null',
                       'hwdec': 'no', 'idle': 'yes', 'pause': 'no'}.items():
        if mpv.mpv_set_option_string(handle, key.encode(), value.encode()) < 0:
            raise RuntimeError(f'Player option rejected: {key}={value}')
    if mpv.mpv_initialize(handle) < 0:
        raise RuntimeError('mpv_initialize failed')

    def prop(name):
        ptr = mpv.mpv_get_property_string(handle, name.encode())
        if not ptr:
            return ''
        try:
            return C.string_at(ptr).decode('utf-8', errors='replace')
        finally:
            mpv.mpv_free(ptr)

    output_port, audio_port = reserve_port(), reserve_port()
    transport = subprocess.Popen([
        str(Path(opts.transport_exe).resolve()), str(output_port),
    ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding='utf-8', errors='replace')
    threading.Thread(target=stderr_reader, args=(transport.stderr,), daemon=True).start()
    input_port = []
    ready = threading.Event()

    def transport_reader():
        for line in transport.stdout:
            try:
                data = json.loads(line)
            except ValueError:
                remember(line)
                continue
            if 'inputPort' in data:
                input_port.append(data['inputPort'])
                ready.set()
            if 'role' in data:
                reports[data['role']] = data

    threading.Thread(target=transport_reader, daemon=True).start()
    if not ready.wait(15):
        raise RuntimeError('Transport startup failed: ' + '\n'.join(logs))

    url = player['url'].replace('127.0.0.1:44002', f'127.0.0.1:{output_port}')
    args = (C.c_char_p * 3)(b'loadfile', url.encode(), None)
    if mpv.mpv_command(handle, args) < 0:
        raise RuntimeError('libmpv rejected the production playback URL')

    # Same production mapping/codecs/PCM/MPEG-TS; only replace screen and ports.
    first = command.index('-i')
    args = ['-hide_banner', '-loglevel', 'warning', '-nostdin', '-re',
            '-readrate_initial_burst', '0.001', '-f', 'lavfi', '-i',
            'testsrc2=size=640x360:rate=240,format=nv12', *command[first + 2:]]
    args = [a.replace('127.0.0.1:44001', f'127.0.0.1:{audio_port}')
            .replace('127.0.0.1:44000', f'127.0.0.1:{input_port[0]}') for a in args]
    threading.Thread(target=pcm, args=(audio_port,), daemon=True).start()
    encoder = subprocess.Popen([str(Path(opts.ffmpeg).resolve()), *args],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding='utf-8', errors='replace')
    threading.Thread(target=stderr_reader, args=(encoder.stderr,), daemon=True).start()
    def encoder_progress():
        for line in encoder.stdout:
            key, _, value = line.strip().partition('=')
            if key in ('frame', 'fps', 'out_time_us'):
                encoded[key] = value

    threading.Thread(target=encoder_progress, daemon=True).start()

    pts = []
    started = time.monotonic()
    first_frame = None
    # Check the application's first-frame deadline and then survive 12 real
    # seconds of playback. Media time need not equal wall time on a headless
    # software decoder; actual throughput has a separate high-FPS regression.
    deadline = started + 30
    while time.monotonic() < deadline:
        if encoder.poll() is not None or transport.poll() is not None:
            raise RuntimeError('Encoder or transport stopped: ' + '\n'.join(logs))
        value = prop('time-pos')
        if value:
            try:
                pts.append(float(value))
            except ValueError:
                pass
        if first_frame is None and prop('vo-configured') == 'yes':
            first_frame = time.monotonic()
        if (first_frame is not None and time.monotonic() - first_frame > 12
                and len(pts) > 1 and max(pts) - min(pts) > 2):
            break
        time.sleep(.05)
    result = {name: prop(name) for name in [
        'video-dec-params/w', 'video-dec-params/h', 'video-codec',
        'audio-params/samplerate', 'audio-codec-name', 'video-pts',
        'time-pos', 'pause', 'idle-active', 'eof-reached', 'video-out-params',
        'vo-configured', 'decoder-frame-drop-count',
    ]}
    result['advancedSeconds'] = max(pts) - min(pts) if pts else 0
    result['firstFrameWallSeconds'] = first_frame - started if first_frame else None
    result['playbackWallSeconds'] = time.monotonic() - first_frame if first_frame else 0
    result['encoder'] = encoded
    result['transport'] = reports
    print(json.dumps(result, indent=2))
    receiver = reports.get('receiver', {})
    if (result['advancedSeconds'] < 2 or result['firstFrameWallSeconds'] is None
            or result['firstFrameWallSeconds'] >= 12 or result['playbackWallSeconds'] < 12
            or result['video-dec-params/w'] != '640'
            or result['vo-configured'] != 'yes' or not result['video-out-params']
            or result['audio-params/samplerate'] != '48000'
            or receiver.get('bytes', 0) < 1000000
            or receiver.get('authFailures', 0) != 0
            or receiver.get('playbackDrops', 0) != 0
            or receiver.get('waitingKeyframe', True)):
        raise RuntimeError('libmpv received no advancing decoded H264/AAC: '
                           + json.dumps(result) + '\n' + '\n'.join(logs))
    print('::notice::PASS real Abordage sender -> UDP relay with loss -> late join -> bundled libmpv H264/AAC playback for 12s at 640x360/240 source FPS '
          f'(headless software decode; first frame={result["firstFrameWallSeconds"]:.2f}s; '
          f'encoder FPS={encoded.get("fps", "unknown")}; network retries={reports.get("sender", {}).get("sendBlocked", 0)}, '
          f'local retries={receiver.get("playbackBlocked", 0)}, local drops={receiver.get("playbackDrops", 0)}).')
except Exception as error:
    print('::error::Abordage libmpv playback failed: ' + str(error).replace('%', '%25').replace('\n', '%0A'))
    raise SystemExit(1)
finally:
    stop.set()
    if encoder:
        encoder.kill()
        encoder.wait(timeout=5)
    if transport:
        try:
            transport.stdin.write('stop\n')
            transport.stdin.flush()
            transport.wait(timeout=5)
        except BrokenPipeError:
            transport.wait(timeout=5)
        except subprocess.TimeoutExpired:
            transport.kill()
            transport.wait(timeout=5)
    if handle:
        mpv.mpv_terminate_destroy(handle)
