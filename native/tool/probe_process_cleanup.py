"""Use real Dart Process.start + FFmpeg; test window close, exit, and crash."""
import argparse
import ctypes as C
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--probe', required=True)
parser.add_argument('--dart')
parser.add_argument('--ffmpeg', default='build/windows/x64/runner/Release/ffmpeg/bin/ffmpeg.exe')
opts = parser.parse_args()
kernel = C.WinDLL('kernel32', use_last_error=True)
kernel.OpenProcess.argtypes = [C.c_ulong, C.c_int, C.c_ulong]
kernel.OpenProcess.restype = C.c_void_p
kernel.WaitForSingleObject.argtypes = [C.c_void_p, C.c_ulong]
kernel.CloseHandle.argtypes = [C.c_void_p]
kernel.TerminateProcess.argtypes = [C.c_void_p, C.c_ulong]
ffmpeg = str(Path(opts.ffmpeg).resolve())
dart = opts.dart or str(Path(shutil.which('flutter')).parent / 'cache/dart-sdk/bin/dart.exe')
if not Path(dart).is_file():
    raise SystemExit('Pass the real Dart SDK executable using --dart')
control = subprocess.Popen([ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin',
                           '-re', '-f', 'lavfi', '-i', 'color=size=64x64:rate=10',
                           '-f', 'null', '-'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    with tempfile.TemporaryDirectory(prefix='pirate job with spaces ') as directory:
        script = Path(directory) / 'child with spaces.dart'
        shutil.copyfile('tool/process_job_probe/child.dart', script)
        for mode in ('window-close', 'normal-exit', 'crash'):
            marker = Path(directory) / (mode + '.pid')
            parent = subprocess.Popen([str(Path(opts.probe).resolve()), mode, str(marker),
                                       dart, str(script), ffmpeg, str(marker)],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, cwd=directory)
            handle = None
            try:
                deadline = time.monotonic() + 20
                while not marker.exists() and time.monotonic() < deadline and parent.poll() is None:
                    time.sleep(.02)
                if not marker.exists():
                    raise RuntimeError(f'{mode}: no active FFmpeg child')
                child_pid = int(marker.read_text())
                handle = kernel.OpenProcess(0x100001, False, child_pid)  # SYNCHRONIZE | TERMINATE
                if not handle or kernel.WaitForSingleObject(handle, 0) != 258:
                    raise RuntimeError(f'{mode}: FFmpeg was not alive before shutdown')
                Path(str(marker) + '.go').touch()
                parent.wait(timeout=10)
                if kernel.WaitForSingleObject(handle, 5000) != 0:
                    raise RuntimeError(f'{mode}: orphan FFmpeg survived parent shutdown')
                if control.poll() is not None:
                    raise RuntimeError('An unrelated FFmpeg process was terminated')
                print(f'::notice::PASS process cleanup: {mode}; real Dart/FFmpeg child stopped, unrelated FFmpeg stays alive.')
            except Exception as error:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait(timeout=5)
                try:
                    diagnostic = parent.communicate(timeout=3)[1].decode(errors='replace')
                except subprocess.TimeoutExpired:
                    diagnostic = 'Child stderr pipe did not close'
                raise RuntimeError(f'{error}; parent code={parent.poll()}; {diagnostic}') from error
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait(timeout=5)
                if handle:
                    if kernel.WaitForSingleObject(handle, 0) == 258:
                        kernel.TerminateProcess(handle, 1)
                        kernel.WaitForSingleObject(handle, 3000)
                    kernel.CloseHandle(handle)
finally:
    control.kill()
    control.wait(timeout=5)
