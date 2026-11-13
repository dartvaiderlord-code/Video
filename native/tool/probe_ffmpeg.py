"""Try real Windows DDAGrab -> NV12 capture, without claiming a frame-rate result."""
from pathlib import Path
import subprocess,sys
exe=Path('build/windows/x64/runner/Release/ffmpeg/bin/ffmpeg.exe').resolve()
def capture(graph):
    return subprocess.run([str(exe),'-hide_banner','-loglevel','info','-f','lavfi','-i',graph,'-frames:v','1','-an','-c:v','libx264','-preset','ultrafast','-tune','zerolatency','-f','null','-'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace',timeout=20)
try:
    baseline=capture('ddagrab=output_idx=0:framerate=120:dup_frames=0,hwdownload,format=bgra')
    if baseline.returncode:
        print('::notice::SKIP Abordage capture probe: runner DXGI capture unavailable. '+baseline.stdout[-1500:].replace('\n',' '))
        sys.exit(0)
    scaled=capture('ddagrab=output_idx=0:framerate=120:dup_frames=0,scale_d3d11=width=640:height=360:format=nv12,hwdownload,format=nv12')
    if scaled.returncode:
        print('::error::Abordage GPU scaling probe failed: '+scaled.stdout[-4000:].replace('\n',' '));sys.exit(1)
    print('::notice::PASS Abordage: real DXGI -> D3D11 NV12 -> H264 frame. This checks startup, not HD/120 or a hardware encoder.')
except subprocess.TimeoutExpired:
    print('::notice::SKIP Abordage capture probe: inactive runner desktop did not deliver a frame within 20 seconds.')
