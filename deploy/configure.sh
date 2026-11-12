#!/bin/sh
# Generate standalone configuration once. Requires only POSIX tools and OpenSSL.
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo 'Usage: sh deploy/configure.sh HOSTNAME_OR_IPV4 [PUBLIC_IPV4]' >&2
    exit 1
fi
is_ipv4() {
    case "$1" in ''|*[!0-9.]*) return 1;; esac
    printf '%s\n' "$1" | awk -F. 'NF != 4 {exit 1} {for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || length($i)>3 || $i+0>255 || (length($i)>1 && substr($i,1,1)=="0")) exit 1}'
}
host=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
case "$host" in ''|*[!a-zA-Z0-9.-]*) echo 'Use a DNS hostname or IPv4, without URL syntax or whitespace.' >&2; exit 1;; esac
if ! is_ipv4 "$host"; then
    # DNS labels only: reject URL syntax, whitespace, config injection and IPv6.
    if ! printf '%s\n' "$host" | LC_ALL=C awk -F. 'length($0)>253 || NF<2 {exit 1} {for(i=1;i<=NF;i++) if(length($i)<1 || length($i)>63 || $i !~ /^[a-zA-Z0-9-]+$/ || $i ~ /^-/ || $i ~ /-$/) exit 1; if($NF !~ /[a-zA-Z]/) exit 1}'; then
        echo 'Use an IPv4 address or DNS hostname, without scheme, port or path.' >&2
        exit 1
    fi
fi
public_ip=${2:-$host}
if ! is_ipv4 "$public_ip"; then
    echo 'For a hostname, provide the server public IPv4 as the second argument.' >&2
    exit 1
fi
https_port=${HTTPS_PORT:-8443}
app_port=${APP_PORT:-3100}
turn_port=${TURN_PORT:-3479}
turn_min=${TURN_MIN_PORT:-40000}
turn_max=${TURN_MAX_PORT:-40060}
for port in "$https_port" "$app_port" "$turn_port" "$turn_min" "$turn_max"; do
    case "$port" in ''|0*|*[!0-9]*) echo 'Ports must be integers from 1 to 65535.' >&2; exit 1;; esac
    if [ "${#port}" -gt 5 ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo 'Ports must be integers from 1 to 65535.' >&2; exit 1
    fi
done
if [ "$turn_min" -gt "$turn_max" ] || [ "$https_port" -eq "$app_port" ] || [ "$https_port" -eq "$turn_port" ] || [ "$app_port" -eq "$turn_port" ]; then
    echo 'Choose distinct service ports and an ordered TURN relay range.' >&2; exit 1
fi
if [ "$turn_port" -ge "$turn_min" ] && [ "$turn_port" -le "$turn_max" ]; then
    echo 'TURN listening port must be outside the relay range.' >&2; exit 1
fi
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
env_file=${SCREENROOM_ENV_FILE:-$project_dir/.env}
if [ -e "$env_file" ] || [ -L "$env_file" ]; then
    echo 'Configuration already exists; preserve it and edit it manually.' >&2; exit 1
fi
command -v openssl >/dev/null
access_key=$(openssl rand -hex 24)
turn_secret=$(openssl rand -hex 32)
umask 077
set -C
cat > "$env_file" <<CONFIG
DOMAIN=$host
PUBLIC_ORIGIN=https://$host:$https_port
HTTPS_PORT=$https_port
APP_PORT=$app_port
MAX_VIEWERS=6
ACCESS_KEY=$access_key
TURN_PUBLIC_IP=$public_ip
TURN_PORT=$turn_port
TURN_MIN_PORT=$turn_min
TURN_MAX_PORT=$turn_max
TURN_URLS=turn:$public_ip:$turn_port?transport=udp,turn:$public_ip:$turn_port?transport=tcp
TURN_SECRET=$turn_secret
CONFIG
unset access_key turn_secret
echo "Created private configuration for https://$host:$https_port"
echo 'ACCESS_KEY in .env is the room creation code. Keep TURN_SECRET private.'
echo 'Start: docker compose -p screenroom -f compose.yaml -f compose.selfsigned.yaml -f compose.turn.yaml up -d --build'
