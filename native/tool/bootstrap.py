"""Generate pinned Flutter platform scaffolding; never replace existing app sources."""
from pathlib import Path
import subprocess
import shutil
import tempfile

root = Path(__file__).resolve().parents[1]
if not (root / 'android').exists() or not (root / 'windows').exists():
    with tempfile.TemporaryDirectory(prefix='pirate-platforms-') as temp:
        subprocess.run(['flutter', 'create', '--platforms=android,windows', '--org', 'ru.piratetraktir',
                        '--project-name', 'pirate_tavern', '--android-language', 'kotlin', '--no-pub', temp], check=True)
        for platform in ('android', 'windows'):
            if not (root / platform).exists():
                shutil.copytree(Path(temp) / platform, root / platform)

manifest = root / 'android/app/src/main/AndroidManifest.xml'
text = manifest.read_text(encoding='utf-8')
text = text.replace('android:label="pirate_tavern"', 'android:label="Пиратский трактир"')
# Microphone is requested at runtime only when joining the optional voice chat.
for permission in ('INTERNET', 'ACCESS_NETWORK_STATE', 'MODIFY_AUDIO_SETTINGS', 'RECORD_AUDIO'):
    if f'android.permission.{permission}' not in text:
        text = text.replace('    <application', f'    <uses-permission android:name="android.permission.{permission}" />\n    <application', 1)
if 'android:usesCleartextTraffic=' not in text:
    text = text.replace('    <application', '    <application android:usesCleartextTraffic="false"', 1)
manifest.write_text(text, encoding='utf-8')
activity = root / 'android/app/src/main/kotlin/ru/piratetraktir/pirate_tavern/MainActivity.kt'
activity.write_text((root / 'tool/MainActivity.kt').read_text(encoding='utf-8'), encoding='utf-8')
main = root / 'windows/runner/main.cpp'
main.write_text(main.read_text(encoding='utf-8').replace('L"pirate_tavern"', 'L"Пиратский трактир"'), encoding='utf-8')
cmake = root / 'windows/CMakeLists.txt'
content = cmake.read_text(encoding='utf-8')
if 'add_compile_options(/utf-8)' not in content:
    content = content.replace('project(pirate_tavern LANGUAGES CXX)', 'project(pirate_tavern LANGUAGES CXX)\nadd_compile_options(/utf-8)')
    cmake.write_text(content, encoding='utf-8')
print('Native Android viewer and Windows runner prepared. Dart sources preserved.')
