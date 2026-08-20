# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/lib.sh — shared helpers, sourced by every cluster/*.sh. Not executable.
# shellcheck shell=bash

set -euo pipefail

CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_inventory() {
  local inv="${INVENTORY:-$CLUSTER_DIR/inventory.env}"
  [[ -f "$inv" ]] || {
    echo "FATAL: inventory not found: $inv" >&2
    echo "       cp $CLUSTER_DIR/inventory.env.example $inv  and edit it" >&2
    exit 1
  }
  # shellcheck disable=SC1090
  source "$inv"
  : "${NODES:?}"
  # StrictHostKeyChecking=accept-new is trust-on-first-use (TOFU): the node's
  # host key is accepted and pinned to ~/.ssh/known_hosts on the FIRST connect,
  # then enforced on every connect after. Cloud allocations reuse IPs, so a
  # recycled address can present a new key (01-ssh-config.sh's HOSTKEY check
  # flags that case). To skip TOFU, pin a known host key in inventory.env via
  # SSH_OPTS (or add the entry to ~/.ssh/known_hosts) when the portal gives one.
  SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new}"
  validate_inventory "$inv"
}

# This demo runs on a single Intel Xeon 6+ instance. Catch the inventory
# mistakes that otherwise surface much later as a confusing failure in
# 30-k3s-up: more than one node, or the alias missing from ~/.ssh/config.
validate_inventory() {
  local inv="$1" errs=0 n
  local -a missing=()

  if [[ "${#NODES[@]}" -ne 1 ]]; then
    echo "FATAL: $inv: NODES must contain exactly one node (found ${#NODES[@]}); this demo is single-node" >&2
    errs=1
  fi

  for n in "${NODES[@]}"; do
    ssh -G "$n" 2>/dev/null | grep -qiE "^hostname +$n$" && missing+=("$n")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "[warn] $inv: no ~/.ssh/config stanza for: ${missing[*]}" >&2
    echo "[warn]   they will be used as literal hostnames; add a 'Host <alias>' block" >&2
    echo "[warn]   (HostName/User/IdentityFile/ProxyJump) if that is not what you want" >&2
  fi

  [[ "$errs" -eq 0 ]] || exit 1
}

node_count() { echo "${#NODES[@]}"; }

# node_index <alias> -> 0-based position in NODES (empty + rc1 if absent)
node_index() {
  local want="$1" i
  for i in "${!NODES[@]}"; do [[ "${NODES[$i]}" == "$want" ]] && { echo "$i"; return 0; }; done
  return 1
}

# Single-node demo: the one node is the k3s server.
server_node() { echo "${NODES[0]}"; }

# Address the node uses for cluster traffic: its resolved SSH HostName, so k3s
# and the Grafana tunnel target the reachable IP rather than the SSH alias.
node_cluster_ip() {
  local n="$1" host
  host="$(ssh -G "$n" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
  echo "${host:-$n}"
}

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

# `-o BatchMode=yes` is NOT inherited by the ProxyJump hop, so a lapsed
# allocation makes every script hang on the jump host's password prompt.
# Detaching from the controlling TTY denies it a prompt and fails in <1s.
if command -v setsid >/dev/null 2>&1; then
  _ssh() { setsid -w ssh "$@"; }
else
  _ssh() { ssh "$@"; }
fi

nssh() { local n="$1"; shift; _ssh $SSH_OPTS "$n" "$@"; }

# Starting path (see PROVISION_MODE in inventory.env): 'icloud' (default) or
# 'baremetal'. The Intel Cloud path is unaffected when PROVISION_MODE is unset.
provision_mode() { echo "${PROVISION_MODE:-icloud}"; }

# Kernel packaging/boot family of a node: 'deb' (Debian/Ubuntu — dpkg +
# update-grub) or 'rpm' (RHEL/Rocky/Fedora — rpm + grubby). Used by the kernel
# build/install stages to pick the right package format and bootloader tooling
# so the demo also runs on a non-Ubuntu node the user keeps. Honors an explicit
# KERNEL_PKG override (deb|rpm) in inventory; otherwise detects it over SSH from
# the node's package tooling, defaulting to 'deb' when detection is inconclusive.
node_pkg_family() {
  local n="$1" fam
  case "${KERNEL_PKG:-auto}" in
    deb|rpm) echo "${KERNEL_PKG}"; return 0 ;;
  esac
  fam="$(nssh "$n" 'if command -v dpkg >/dev/null 2>&1; then echo deb; \
                    elif command -v rpm >/dev/null 2>&1; then echo rpm; \
                    else echo unknown; fi' 2>/dev/null || echo unknown)"
  case "$fam" in
    deb|rpm) echo "$fam" ;;
    *) echo deb ;;
  esac
}

# Export host-side proxy env (http_proxy/https_proxy/no_proxy) when PROXY_URL is
# set in inventory. Host tools (git, curl, go) do NOT read Docker's daemon or
# client proxy config, so build/clone stages that fetch over HTTPS from the
# build host must call this first. No-op when PROXY_URL is empty — e.g. an Intel
# Cloud node with direct egress, where forcing a proxy would break the fetch.
apply_host_proxy() {
  [[ -n "${PROXY_URL:-}" ]] || return 0
  local np="${PROXY_NO_PROXY:-localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16}"
  export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" no_proxy="$np"
  export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" NO_PROXY="$np"
}

# Guard the bare-metal-only stages so they cannot be run against an Intel Cloud
# allocation by mistake (and vice versa is a no-op for the icloud scripts).
require_baremetal_mode() {
  [[ "$(provision_mode)" == "baremetal" ]] ||
    die "this is the bare-metal path; set PROVISION_MODE=baremetal in inventory.env (current: $(provision_mode))"
}

# Refuse a destructive re-image unless explicitly unlocked — the analogue of
# 21-kernel-install.sh's reboot_guard. Re-imaging WIPES the node's target disk
# and takes it fully offline, so it must never happen without a confirmed
# out-of-band recovery path.
reimage_guard() {
  [[ "${ALLOW_REIMAGE:-0}" == "1" ]] ||
    die "refusing to re-image ${1:-the node}: set ALLOW_REIMAGE=1 AND confirm an out-of-band recovery path + the target disk first"
}
