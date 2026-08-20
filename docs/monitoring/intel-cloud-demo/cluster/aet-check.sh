#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# AET/RAPL/resctrl smoke check — run as root on a node booted into the AET
# kernel. This is the documented gate before k3s deployment: it prints each
# check and EXITS NONZERO if any required capability (resctrl, AET counters,
# AET kernel config, RAPL, rdt=perf) is missing, so a misconfigured node fails
# fast instead of deploying a telemetry stack that will read nothing.
set -uo pipefail
fail=0
req() { echo "  MISS $1"; fail=1; }

echo "== uname =="; uname -r

echo "== resctrl =="
mount | grep -q ' /sys/fs/resctrl ' || mount -t resctrl resctrl /sys/fs/resctrl 2>/dev/null || true
if mount | grep -q ' /sys/fs/resctrl '; then
  mount | grep resctrl
else
  req "resctrl is not mounted and could not be mounted (need an AET/rdt kernel)"
fi

echo "== L3_MON mon_features =="
if feats="$(cat /sys/fs/resctrl/info/L3_MON/mon_features 2>/dev/null)" && [[ -n "$feats" ]]; then
  echo "$feats"
else
  req "no L3_MON/mon_features (resctrl monitoring counters absent)"
fi

echo "== AET PERF_PKG counters =="
# mon_features only proves generic resctrl monitoring exists (LLC/MBM); the AET
# readiness gate is the actual per-package energy counters, so require a readable
# mon_PERF_PKG_*/{core_energy,activity} pair.
aet_dir="$(compgen -G '/sys/fs/resctrl/mon_data/mon_PERF_PKG_*' 2>/dev/null | head -1 || true)"
if [[ -n "$aet_dir" && -r "$aet_dir/core_energy" && -r "$aet_dir/activity" ]]; then
  echo "  OK   $aet_dir/{core_energy,activity}"
else
  req "no readable mon_PERF_PKG_*/{core_energy,activity} counters (AET energy absent — LLC/MBM alone is not enough)"
fi

echo "== AET/BPF/RAPL config =="
cfg="/boot/config-$(uname -r)"
if [[ -r "$cfg" ]]; then
  for sym in X86_CPU_RESCTRL_INTEL_AET CGROUP_BPF INTEL_RAPL_TPMI; do
    if grep -qE "^CONFIG_${sym}=(y|m)" "$cfg"; then echo "  OK   CONFIG_$sym"; else req "CONFIG_$sym not enabled"; fi
  done
else
  req "cannot read $cfg to verify the AET kernel config"
fi

echo "== RAPL powercap =="
ls /sys/class/powercap/ 2>/dev/null | grep -q intel-rapl || modprobe intel_rapl_tpmi 2>/dev/null || true
if ls /sys/class/powercap/ 2>/dev/null | grep intel-rapl; then
  :
else
  req "no intel-rapl powercap domains (RAPL energy unavailable)"
fi

echo "== cmdline =="; cat /proc/cmdline
grep -qw 'rdt=perf' /proc/cmdline || req "rdt=perf missing from kernel command line (AET exposes no resctrl counters without it)"

if [[ "$fail" -ne 0 ]]; then
  echo "== RESULT: FAIL — node is NOT ready for AET telemetry =="
  exit 1
fi
echo "== RESULT: OK — all AET requirements satisfied =="
