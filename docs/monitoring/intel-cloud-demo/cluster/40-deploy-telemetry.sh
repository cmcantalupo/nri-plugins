#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/40-deploy-telemetry.sh — deploy the AET telemetry stack onto the k3s
# cluster: a `monitoring` namespace with Prometheus + Grafana +
# kube-state-metrics (dt1), then the three per-node workloads —
# otel-collector-resctrl, nri-resctrl-mon and rapl-node-exporter (dt2).
#
# kubectl is only ever invoked on the server node via `sudo k3s kubectl`; there
# is no kubeconfig or helm on the nodes. Manifests are streamed from this repo
# straight into `kubectl apply -f -` over SSH.
#
#   ./40-deploy-telemetry.sh dt1         # ns + ksm + prometheus + grafana
#   ./40-deploy-telemetry.sh ns          # namespace only
#   ./40-deploy-telemetry.sh ksm         # kube-state-metrics
#   ./40-deploy-telemetry.sh prometheus  # Prometheus (NodePort 30090)
#   ./40-deploy-telemetry.sh grafana     # Grafana (NodePort 30030)
#   ./40-deploy-telemetry.sh otel        # otel-collector-resctrl Deployment (OTLP sink)
#   ./40-deploy-telemetry.sh rapl        # rapl-node-exporter DaemonSet
#   ./40-deploy-telemetry.sh nri         # nri-resctrl-mon DaemonSet
#   ./40-deploy-telemetry.sh netpol      # opt-in baseline NetworkPolicies (validate live first)
#   ./40-deploy-telemetry.sh status      # kubectl get all -n monitoring
#   ./40-deploy-telemetry.sh verify      # smoke-check targets + AET/RAPL series
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_inventory

TELEMETRY_DIR="${TELEMETRY_DIR:-$CLUSTER_DIR/telemetry}"
NS="${MONITORING_NS:-monitoring}"

# kubectl on the server node (reachable via SSH; no local kubeconfig needed).
skubectl() { local srv; srv="$(server_node)"; nssh "$srv" "sudo k3s kubectl $*"; }

# Stream a local manifest into `kubectl apply -f -` on the server.
sapply() {
  local f="$TELEMETRY_DIR/$1"
  [[ -f "$f" ]] || die "manifest not found: $f"
  log "apply $1"
  nssh "$(server_node)" "sudo k3s kubectl apply -f -" < "$f"
}

# Like sapply, but first expand a restricted allowlist of ${VARS} via envsubst
# (e.g. GRAFANA_ROOT_URL in 30-grafana.yaml). The allowlist keeps any other `$`
# in the manifest untouched. Usage: sapply_env <file> '${VAR1} ${VAR2}'
sapply_env() {
  local f="$TELEMETRY_DIR/$1" vars="$2"
  [[ -f "$f" ]] || die "manifest not found: $f"
  command -v envsubst >/dev/null 2>&1 || die "envsubst not found (install gettext) — needed to template $1"
  log "apply $1 (templated: $vars)"
  envsubst "$vars" < "$f" | nssh "$(server_node)" "sudo k3s kubectl apply -f -"
}

wait_rollout() {  # wait_rollout <kind/name> [timeout]
  local obj="$1" to="${2:-180s}"
  log "wait rollout $obj (${to})"
  # A rollout that never becomes ready (e.g. ImagePullBackOff) must fail the
  # deploy: later stages depend on these workloads, so propagate it instead of
  # warning and continuing.
  skubectl "-n $NS rollout status $obj --timeout=$to" \
    || die "$obj not ready within $to (check: ./40-deploy-telemetry.sh status)"
}

# ---- dt1. namespace + core monitoring -----------------------------------------
cmd_ns()      { sapply 00-namespace.yaml; }
cmd_ksm()     { sapply 10-kube-state-metrics.yaml; wait_rollout deploy/kube-state-metrics; }
cmd_prometheus() { sapply 20-prometheus.yaml; wait_rollout deploy/prometheus; }

# Ensure the grafana-admin Secret exists (referenced by 30-grafana.yaml). The
# password is taken from GRAFANA_ADMIN_PASSWORD in inventory.env; if unset, a
# random one is generated and printed once. An existing Secret is left as-is so
# repeated deploys do not silently rotate the password. The Secret is streamed
# over stdin (base64-encoded locally) so the password never lands in a process
# argument list on the node.
ensure_grafana_secret() {
  local srv user pass generated=0 ub pb
  srv="$(server_node)"
  if nssh "$srv" "sudo k3s kubectl -n $NS get secret grafana-admin" >/dev/null 2>&1; then
    log "grafana-admin secret already present — leaving it unchanged"
    return 0
  fi
  user="${GRAFANA_ADMIN_USER:-admin}"
  pass="${GRAFANA_ADMIN_PASSWORD:-}"
  if [[ -z "$pass" ]]; then
    # cut drains its input; `head -c` would close the pipe early and kill tr
    # with SIGPIPE, which under `set -o pipefail` aborts the whole deploy.
    pass="$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
    generated=1
  fi
  ub="$(printf '%s' "$user" | base64 | tr -d '\n')"
  pb="$(printf '%s' "$pass" | base64 | tr -d '\n')"
  log "create grafana-admin secret (user=$user)"
  nssh "$srv" "sudo k3s kubectl apply -f -" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: $NS
  labels:
    app.kubernetes.io/name: grafana
type: Opaque
data:
  admin-user: $ub
  admin-password: $pb
EOF
  if [[ "$generated" -eq 1 ]]; then
    warn "generated a random Grafana admin password — store it now, it is not shown again:"
    warn "    user=$user  password=$pass"
    warn "  (set GRAFANA_ADMIN_PASSWORD in inventory.env to choose your own)"
  fi
}

# Grafana's public root_url: explicit GRAFANA_ROOT_URL wins; otherwise derive it
# from the publish host so it stays consistent with 70-grafana-tunnel.sh; if
# neither is set, use the localhost default (fine for direct NodePort access).
grafana_root_url() {
  if [[ -n "${GRAFANA_ROOT_URL:-}" ]]; then echo "$GRAFANA_ROOT_URL"; return; fi
  if [[ -n "${PUBLISH_HOST:-}" ]]; then echo "https://${PUBLISH_HOST}:${GRAFANA_HTTPS_PORT:-3443}/"; return; fi
  echo "http://localhost:3000/"
}

cmd_grafana() {
  ensure_grafana_secret
  install_dashboards
  # shellcheck disable=SC2016  # '${GRAFANA_ROOT_URL}' is the envsubst allowlist, not a bash expansion
  GRAFANA_ROOT_URL="$(grafana_root_url)" sapply_env 30-grafana.yaml '${GRAFANA_ROOT_URL}'
  wait_rollout deploy/grafana
}

# The dashboards are published with the resctrl-mon plugin, not written here, so
# the demo renders whatever that branch ships. Prefer the checkout
# telemetry/build-nri-image.sh already cloned; otherwise fetch the raw files.
DASH_PATH="deployment/helm/resctrl-mon/optional"
install_dashboards() {
  local src tmp url base rc=0
  src="${NRI_SRC:-$TELEMETRY_DIR/.src/nri-plugins}"
  tmp="$(mktemp -d)"
  base="${NRI_REPO:-https://github.com/cmcantalupo/nri-plugins.git}"
  base="${base%.git}"; base="${base/github.com/raw.githubusercontent.com}"

  local -A files=(
    [pod-energy.json]=grafana-resctrl-pod-energy.json
    [pod-perf.json]=grafana-resctrl-perf-counters.json
  )
  local key up
  for key in "${!files[@]}"; do
    up="${files[$key]}"
    if [[ -f "$src/$DASH_PATH/$up" ]]; then
      cp "$src/$DASH_PATH/$up" "$tmp/$key"
    else
      url="$base/${NRI_BRANCH:-resctrl-mon-goresctrl}/$DASH_PATH/$up"
      log "fetch dashboard $up"
      curl -fsSL "$url" -o "$tmp/$key" || rc=1
    fi
    [[ -s "$tmp/$key" ]] || rc=1
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp/$key" 2>/dev/null || rc=1
    [[ "$rc" -eq 0 ]] || { rm -rf "$tmp"; die "could not obtain a valid dashboard for $key (looked in $src/$DASH_PATH, then $base)"; }
  done

  log "install plugin dashboards (pod-energy, pod-perf)"
  local cm
  for cm in pod-energy:grafana-dashboard-pod-energy pod-perf:grafana-dashboard-pod-perf; do
    key="${cm%%:*}.json"
    python3 - "$tmp/$key" "$key" "${cm##*:}" "$NS" <<'PY' |
import sys
# Emitted by hand as a literal block rather than with PyYAML, which is not in
# the standard library and would be an undeclared prerequisite.
path, key, name, ns = sys.argv[1:5]
print("apiVersion: v1")
print("kind: ConfigMap")
print("metadata:")
print(f"  name: {name}")
print(f"  namespace: {ns}")
print("  labels:")
print("    app.kubernetes.io/name: grafana")
print("data:")
print(f"  {key}: |")
for line in open(path).read().splitlines():
    print("    " + line if line else "")
PY
      nssh "$(server_node)" "sudo k3s kubectl apply -f -" >/dev/null
  done
  rm -rf "$tmp"
  # ConfigMap edits do not restart the pod; Grafana's file provider rescans, but
  # restart when one already exists so the new dashboards appear immediately.
  skubectl "-n $NS rollout restart deploy/grafana" >/dev/null 2>&1 || true
}

cmd_dt1() {
  cmd_ns
  cmd_ksm
  cmd_prometheus
  cmd_grafana
  log "dt1 done — Prometheus NodePort 30090, Grafana NodePort 30030"
}

# ---- dt2. OTLP sink + per-node DaemonSets --------------------------------------
# otel-collector-resctrl is a single-replica Deployment (stable OTLP endpoint);
# rapl-node-exporter and nri-resctrl-mon are per-node DaemonSets.
cmd_otel() { sapply 40-otel-collector-resctrl.yaml; wait_rollout deploy/otel-collector-resctrl; }
cmd_rapl() { sapply 50-rapl-node-exporter.yaml; wait_rollout ds/rapl-node-exporter; }
cmd_nri()  {
  sapply 60-nri-resctrl-mon.yaml
  # The image is a fixed local tag with IfNotPresent, so re-applying an unchanged
  # manifest does not recreate Pods after a rebuild/import — the old image keeps
  # running. Force a rollout so the freshly imported image is actually picked up.
  skubectl "-n $NS rollout restart ds/nri-resctrl-mon" >/dev/null 2>&1 || true
  wait_rollout ds/nri-resctrl-mon
}

cmd_dt2() {
  cmd_otel
  cmd_rapl
  cmd_nri
  log "dt2 done — otel-collector-resctrl, rapl-node-exporter, nri-resctrl-mon"
}

# ---- opt-in: baseline NetworkPolicies -----------------------------------------
# default-deny-ingress + allow-rules for the scrape/serve graph (M-1/L-4). NOT
# part of dt1/dt2: apply explicitly and validate on the live cluster first, as
# NodePort SNAT and kubelet-probe handling depend on the CNI (see the manifest
# header). Safe to re-run; remove with `netpol-down`.
cmd_netpol()      { sapply 65-networkpolicies.yaml; }
cmd_netpol_down() { skubectl "-n $NS delete -f - --ignore-not-found" < "$TELEMETRY_DIR/65-networkpolicies.yaml" 2>/dev/null || \
  nssh "$(server_node)" "sudo k3s kubectl -n $NS delete -f - --ignore-not-found" < "$TELEMETRY_DIR/65-networkpolicies.yaml"; }

# ---- status / verify ----------------------------------------------------------
cmd_status() {
  skubectl "-n $NS get pods -o wide"
  echo
  skubectl "-n $NS get svc"
  echo
  skubectl "-n $NS get ds,deploy"
}

# Query the in-cluster Prometheus (via kubectl exec) for an instant vector.
promq() {  # promq <expr>
  # URL-encode: UTF-8 selectors carry {}, quotes and spaces, which would
  # otherwise be mangled between the shell, wget and the Prometheus API.
  local u
  u=$(python3 -c "import urllib.parse,sys;print('http://localhost:9090/api/v1/query?query='+urllib.parse.quote(sys.argv[1]))" "$1")
  skubectl "-n $NS exec deploy/prometheus -c prometheus -- wget -qO- '$u'"
}

# Extract the scalar value of a `count(...)` instant query from Prometheus JSON.
# Prints the integer count (0 when count() matched an empty set and returned no
# vector element); prints nothing when the response was not a success vector.
prom_scalar() {  # prom_scalar <prometheus-json>
  PROM_JSON="$1" python3 - <<'PY'
import json, os, sys
try:
    d = json.loads(os.environ.get("PROM_JSON", ""))
except Exception:
    sys.exit(0)
if d.get("status") != "success":
    sys.exit(0)
res = d.get("data", {}).get("result", [])
if not res:
    print(0)
else:
    try:
        print(int(float(res[0]["value"][1])))
    except Exception:
        sys.exit(0)
PY
}

# Run a `count(...)` query and require at least one series. Returns nonzero (and
# warns) when the query failed or reported zero series.
check_series() {  # check_series <label> <promql-count-expr>
  local label="$1" expr="$2" json n
  log "$label:"
  json="$(promq "$expr" 2>/dev/null)" || json=""
  n="$(prom_scalar "$json")"
  if [[ -z "$n" ]]; then
    warn "  $label: query failed or returned no result"
    return 1
  fi
  echo "  count=$n"
  if [[ "$n" -lt 1 ]]; then
    warn "  $label: zero series present"
    return 1
  fi
  return 0
}

cmd_verify() {
  local rc=0

  log "active Prometheus targets:"
  local targets up down
  targets="$(skubectl "-n $NS exec deploy/prometheus -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/targets?state=active'" 2>/dev/null)" || targets=""
  if [[ -z "$targets" ]]; then
    warn "targets query failed"
    rc=1
  else
    printf '%s' "$targets" | tr ',' '\n' | grep -E '"job"|"health"' | sed 's/^/  /'
    # grep exits 1 on the healthy no-match case; `|| true` keeps pipefail/set -e
    # from aborting before the explicit zero checks below decide the result.
    up="$(printf '%s' "$targets" | grep -o '"health":"up"' | wc -l | tr -d ' ' || true)"
    down="$(printf '%s' "$targets" | grep -oE '"health":"(down|unknown)"' | wc -l | tr -d ' ' || true)"
    echo "  -> up=$up down=$down"
    if [[ "$up" -eq 0 ]]; then warn "no Prometheus targets are up"; rc=1; fi
    if [[ "$down" -gt 0 ]]; then warn "$down Prometheus target(s) are down"; rc=1; fi
  fi
  echo

  check_series 'kube_pod_info'                       'count(kube_pod_info)'                               || rc=1
  echo
  check_series 'per-pod AET (perf.core.energy_joules_total)' \
                                                     'count({__name__="perf.core.energy_joules_total"})' || rc=1
  echo
  check_series 'per-node RAPL (node_rapl_package_joules_total)' \
                                                     'count(node_rapl_package_joules_total)'              || rc=1

  echo
  [[ "$rc" -eq 0 ]] && log "verify PASSED" || die "verify FAILED — required targets or series are missing (see warnings above)"
}

case "${1:-}" in
  ns)         cmd_ns ;;
  ksm)        cmd_ksm ;;
  prometheus) cmd_prometheus ;;
  grafana)    cmd_grafana ;;
  dt1)        cmd_dt1 ;;
  otel)       cmd_otel ;;
  rapl)       cmd_rapl ;;
  nri)        cmd_nri ;;
  dt2)        cmd_dt2 ;;
  netpol)     cmd_netpol ;;
  netpol-down) cmd_netpol_down ;;
  status)     cmd_status ;;
  verify)     cmd_verify ;;
  *) echo "usage: $0 {ns|ksm|prometheus|grafana|dt1|otel|rapl|nri|dt2|netpol|netpol-down|status|verify}" >&2; exit 2 ;;
esac
