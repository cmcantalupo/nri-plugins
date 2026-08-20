#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/01-ssh-config.sh — manage the ~/.ssh/config stanzas for an allocation.
#
# An Intel Cloud allocation is temporary, but the ~/.ssh/config stanzas it needs
# are not self-cleaning: when the reservation ends the aliases still resolve, the
# jump host rejects the key, and every toolkit script trips over a password
# prompt that no password can satisfy. This script owns those stanzas in a
# delimited block so they can be generated, checked, and removed as a unit.
#
#   ./01-ssh-config.sh show     # print the block that WOULD be written
#   ./01-ssh-config.sh apply    # write/refresh the block (backs up first)
#   ./01-ssh-config.sh check    # classify every alias: LIVE / STALE / ...
#   ./01-ssh-config.sh remove   # delete the block (allocation released)
#   ./01-ssh-config.sh prune [--force] [pattern ...]
#                               # show (or delete) hand-written stanzas left
#                               # behind by an earlier allocation
#
# Inventory inputs (see inventory.env.example): NODES, SSH_IDENTITY, NODE_USER,
# NODE_HOSTS, NODE_JUMPS, JUMP_USER, and the PROXY_* block when the workstation
# reaches the cloud through a corporate proxy.
#
# Env overrides (for dry runs): INVENTORY=<file>, SSH_CONFIG=<file>.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_inventory

SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
# A stray SSH_CONFIG export must never silently redirect a --force delete.
[[ "$SSH_CONFIG" == "$HOME/.ssh/config" ]] || warn "operating on $SSH_CONFIG (SSH_CONFIG override)"
BEGIN_MARK="# >>> aet-toolkit managed block (cluster/01-ssh-config.sh) >>>"
END_MARK="# <<< aet-toolkit managed block <<<"

backup_config() {
  [[ -f "$SSH_CONFIG" ]] || { mkdir -p "$(dirname "$SSH_CONFIG")"; touch "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"; }
  local bak="$SSH_CONFIG.aet-bak.$(date +%Y%m%d-%H%M%S)" n=1
  while [[ -e "$bak" ]]; do bak="$SSH_CONFIG.aet-bak.$(date +%Y%m%d-%H%M%S).$n"; n=$((n + 1)); done
  cp -p "$SSH_CONFIG" "$bak"
  log "backed up $SSH_CONFIG -> $bak"
}

# ProxyCommand for a jump host when the workstation is behind a corporate proxy.
# ncat is not installed everywhere; netcat-openbsd's -x/-X does the same job.
proxy_command_line() {
  [[ -n "${PROXY_URL:-}" ]] || return 0
  local hp="${PROXY_SSH_HOSTPORT:-}"
  [[ -n "$hp" ]] || hp="$(printf '%s' "$PROXY_URL" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##')"
  # Default the transport to http when PROXY_URL is set but the type is omitted,
  # matching 05-proxy-setup.sh; otherwise a set PROXY_URL would silently produce
  # a direct (unusable) jump-host route.
  local mode
  case "${PROXY_SSH_TYPE:-http}" in
    http|http-connect) mode=http ;;
    socks5|socks)      mode=socks5 ;;
    *) die "PROXY_SSH_TYPE must be 'http' or 'socks5' (got '$PROXY_SSH_TYPE')" ;;
  esac
  # Fall back to netcat-openbsd only when it is actually installed; a bare `nc`
  # ProxyCommand that cannot run would replace the managed block with a config
  # that can never connect.
  if command -v ncat >/dev/null; then
    echo "    ProxyCommand ncat --proxy ${hp} --proxy-type ${mode} %h %p"
  elif command -v nc >/dev/null; then
    case "$mode" in
      http)   echo "    ProxyCommand nc -X connect -x ${hp} %h %p" ;;
      socks5) echo "    ProxyCommand nc -X 5 -x ${hp} %h %p" ;;
    esac
  else
    die "neither 'ncat' (nmap-ncat) nor 'nc' (netcat-openbsd) is installed — one is required to build the jump-host ProxyCommand; install one and re-run"
  fi
}

require_conn_facts() {
  : "${SSH_IDENTITY:?set SSH_IDENTITY in inventory.env (the private key uploaded to the portal)}"
  : "${NODE_USER:?set NODE_USER in inventory.env (the login user from the portal SSH panel)}"
  [[ -n "${NODE_HOSTS+x}" ]] ||
    die "set NODE_HOSTS in inventory.env (each node's IP from the portal's SSH panel)"
  [[ -n "${NODE_JUMPS+x}" ]] ||
    die "set NODE_JUMPS in inventory.env (each node's jump host, '' for a direct route)"
  [[ "${#NODE_HOSTS[@]}" -eq "${#NODES[@]}" ]] ||
    die "NODE_HOSTS has ${#NODE_HOSTS[@]} entries, NODES has ${#NODES[@]} (index-aligned)"
  [[ "${#NODE_JUMPS[@]}" -eq "${#NODES[@]}" ]] ||
    die "NODE_JUMPS has ${#NODE_JUMPS[@]} entries, NODES has ${#NODES[@]} (use '' for a direct route)"
}

# `BatchMode yes` on the jump stanza is load-bearing: command-line -o options are
# NOT inherited by the ProxyJump child, so without it an expired reservation
# turns every script into an unanswerable password prompt.
render_block() {
  require_conn_facts
  local i n host jump pc jalias
  local -A jump_alias_of=()
  pc="$(proxy_command_line || true)"

  echo "$BEGIN_MARK"
  echo "# Generated $(date -Is) from cluster/inventory.env. Do not hand-edit:"
  echo "# re-run './01-ssh-config.sh apply', or './01-ssh-config.sh remove' when"
  echo "# the allocation is released."

  for i in "${!NODES[@]}"; do
    jump="${NODE_JUMPS[$i]}"
    [[ -n "$jump" ]] || continue
    if [[ -z "${jump_alias_of[$jump]:-}" ]]; then
      jalias="aet-jump-$(echo "$jump" | tr -c 'a-zA-Z0-9' '-' | sed 's/-*$//')"
      jump_alias_of[$jump]="$jalias"
      echo
      echo "Host $jalias"
      echo "    HostName $jump"
      echo "    User ${JUMP_USER:-$NODE_USER}"
      echo "    IdentityFile $SSH_IDENTITY"
      echo "    BatchMode yes"
      [[ -n "$pc" ]] && echo "$pc"
    fi
  done

  for i in "${!NODES[@]}"; do
    n="${NODES[$i]}"; host="${NODE_HOSTS[$i]}"; jump="${NODE_JUMPS[$i]}"
    echo
    echo "Host $n"
    echo "    HostName $host"
    echo "    User $NODE_USER"
    echo "    IdentityFile $SSH_IDENTITY"
    echo "    BatchMode yes"
    [[ -n "$jump" ]] && echo "    ProxyJump ${jump_alias_of[$jump]}"
  done
  echo
  echo "$END_MARK"
}

has_block() { [[ -f "$SSH_CONFIG" ]] && grep -qF "$BEGIN_MARK" "$SSH_CONFIG"; }

strip_block() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$SSH_CONFIG"
}

cmd_show() { render_block; }

cmd_apply() {
  local block; block="$(render_block)"   # render before touching anything
  backup_config
  local tmp; tmp="$(mktemp)"
  strip_block > "$tmp"
  printf '%s\n' "$block" >> "$tmp"
  install -m 600 "$tmp" "$SSH_CONFIG"; rm -f "$tmp"
  log "wrote managed block for: ${NODES[*]}"
  cmd_prune            # report (never delete) leftovers that could shadow these
}

cmd_remove() {
  has_block || { log "no managed block in $SSH_CONFIG — nothing to remove"; return 0; }
  backup_config
  local tmp; tmp="$(mktemp)"
  strip_block > "$tmp"
  install -m 600 "$tmp" "$SSH_CONFIG"; rm -f "$tmp"
  log "removed the managed block from $SSH_CONFIG"
}

# ---- check: is each alias usable, and if not, why ------------------------------
classify() {
  local n="$1" out rc=0
  # setsid removes the controlling TTY so a rejected key cannot fall back to an
  # interactive password prompt on the ProxyJump hop. The explicit options come
  # first (ssh keeps the first value it sees) so this stays non-interactive with
  # a short timeout, while SSH_OPTS still supplies the inventory's host-key
  # policy: accept-new admits a first-time host but still rejects a CHANGED key,
  # which is what the HOSTKEY state is meant to report.
  out="$(setsid -w ssh -o BatchMode=yes -o ConnectTimeout=10 $SSH_OPTS "$n" true 2>&1 </dev/null)" || rc=$?
  if [[ $rc -eq 0 ]]; then echo "LIVE|ok"; return; fi
  case "$out" in
    *"Could not resolve hostname"*) echo "NO-STANZA|no ~/.ssh/config entry and not a resolvable host" ;;
    *"Permission denied"*)          echo "STALE|key rejected — reservation ended, or the key is not yet installed on this node/jump host" ;;
    *"ssh_askpass"*|*"password"*)   echo "STALE|server fell back to password auth — key no longer authorized" ;;
    *"timed out"*|*"No route"*)     echo "UNREACHABLE|network path down (proxy/jump/VPN)" ;;
    *"Host key verification failed"*) echo "HOSTKEY|host key changed — a reused IP from a new allocation" ;;
    *) echo "ERROR|$(printf '%s' "$out" | tail -1)" ;;
  esac
}

cmd_check() {
  local n state reason live=0 stale=0
  printf '%-16s %-11s %s\n' ALIAS STATE DETAIL
  for n in "${NODES[@]}"; do
    IFS='|' read -r state reason <<<"$(classify "$n")"
    printf '%-16s %-11s %s\n' "$n" "$state" "$reason"
    [[ "$state" == "LIVE" ]] && live=$((live + 1))
    [[ "$state" == "STALE" ]] && stale=$((stale + 1))
  done
  echo
  if [[ "$live" -eq "${#NODES[@]}" ]]; then
    log "all ${#NODES[@]} nodes reachable — next: ./00-probe.sh"
  elif [[ "$stale" -gt 0 ]]; then
    warn "$stale alias(es) STALE. Check the reservation in the Intel Cloud console"
    warn "  (Instances -> State / Reservation End). If it has ended, this is not an"
    warn "  SSH problem: request a new allocation (SKILLS.md Skill 1), then"
    warn "  './01-ssh-config.sh apply' with the new portal values."
  fi
}

# ---- prune: hand-written leftovers from an earlier allocation -------------------
# Reports by default. Deleting someone's hand-written SSH config is destructive,
# so it needs --force and always leaves a timestamped backup.
list_stanza() {
  strip_block | awk -v want="$1" '
    /^[Hh][Oo][Ss][Tt][[:space:]]/ {
      inblk = 0
      for (i = 2; i <= NF; i++) if ($i == want) inblk = 1
    }
    inblk { print }
  '
}

extract_block() {
  [[ -f "$SSH_CONFIG" ]] || return 0
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0 == b { f = 1 } f { print } $0 == e { f = 0 }' "$SSH_CONFIG"
}

cmd_prune() {
  local force=0
  [[ "${1:-}" == "--force" ]] && { force=1; shift; }
  local -a pats=("$@")
  [[ "${#pats[@]}" -gt 0 ]] || pats=("${NODES[@]}")

  local p found=0
  local -a hits=()
  for p in "${pats[@]}"; do
    # Only unmanaged stanzas matter; the managed block is handled by remove.
    strip_block | awk -v want="$p" '
      /^[Hh][Oo][Ss][Tt][[:space:]]/ { inblk = 0; for (i = 2; i <= NF; i++) if ($i == want) inblk = 1 }
      inblk { found = 1 }
      END { exit !found }
    ' && { hits+=("$p"); found=1; }
  done

  [[ "$found" -eq 1 ]] || { log "prune: no unmanaged stanzas for: ${pats[*]}"; return 0; }

  warn "unmanaged ~/.ssh/config stanzas shadow the managed block (ssh takes the FIRST match):"
  local -a jumps=()
  for p in "${hits[@]}"; do
    echo "----- Host $p -----"
    list_stanza "$p"
    while read -r j; do
      [[ -n "$j" ]] && ! printf '%s\n' "${jumps[@]:-}" | grep -qx "$j" && jumps+=("$j")
    done < <(list_stanza "$p" | awk '/^[[:space:]]*[Pp]roxy[Jj]ump[[:space:]]/ { print $2 }')
  done
  echo
  [[ "${#jumps[@]}" -gt 0 ]] &&
    warn "they reference jump aliases that are probably stale too: ${jumps[*]}"

  if [[ "$force" -ne 1 ]]; then
    warn "review the above, then delete them with:"
    warn "  $0 prune --force ${hits[*]} ${jumps[*]:-}"
    warn "(a timestamped backup of $SSH_CONFIG is taken first)"
    return 0
  fi

  backup_config
  local block; block="$(extract_block)"
  local tmp; tmp="$(mktemp)"
  strip_block > "$tmp"
  for p in "${hits[@]}"; do
    awk -v want="$p" '
      /^[Hh][Oo][Ss][Tt][[:space:]]/ { drop = 0; for (i = 2; i <= NF; i++) if ($i == want) drop = 1 }
      /^[Mm][Aa][Tt][Cc][Hh][[:space:]]/ { drop = 0 }
      !drop { print }
    ' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
  done
  [[ -n "$block" ]] && printf '%s\n' "$block" >> "$tmp"
  install -m 600 "$tmp" "$SSH_CONFIG"; rm -f "$tmp"
  log "pruned stanzas: ${hits[*]}"
}

case "${1:-show}" in
  show)   cmd_show ;;
  apply)  cmd_apply ;;
  check)  cmd_check ;;
  remove) cmd_remove ;;
  prune)  shift; cmd_prune "$@" ;;
  *) echo "usage: $0 {show|apply|check|remove|prune [--force] [alias ...]}" >&2; exit 2 ;;
esac
