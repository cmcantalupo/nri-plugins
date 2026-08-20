#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/60-validate.sh — confirm the AET telemetry pipeline is live by querying
# the in-cluster Prometheus for the per-node numbers that matter:
#   - RAPL referee   : node_rapl_package/dram_joules_total (independent of AET)
#   - AET core power : per-node core power (W) measured by AET (perf.core.energy)
#   - AET efficiency : per-node J/uop (energy per retired micro-op)
# plus integrated-energy windows over a chosen duration.
#
# Queries run through a Prometheus pod exec (GET + URL-encoded query, which
# survives the ssh->sh quoting layers where POST --post-data does not).
#
# Usage:
#   ./60-validate.sh power            per-node RAPL + AET core power, now
#   ./60-validate.sh eff              per-node J/uop (AET efficiency), now
#   ./60-validate.sh snapshot         power + eff in one shot (default)
#   ./60-validate.sh energy <dur>     integrated RAPL energy over the last <dur> (e.g. 10m)
#   ./60-validate.sh query '<promql>' run an arbitrary instant query, node-keyed
#
# Env: NODE (ssh target for kubectl exec, default = server node), PROM_NS
#      (default monitoring), WIN (rate window for power/eff, default 5m).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_inventory

NODE=${NODE:-$(server_node)}
PROM_NS=${PROM_NS:-monitoring}
WIN=${WIN:-5m}

# AET per-pod series carry k8s.pod.uid; kube_pod_info carries the uid as `uid`.
# The collector keeps the plugin's dotted OTLP names, so these are UTF-8 names
# and must be quoted inside the selector (Prometheus 3 syntax).
# This fragment lifts the node label onto each AET sample so it can be summed
# per node.
JOIN='* on ("k8s.pod.uid") group_left(node) label_replace(kube_pod_info, "k8s.pod.uid", "$1", "uid", "(.*)")'

promq() {
  local u
  u=$(python3 -c "import urllib.parse,sys;print('http://localhost:9090/api/v1/query?query='+urllib.parse.quote(sys.argv[1]))" "$1")
  nssh "$NODE" "sudo k3s kubectl -n $PROM_NS exec deploy/prometheus -c prometheus -- wget -qO- '$u'" </dev/null
}

show() {
  local unit=${1:-}
  python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('status')!='success':
    sys.stderr.write('QUERY ERROR: %s\n'%d); sys.exit(1)
data=d['data']
rt=data.get('resultType')
res=data['result']
# scalar/string results are a bare [timestamp, value] pair, not a vector of
# {metric, value} objects; handle them before the vector formatting path.
if rt in ('scalar','string'):
    v=res[1]
    try: print('  %-14s %14.6g %s' % (rt, float(v), '$unit'))
    except (TypeError, ValueError): print('  %-14s %14s %s' % (rt, v, '$unit'))
    sys.exit(0)
if not res:
    print('  (no series)'); sys.exit(0)
for r in sorted(res, key=lambda r: (r['metric'].get('node') or r['metric'].get('workload') or '')):
    m=r['metric']
    key=m.get('node') or m.get('workload') or m.get('instance') or str(m)
    print('  %-14s %14.6g %s' % (key, float(r['value'][1]), '$unit'))
"
}

cmd=${1:-snapshot}; shift || true

case "$cmd" in
  power)
    echo "== RAPL package power (W) [referee] =="
    promq "sum by (node) (rate(node_rapl_package_joules_total[$WIN]))" | show W
    echo "== RAPL DRAM power (W) [referee] =="
    promq "sum by (node) (rate(node_rapl_dram_joules_total[$WIN]))" | show W
    echo "== AET core power (W) [measured] =="
    promq "sum by (node) (rate({__name__=\"perf.core.energy_joules_total\"}[$WIN]) $JOIN)" | show W
    ;;
  eff)
    echo "== AET efficiency J/uop [lower = more efficient] =="
    promq "sum by (node) (rate({__name__=\"perf.core.energy_joules_total\"}[$WIN]) $JOIN) / sum by (node) (rate({__name__=\"perf.uops.retired_total\"}[$WIN]) $JOIN)" | show J/uop
    ;;
  energy)
    dur=${1:?usage: energy <dur> e.g. 10m}
    echo "== integrated RAPL package energy over ${dur} (J) [referee] =="
    promq "sum by (node) (increase(node_rapl_package_joules_total[$dur]))" | show J
    echo "== integrated RAPL DRAM energy over ${dur} (J) [referee] =="
    promq "sum by (node) (increase(node_rapl_dram_joules_total[$dur]))" | show J
    ;;
  snapshot)
    "$0" power; "$0" eff
    ;;
  query)
    promq "${1:?usage: query <promql>}" | show
    ;;
  *)
    sed -n '14,19p' "$0"; exit 2 ;;
esac
