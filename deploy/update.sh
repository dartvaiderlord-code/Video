#!/bin/sh
# Run in the existing checkout after git pull --ff-only. Update the app only.
set -eu
project=${1:-screenroom}
case "$project" in ''|*[!a-zA-Z0-9_-]*) echo 'Invalid Compose project name.' >&2; exit 1;; esac
if [ ! -f compose.yaml ] || [ ! -f .env ]; then
  echo 'Run from the existing Video directory containing compose.yaml and .env.' >&2
  exit 1
fi
container=$(docker compose -p "$project" -f compose.yaml ps -aq app)
if [ -z "$container" ]; then
  echo "No existing app container in project $project. Check: docker compose ls" >&2
  exit 1
fi
# Build first: a failed build leaves the current app running.
docker compose -p "$project" -f compose.yaml build app
docker compose -p "$project" -f compose.yaml up -d --no-deps app
# Query from inside the container, independent of the configured HTTPS/backend port.
docker compose -p "$project" -f compose.yaml exec -T app node --input-type=module -e '
let last;
for (let attempt = 0; attempt < 20; attempt++) {
  try {
    const response = await fetch("http://127.0.0.1:3000/api/version");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const info = await response.json();
    if (!info.features?.includes("chat") || !info.features?.includes("voice")) throw new Error("Chat/voice unavailable");
    console.log(`Server ${info.version}: text and voice chat available. Create a new room.`);
    process.exit(0);
  } catch (error) { last = error; await new Promise(resolve => setTimeout(resolve, 500)); }
}
console.error(`App update check failed: ${last}`); process.exit(1);
'
