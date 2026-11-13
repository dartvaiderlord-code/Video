"""Check compatible conversion even without a desktop; optionally capture DXGI."""
from pathlib import Path
import re
import subprocess
import sys

exe = Path('build/windows/x64/runner/Release/ffmpeg/bin/ffmpeg.exe').resolve()

def capture(graph):
    return subprocess.run([
        str(exe), '-hide_banner', '-loglevel', 'info', '-f', 'lavfi', '-i', graph,
        '-frames:v', '1', '-an', '-c:v', 'libx264', '-preset', 'ultrafast',
        '-tune', 'zerolatency', '-progress', 'pipe:1', '-f', 'null', '-',
    ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        encoding='utf-8', errors='replace', timeout=20)

def has_frame(result):
    return result.returncode == 0 and re.search(r'frame=\s*[1-9]\d*', result.stdout)

def fail(message, result):
    details = (message + ': ' + result.stdout[-4000:]).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    print('::error::' + details)
    sys.exit(1)

conversion = 'scale=1920:1080:flags=fast_bilinear,format=nv12'
# Mandatory test: no physical GPU or active monitor is needed for this part.
synthetic = capture('testsrc2=size=640x360:rate=120,format=bgra,' + conversion)
if not has_frame(synthetic):
    fail('Compatible BGRA/NV12 processing failed', synthetic)
print('::notice::PASS Abordage compatible NV12 conversion and H264 encoding (one frame; no FPS claim).')
try:
    baseline = capture('ddagrab=output_idx=0:framerate=120:dup_frames=1,hwdownload,format=bgra')
    if not has_frame(baseline):
        print('::notice::SKIP real DXGI capture: runner desktop unavailable. ' + baseline.stdout[-1200:].replace('\n', ' '))
        sys.exit(0)
    converted = capture('ddagrab=output_idx=0:framerate=120:dup_frames=1,hwdownload,format=bgra,' + conversion)
    if not has_frame(converted):
        fail('Real DXGI compatible conversion failed', converted)
    print('::notice::PASS real DXGI -> BGRA download -> NV12 -> H264 frame. Hardware encoder performance needs a physical GPU.')
except subprocess.TimeoutExpired:
    print('::notice::SKIP real DXGI capture: inactive runner desktop timed out.')
