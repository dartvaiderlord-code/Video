"""Regression for a nominal 480 FPS desktop delivering 120 real frames/sec."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--ffmpeg', default='build/windows/x64/runner/Release/ffmpeg/bin/ffmpeg.exe')
parser.add_argument('--fixture', default='build/encoder-fixtures/oversampled.json')
opts = parser.parse_args()
exe = str(Path(opts.ffmpeg).resolve())
production = json.loads(Path(opts.fixture).read_text())

def run(args):
    result = subprocess.run([exe, *args], capture_output=True, timeout=40)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace')[-4000:])
    return result

try:
    with tempfile.TemporaryDirectory(prefix='pirate-vfr-') as temporary:
        rates = {}
        # select preserves the 480 FPS input time base, but forwards every 4th
        # frame: the same timing mismatch as an overloaded desktop capture.
        graph = 'testsrc2=size=320x180:rate=480,noise=alls=100:allf=t,select=not(mod(n\\,4))'
        for old in (True, False):
            args = list(production)
            first = args.index('-i')
            args = ['-hide_banner', '-loglevel', 'error', '-nostdin', '-f', 'lavfi', '-i', graph,
                    *args[first + 2:]]
            if old:
                args[args.index('-x264-params') + 1] = 'nal-hrd=cbr:force-cfr=1'
            output = str(Path(temporary) / ('old.ts' if old else 'fixed.ts'))
            args = [*args[:-1], '-threads', '2', '-frames:v', '360', output]
            run(args)
            # Remux the actual video elementary stream, excluding TS overhead.
            raw = run(['-hide_banner', '-loglevel', 'error', '-i', output,
                       '-map', '0:v:0', '-c:v', 'copy', '-f', 'h264', 'pipe:1']).stdout
            decoded = run(['-hide_banner', '-loglevel', 'error', '-i', output,
                           '-an', '-progress', 'pipe:1', '-fps_mode', 'passthrough', '-f', 'null', '-']).stdout
            frames = re.findall(rb'frame=(\d+)', decoded)
            if not frames or int(frames[-1]) != 360:
                raise RuntimeError('Variable-FPS stream lost decoded frames')
            # 360 frames at real 120 FPS = three seconds of wall-timestamp video.
            rates['old' if old else 'fixed'] = len(raw) * 8 / 3 / 1000000
        if not (rates['fixed'] > rates['old'] * 2.5 and 20 <= rates['fixed'] <= 30):
            raise RuntimeError('480->120 FPS budget regression: ' + json.dumps(rates))
        print(f'::notice::PASS VFR quality budget: nominal 480/real 120 FPS; old {rates["old"]:.2f} Mbps, fixed {rates["fixed"]:.2f} Mbps for 25 Mbps target; all 360 frames decode.')
except Exception as error:
    print('::error::' + str(error).replace('%', '%25').replace('\n', '%0A'))
    raise SystemExit(1)
