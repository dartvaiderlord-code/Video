"""Pinned separate FFmpeg executable + license/provenance for portable Windows."""
from pathlib import Path
import hashlib,json,shutil,sys,tempfile,urllib.request,zipfile
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'tool/ffmpeg-windows.json').read_text())
destination=Path(sys.argv[1]) if len(sys.argv)>1 else root/'build/windows/x64/runner/Release/ffmpeg'
with tempfile.TemporaryDirectory(prefix='abordage-ffmpeg-') as temporary:
    archive=Path(temporary)/'ffmpeg.zip'
    urllib.request.urlretrieve(manifest['url'],archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=manifest['sha256']:
        raise SystemExit('Pinned FFmpeg SHA-256 mismatch')
    with zipfile.ZipFile(archive) as zipped:
        zipped.extractall(Path(temporary)/'unpacked')
    candidates=list((Path(temporary)/'unpacked').glob('*/bin/ffmpeg.exe'))
    if len(candidates)!=1: raise SystemExit('Unexpected FFmpeg archive')
    upstream=candidates[0].parents[1]
    destination.mkdir(parents=True,exist_ok=True)
    (destination/'bin').mkdir(exist_ok=True)
    shutil.copy2(candidates[0],destination/'bin/ffmpeg.exe')
    for entry in upstream.iterdir():
        if entry.name.lower()=='bin': continue
        if entry.is_dir(): shutil.copytree(entry,destination/entry.name,dirs_exist_ok=True)
        else: shutil.copy2(entry,destination/entry.name)
    shutil.copy2(root/'tool/ffmpeg-windows.json',destination/'build-provenance.json')
    shutil.copy2(root/'tool/FFMPEG-NOTICE.txt',destination/'DISTRIBUTION-NOTICE.txt')
print('Bundled pinned FFmpeg with licenses and provenance:',destination)
