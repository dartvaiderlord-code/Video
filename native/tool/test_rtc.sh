#!/bin/sh
# Linux headless encoder/transport regression. Not a Windows capture benchmark.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="${PIRATE_RTC_WORK:-$(mktemp -d)}"
mkdir -p "$work"
archive="$work/libwebrtc-linux.zip"
if [ ! -f "$archive" ]; then
  curl -fL --retry 3 https://github.com/webrtc-sdk/libwebrtc/releases/download/libwebrtc.m150.7871.07/libwebrtc-linux-x64-release.zip -o "$archive"
fi
(cd "$work" && printf '%s  %s\n' ef380526cf9616848bc0b97b24990cbf2ad851c209d5dce93cc3ebb9d3789fbc libwebrtc-linux.zip | sha256sum -c -)
unzip -oq "$archive" -d "$work"
sdk="$work/linux-x64-release"
g++ -std=c++17 -DRTC_DESKTOP_DEVICE -O2 "$root/tool/rtc_benchmark.cpp" -I"$sdk/include" -L"$sdk/lib" -Wl,-rpath,"$sdk/lib" -lwebrtc -pthread -o "$work/rtc-benchmark"
# The SDK initializes an audio device even in a video-only test.
# The runner's own PulseAudio null sink needs no real microphone/speakers.
pulse_work="$(mktemp -d)"
chmod 700 "$pulse_work"
mkdir -p "$pulse_work/run" "$pulse_work/state" "$pulse_work/config"
cat > "$pulse_work/test.pa" <<PA
load-module module-native-protocol-unix socket=$pulse_work/run/native auth-anonymous=1
load-module module-null-sink sink_name=pirate_benchmark
set-default-sink pirate_benchmark
set-default-source pirate_benchmark.monitor
PA
PULSE_RUNTIME_PATH="$pulse_work/run" PULSE_STATE_PATH="$pulse_work/state" XDG_CONFIG_HOME="$pulse_work/config" pulseaudio -nF "$pulse_work/test.pa" --exit-idle-time=-1 --daemonize=yes
trap 'if [ -f "$pulse_work/run/pid" ]; then kill "$(cat "$pulse_work/run/pid")" 2>/dev/null || true; fi; rm -rf "$pulse_work"' EXIT
export PULSE_SERVER="unix:$pulse_work/run/native"
export XDG_CONFIG_HOME="$pulse_work/config"
# Check a high-motion bitrate and >60 actual decoded FPS separately from HD.
timeout 45 "$work/rtc-benchmark" quality 120 320 > "$work/120fps.log" 2>&1
timeout 45 "$work/rtc-benchmark" quality 60 640 > "$work/bitrate.log" 2>&1
sed -n '/sent_Mbps=/p' "$work/120fps.log" "$work/bitrate.log"
