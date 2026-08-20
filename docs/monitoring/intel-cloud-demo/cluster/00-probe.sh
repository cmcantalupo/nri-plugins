#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/00-probe.sh — node capability/topology probe.
# Read-only. Prints a capability report for the single demo node.
#
#   ./00-probe.sh            # probe the node in the inventory
#   INVENTORY=foo.env ./00-probe.sh
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_inventory

OUTDIR="$(mktemp -d)"
trap 'rm -rf "$OUTDIR"' EXIT

probe_one() {
  local n="$1"
  echo "################## $n ##################"
  nssh "$n" 'bash -s' >"$OUTDIR/$n" 2>&1 <<'EOF' || echo "  (SSH FAILED)" >>"$OUTDIR/$n"
echo "-- identity --"; echo "host=$(hostname) kernel=$(uname -r)"; . /etc/os-release 2>/dev/null && echo "os=$PRETTY_NAME"
echo "-- cpu/topology --"; lscpu | grep -E "^Model name|^Socket|^NUMA node\(s\)|^CPU\(s\):" | sed 's/^/  /'
echo "-- sudo --"; sudo -n true 2>/dev/null && echo "  passwordless-sudo=yes" || echo "  passwordless-sudo=NO"
echo "-- cgroup v2 + BPF --"; echo "  cgroup=$(stat -fc %T /sys/fs/cgroup)"; grep -q "CONFIG_CGROUP_BPF=y" "/boot/config-$(uname -r)" && echo "  CGROUP_BPF=y" || echo "  CGROUP_BPF=missing"
echo "-- RAPL referee --"; ls /sys/class/powercap/ 2>/dev/null | grep -E "intel-rapl" | sed 's/^/  /' || echo "  (no powercap)"
echo "-- resctrl / AET --"; grep -E "CONFIG_X86_CPU_RESCTRL=|CONFIG_X86_CPU_RESCTRL_INTEL_AET" "/boot/config-$(uname -r)" | sed 's/^/  /'
echo "-- egress --"; timeout 8 bash -c 'echo > /dev/tcp/github.com/443' 2>/dev/null && echo "  github:443=OPEN" || echo "  github:443=blocked"
EOF
  cat "$OUTDIR/$n"
  echo
}

field() { sed -n "s/.*$2=\([^ ]*\).*/\1/p" "$OUTDIR/$1" | head -1; }
cpu_model() { sed -n 's/^ *Model name: *//p' "$OUTDIR/$1" | head -1; }

# Single-node capability report: confirm the node is reachable and (optionally)
# is the CPU model the catalog promised.
capability_report() {
  local n model kern bad=0
  n="${NODES[0]}"
  model="$(cpu_model "$n")"; kern="$(field "$n" kernel)"
  printf '%-14s %-22s %s\n' ALIAS KERNEL "CPU MODEL"
  printf '%-14s %-22s %s\n' "$n" "${kern:-?}" "${model:-UNREACHABLE}"
  echo

  if [[ -z "$model" ]]; then
    warn "The node was not reachable. Before debugging anything else, check that"
    warn "  the allocation is still live (Intel Cloud console -> Instances -> State"
    warn "  / Reservation End) and that ~/.ssh/config still matches it. A stale"
    warn "  alias from an expired allocation fails as a jump-host password prompt."
    return 1
  fi

  if [[ -n "${EXPECT_CPU_MODEL:-}" ]]; then
    if [[ "$model" == *"$EXPECT_CPU_MODEL"* ]]; then
      echo "CPU: matches EXPECT_CPU_MODEL='$EXPECT_CPU_MODEL' ($model)"
    else
      warn "$n: CPU model '$model' does not match EXPECT_CPU_MODEL='$EXPECT_CPU_MODEL'"
      bad=1
    fi
  else
    echo "CPU: $model"
  fi
  return "$bad"
}

for n in "${NODES[@]}"; do probe_one "$n"; done

echo "==================== summary ===================="
# capability_report returns nonzero for an unreachable node or an
# EXPECT_CPU_MODEL mismatch. Capture that result and use it to gate the "build
# next" guidance so the hardware check actually stops an unsuitable node.
cap_rc=0
capability_report || cap_rc=$?
echo
echo "node: ${NODES[0]}"
srv_kernel="$(field "$(server_node)" kernel)"
[[ -n "$srv_kernel" ]] &&
  echo "Set STOCK_KERNEL=$srv_kernel in inventory.env (the node's live kernel)."
if [[ "$cap_rc" -ne 0 ]]; then
  die "capability check failed (unreachable node or CPU model mismatch) — resolve before building the AET kernel"
fi
echo "Next: ./20-kernel-build.sh all (build the AET kernel on your build host)."
