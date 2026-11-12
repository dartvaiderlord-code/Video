#!/bin/sh
set -eu
# Snikket remains the certificate owner. Re-read its renewed files hourly.
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
server_pid=$!
(
    while sleep 3600; do
        caddy reload --force --config /etc/caddy/Caddyfile --adapter caddyfile || echo 'Certificate reload failed; check certificate paths and renewal.' >&2
    done
) &
reload_pid=$!
stop() {
    trap - TERM INT
    kill "$reload_pid" "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    exit 0
}
trap stop TERM INT
result=0
wait "$server_pid" || result=$?
kill "$reload_pid" 2>/dev/null || true
exit "$result"
