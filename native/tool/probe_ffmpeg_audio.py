"""Run production encoder arguments with UDP PCM, using only a synthetic screen."""
import argparse
import array
import json
import math
from pathlib import Path
import re
import socket
import struct
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--ffmpeg', default='build/windows/x64/runner/Release/ffmpeg/bin/ffmpeg.exe')
parser.add_argument('--fixtures', default='build/encoder-fixtures/commands.json')
opts = parser.parse_args()
exe = str(Path(opts.ffmpeg).resolve())
commands = json.loads(Path(opts.fixtures).read_text())

def run(args):
    result = subprocess.run([exe, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
    if result.returncode:
        raise RuntimeError(result.stderr.decode('utf-8', errors='replace')[-6000:])
    return result

def pcm_feeder(port, stop):
    samples = []
    for i in range(480):
        value = int(4000 * math.sin(2 * math.pi * 1000 * i / 48000))
        samples.extend((value, value))
    packet = struct.pack('<' + 'h' * len(samples), *samples)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
        deadline = time.monotonic()
        while not stop.is_set():
            try:
                sender.sendto(packet, ('127.0.0.1', port))
            except OSError:
                pass  # The PCM input has not bound its local port yet.
            deadline += .01
            stop.wait(max(0, deadline - time.monotonic()))

try:
    with tempfile.TemporaryDirectory(prefix='abordage-audio-') as temp:
        for mode in ('silent', 'audio'):
            args = list(commands[mode])
            # Only the desktop device is replaced. All audio, mapping, encoder
            # and MPEG-TS options are the actual Dart-generated production tail.
            first_input = args.index('-i')
            args = ['-hide_banner', '-loglevel', 'warning', '-nostdin',
                    '-re', '-readrate_initial_burst', '0.001', '-f', 'lavfi', '-i',
                    'testsrc2=size=1920x1080:rate=120,format=nv12',
                    *args[first_input + 2:]]
            stop = threading.Event()
            feeder = None
            if mode == 'audio':
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
                    reservation.bind(('127.0.0.1', 0))
                    port = reservation.getsockname()[1]
                audio_url = args.index('-i') + 2
                audio_url = args.index('-i', audio_url) + 1
                args[audio_url] = args[audio_url].replace('127.0.0.1:44001', f'127.0.0.1:{port}')
                feeder = threading.Thread(target=pcm_feeder, args=(port, stop), daemon=True)
                feeder.start()
            recording = str(Path(temp) / (mode + '.ts'))
            args = [*args[:-1], '-t', '0.4', '-frames:v', '48', recording]
            try:
                encoded = run(args)
            finally:
                stop.set()
                if feeder:
                    feeder.join(timeout=2)
            if not re.search(rb'frame=\s*[1-9]\d*', encoded.stdout):
                raise RuntimeError(f'{mode}: encoder produced no frame')
            maps = ['-map', '0:v:0'] + (['-map', '0:a:0'] if mode == 'audio' else [])
            run(['-hide_banner', '-loglevel', 'error', '-i', recording, *maps, '-f', 'null', '-'])
            if mode == 'audio':
                decoded = run(['-hide_banner', '-loglevel', 'error', '-i', recording,
                               '-map', '0:a:0', '-vn', '-ac', '2', '-ar', '48000', '-f', 's16le', 'pipe:1'])
                samples = array.array('h')
                samples.frombytes(decoded.stdout)
                if len(samples) < 960 or max(abs(v) for v in samples) < 128:
                    raise RuntimeError('AAC decoded without audible PCM samples')
                print(f'::notice::PASS production command with UDP PCM: H264 + AAC decoded, {len(samples)} audio samples.')
            else:
                print('::notice::PASS production command without sound: H264 decoded.')
except Exception as error:
    message = str(error).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    print('::error::Abordage production audio command failed: ' + message)
    raise SystemExit(1)
