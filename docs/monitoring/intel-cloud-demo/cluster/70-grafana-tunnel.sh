#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/70-grafana-tunnel.sh — publish the in-cluster Grafana (HTTP NodePort
# 30030) as an HTTPS URL a user can open in a browser, via a persistent TLS
# reverse proxy on a public-facing PUBLISH_HOST plus an SSH tunnel.
#
# The Intel Cloud node is only reachable from your workstation (through a
# jump host), so the browser cannot hit the NodePort directly. We front Grafana
# with a host that a user CAN reach:
#
#   Browser
#     -> PUBLISH_HOST:GRAFANA_HTTPS_PORT   (persistent TLS reverse proxy; set up once)
#     -> 127.0.0.1:GRAFANA_BACKEND_PORT    (plain-HTTP backend on PUBLISH_HOST)
#     -> [ssh tunnel]                      (this script; the piece that drops/restores)
#     -> <node>:30030                      (Grafana HTTP NodePort, k3s)
#
# SSH never terminates TLS — the HTTPS layer is the proxy on PUBLISH_HOST. This
# script only (re)binds the plain-HTTP backend port. Two tunnel directions:
#
#   reverse  (default) run on your WORKSTATION. Reverse-forwards Grafana to
#            PUBLISH_HOST. Use when only the workstation can reach the node
#            (the Intel Cloud / developer-cloud case).
#   forward  run ON the PUBLISH_HOST. Forwards PUBLISH_HOST:backend -> node:30030.
#            Use when the publish host itself can SSH to the node.
#
#   ./70-grafana-tunnel.sh up        # start the tunnel (reverse, from workstation)
#   ./70-grafana-tunnel.sh forward   # start the tunnel (run on PUBLISH_HOST)
#   ./70-grafana-tunnel.sh status    # check backend + HTTPS chain on PUBLISH_HOST
#   ./70-grafana-tunnel.sh down      # stop the tunnel
#   ./70-grafana-tunnel.sh local     # quick operator-only view on localhost:3000
#
# Inventory vars (inventory.env): PUBLISH_HOST, GRAFANA_HTTPS_PORT (default 3443),
#   GRAFANA_BACKEND_PORT (default 3008), GRAFANA_NODEPORT (default 30030),
#   GRAFANA_NODE_TARGET (host:port the WORKSTATION uses to reach Grafana for the
#   reverse tunnel; default <server cluster IP>:GRAFANA_NODEPORT).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_inventory

HTTPS_PORT="${GRAFANA_HTTPS_PORT:-3443}"
BACKEND_PORT="${GRAFANA_BACKEND_PORT:-3008}"
NODEPORT="${GRAFANA_NODEPORT:-30030}"
SERVER="$(server_node)"

require_publish_host() {
  [[ -n "${PUBLISH_HOST:-}" ]] || die "set PUBLISH_HOST in inventory.env (the public-facing TLS-proxy host)"
}

# ---- reverse: run on the workstation, bind the backend on PUBLISH_HOST --------
cmd_up() {
  require_publish_host
  local tgt
  if [[ -n "${GRAFANA_NODE_TARGET:-}" ]]; then
    # Operator asserts the workstation can dial this target directly, so the
    # reverse forward's own outbound connection can reach it unaided.
    tgt="$GRAFANA_NODE_TARGET"
  else
    # Default target is the node's private NodePort, reachable from the
    # workstation only through $SERVER's ProxyJump. A reverse (-R) forward is
    # dialed by the ssh client to PUBLISH_HOST and does NOT ride that ProxyJump,
    # so it cannot reach the node IP directly. Bridge it: first open a local
    # forward over $SERVER (which HAS the ProxyJump) to expose the NodePort on
    # the workstation loopback, then reverse-forward that loopback endpoint.
    log "local bridge: 127.0.0.1:$BACKEND_PORT -> $SERVER:$NODEPORT (via ProxyJump)"
    ssh $SSH_OPTS -f -N \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
      -L "127.0.0.1:$BACKEND_PORT:localhost:$NODEPORT" "$SERVER"
    tgt="127.0.0.1:$BACKEND_PORT"
  fi
  log "reverse tunnel: $PUBLISH_HOST:127.0.0.1:$BACKEND_PORT -> $tgt (Grafana)"
  # Loopback bind on PUBLISH_HOST: the TLS proxy connects to 127.0.0.1:backend,
  # so no GatewayPorts is needed on the publish host.
  ssh $SSH_OPTS -f -N \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
    -R "127.0.0.1:$BACKEND_PORT:$tgt" "$PUBLISH_HOST"
  log "up. Browse: https://$PUBLISH_HOST:$HTTPS_PORT/  (self-signed cert expected)"
}

# ---- forward: run ON the publish host, reach the node directly ---------------
cmd_forward() {
  log "forward tunnel (run this on the publish host): 127.0.0.1:$BACKEND_PORT -> $SERVER:$NODEPORT"
  ssh $SSH_OPTS -f -N \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:$BACKEND_PORT:localhost:$NODEPORT" "$SERVER"
  log "up. The local TLS proxy should now serve https://<this-host>:$HTTPS_PORT/"
}

cmd_status() {
  require_publish_host
  log "checking backend + HTTPS chain on $PUBLISH_HOST"
  nssh "$PUBLISH_HOST" "
    printf '  backend  http://127.0.0.1:$BACKEND_PORT/  -> '
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 6 http://127.0.0.1:$BACKEND_PORT/ || echo 000
    printf '  https    https://localhost:$HTTPS_PORT/   -> '
    curl -sk -o /dev/null -w '%{http_code}\n' --max-time 8 https://localhost:$HTTPS_PORT/ || echo 000
  " || warn "status check failed"
  echo "  200/200 = healthy; 503/000 = proxy up but tunnel down (re-run 'up'); refused = TLS proxy down"
}

cmd_down() {
  require_publish_host
  # Kill any of our tunnels (reverse from here, or forward on the publish host).
  pkill -f "ssh .*-R 127.0.0.1:$BACKEND_PORT:" 2>/dev/null && log "stopped reverse tunnel" || true
  # The local bridge forward this script may have opened over $SERVER (the -R
  # case above); match the loopback -L to the NodePort so we don't touch the
  # operator-only 'local' view (which binds -L 3000:...).
  pkill -f "ssh .*-L 127.0.0.1:.*:localhost:$NODEPORT" 2>/dev/null && log "stopped local bridge forward" || true
  nssh "$PUBLISH_HOST" "pkill -f 'ssh .*-L 127.0.0.1:$BACKEND_PORT:' 2>/dev/null" 2>/dev/null \
    && log "stopped forward tunnel on $PUBLISH_HOST" || true
}

# ---- local: quick operator-only view (no publish host) -----------------------
cmd_local() {
  log "operator view: forwarding localhost:3000 -> $SERVER:$NODEPORT (Ctrl-C to stop)"
  log "open http://localhost:3000/ (log in as the grafana-admin user; see inventory.env / deploy output)"
  ssh $SSH_OPTS -N -L "3000:localhost:$NODEPORT" "$SERVER"
}

case "${1:-up}" in
  up)      cmd_up ;;
  forward) cmd_forward ;;
  status)  cmd_status ;;
  down)    cmd_down ;;
  local)   cmd_local ;;
  *) echo "usage: $0 {up|forward|status|down|local}" >&2; exit 2 ;;
esac
