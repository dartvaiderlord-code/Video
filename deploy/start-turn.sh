#!/bin/sh
set -eu
# A private, ephemeral config keeps the shared secret out of process arguments.
umask 077
cat > /tmp/turnserver.conf <<CONFIG
listening-port=${TURN_PORT:-3478}
fingerprint
use-auth-secret
static-auth-secret=${TURN_SECRET}
realm=${TURN_REALM}
external-ip=${TURN_PUBLIC_IP}
min-port=${TURN_MIN_PORT:-49160}
max-port=${TURN_MAX_PORT:-49200}
no-cli
no-tls
no-dtls
no-multicast-peers
no-loopback-peers
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=224.0.0.0-255.255.255.255
denied-peer-ip=::
denied-peer-ip=::1
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
user-quota=12
total-quota=200
stale-nonce=600
no-tcp-relay
log-file=stdout
simple-log
CONFIG
exec turnserver -c /tmp/turnserver.conf
