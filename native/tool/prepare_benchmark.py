"""Select only pure Dart protocol dependencies; GUI plugin hooks aren't used."""
import json
from pathlib import Path
from urllib.parse import urljoin
root=Path(__file__).resolve().parents[1]
source=root/'.dart_tool/package_config.json'
config=json.loads(source.read_text())
names={'pirate_tavern','abordage_crypto','ffi','crypto','cryptography','collection','meta','typed_data'}
packages=[]
for package in config['packages']:
    if package['name'] in names:
        package['rootUri']=urljoin(source.as_uri(),package['rootUri'])
        packages.append(package)
if {p['name'] for p in packages}!=names: raise SystemExit('Run flutter pub get first')
config['packages']=packages
(root/'.dart_tool/abordage_package_config.json').write_text(json.dumps(config))
