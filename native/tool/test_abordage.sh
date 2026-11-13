#!/bin/sh
set -eu
abordage_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
abordage_work="$abordage_root/build/abordage-benchmark"
mkdir -p "$abordage_work"
cc -shared -fPIC -O3 "$abordage_root/packages/abordage_crypto/src/monocypher.c" "$abordage_root/packages/abordage_crypto/src/abordage_crypto.c" -o "$abordage_work/libabordage_crypto.so"
export ABORDAGE_CRYPTO_LIBRARY="$abordage_work/libabordage_crypto.so"
export ABORDAGE_REPO=$(dirname "$abordage_root")
python3 "$abordage_root/tool/prepare_benchmark.py"
# Compile outside the Flutter package: unrelated GUI build hooks are not used.
abordage_temporary=$(mktemp -d)
trap 'rm -rf "$abordage_temporary"' EXIT
(cd "$abordage_temporary" && dart compile exe --packages="$abordage_root/.dart_tool/abordage_package_config.json" "$abordage_root/tool/abordage_benchmark.dart" -o "$abordage_work/benchmark")
cd "$abordage_root"
"$abordage_work/benchmark" 320 180 480 25 > "$abordage_work/480fps.log" 2>&1 || { cat "$abordage_work/480fps.log"; exit 1; }
cat "$abordage_work/480fps.log"
"$abordage_work/benchmark" 640 360 240 50 > "$abordage_work/240fps.log" 2>&1 || { cat "$abordage_work/240fps.log"; exit 1; }
cat "$abordage_work/240fps.log"
