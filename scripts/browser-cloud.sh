#!/bin/sh
# Local test fixture only. Loopback peers are allowed exclusively in this fixture.
set -eu
fixture="screenroom-browser-$$"
local_docker() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH docker --host=unix:///var/run/docker.sock "$@"
}
trap 'local_docker rm -f "$fixture" >/dev/null 2>&1 || true' EXIT
local_docker run -d --name "$fixture" -p 127.0.0.1::3478/tcp \
  --entrypoint turnserver coturn/coturn:4.6.3 \
  -n --listening-port=3478 --external-ip=127.0.0.1 --relay-ip=127.0.0.1 \
  --listening-ip=0.0.0.0 --use-auth-secret --static-auth-secret=browser-test \
  --realm=local.test --allow-loopback-peers --no-cli --no-tls --no-dtls \
  --min-port=49160 --max-port=49200 --log-file=stdout >/dev/null
fixture_port="$(local_docker inspect --format '{{(index (index .NetworkSettings.Ports "3478/tcp") 0).HostPort}}' "$fixture")"
node --input-type=module - "$fixture_port" <<'JS'
import net from 'node:net';
const port = Number(process.argv[2]);
for (let attempt = 0; attempt < 50; attempt++) {
  const ok = await new Promise(resolve => {
    const socket = net.connect({host:'127.0.0.1', port});
    socket.once('connect', () => {socket.destroy(); resolve(true);});
    socket.once('error', () => resolve(false));
  });
  if (ok) process.exit(0);
  await new Promise(r => setTimeout(r, 100));
}
throw new Error('Local TURN did not start');
JS
TURN_URLS="turn:127.0.0.1:${fixture_port}?transport=tcp" TURN_SECRET=browser-test npm run test:browser
