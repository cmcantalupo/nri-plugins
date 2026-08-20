#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/30-k3s-up.sh — Stand up a single-node k3s cluster on the demo's
# Intel Xeon 6+ instance: OS prereqs, a k3s server (which also runs workloads),
# NRI enabled, and the AET node label applied.
#
# Run from a host with SSH access to the node (your workstation). k3s
# auto-detects the node IP, so no overlay or flannel pinning is required.
#
#   ./30-k3s-up.sh up          # prereqs -> server -> nri -> labels
#   ./30-k3s-up.sh prereqs     # C-T1 only
#   ./30-k3s-up.sh nri         # C-T4 only (idempotent; restarts k3s if running)
#   ./30-k3s-up.sh server      # C-T2 only
#   ./30-k3s-up.sh labels      # C-T5 only
#   ./30-k3s-up.sh status      # kubectl get nodes -o wide (via the server)
#   ./30-k3s-up.sh kubeconfig  # fetch kubeconfig to $RUNDIR, server -> reachable IP
#
# The node's /etc/rancher/k3s/k3s.yaml holds cluster-admin credentials and is
# created mode 600 (root-only). Remote kubectl never reads that file directly:
# the `kubeconfig` subcommand fetches a copy into $RUNDIR (also 600) with the
# API server rewritten to the node's reachable IP.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_inventory

RUNDIR="${AET_RUNDIR:-$HOME/.aet-toolkit}"
mkdir -p "$RUNDIR"

AET_LABEL="${AET_LABEL:-energy.intel.com/aet=true}"

# k3s kubectl on the server node (reachable via SSH).
skubectl() { local srv; srv="$(server_node)"; nssh "$srv" "sudo k3s kubectl $*"; }

# Wait until the k3s node reports Ready (API up). Used after the initial install
# and after an NRI-triggered k3s restart, before the API is touched again.
wait_node_ready() {
  local srv="$1" i
  for i in $(seq 1 60); do
    skubectl "get node $srv --no-headers 2>/dev/null" | grep -q ' Ready ' && return 0
    sleep 5
  done
  return 1
}

# ---- C-T1. OS prerequisites ---------------------------------------------------
cmd_prereqs() {
  local n
  for n in "${NODES[@]}"; do
    log "C-T1 prereqs on $n"
    nssh "$n" 'sudo bash -s' <<'EOF'
set -e
swapoff -a || true
sed -i.bak '/\bswap\b/s/^/#/' /etc/fstab 2>/dev/null || true
modprobe overlay || true
modprobe br_netfilter || true
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
cat > /etc/sysctl.d/99-k8s.conf <<SYS
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYS
sysctl --system >/dev/null
systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet systemd-timesyncd 2>/dev/null || true
echo "  swap=$(swapon --show=NAME --noheadings | wc -l) modules=$(lsmod | grep -cE '^(overlay|br_netfilter) ') bridge_nf=$(sysctl -n net.bridge.bridge-nf-call-iptables)"
EOF
  done
}

# ---- C-T4. Enable NRI in k3s's containerd -------------------------------------
# Merge onto k3s's generated base (via {{ template "base" . }}) so the default
# runtime config is preserved; only add the NRI block. Restart k3s if running.
cmd_nri() {
  local n
  for n in "${NODES[@]}"; do
    log "C-T4 enable NRI on $n"
    nssh "$n" 'sudo bash -s' <<'EOF'
set -e
d=/var/lib/rancher/k3s/agent/etc/containerd
mkdir -p "$d"
cat > "$d/config.toml.tmpl" <<'TOML'
{{ template "base" . }}

[plugins."io.containerd.nri.v1.nri"]
  disable = false
  disable_connections = false
  plugin_registration_timeout = "5s"
  plugin_request_timeout = "2s"
  socket_path = "/var/run/nri/nri.sock"
TOML
if systemctl is-active --quiet k3s; then svc=k3s
elif systemctl is-active --quiet k3s-agent; then svc=k3s-agent
else echo "  k3s not running yet — NRI applies on next start"; exit 0
fi
systemctl restart "$svc"
# containerd re-renders config.toml.tmpl on restart; wait for the NRI socket so
# callers (e.g. `up`) don't race a half-restarted runtime before labelling.
for _ in $(seq 1 30); do [ -S /var/run/nri/nri.sock ] && break; sleep 2; done
if [ -S /var/run/nri/nri.sock ]; then
  echo "  nri.sock=present"
else
  echo "  nri.sock=pending — containerd did not expose /var/run/nri/nri.sock after restart (NRI config rejected?)" >&2
  exit 1
fi
EOF
  done
}

# ---- C-T2. k3s server on the node ---------------------------------------------
cmd_server() {
  local srv k3s_ver
  srv="$(server_node)"
  k3s_ver="${INSTALL_K3S_VERSION:-v1.36.2+k3s1}"
  log "C-T2 install k3s server on $srv (auto-detected node IP), k3s $k3s_ver"
  # --node-name pins a stable name: the cloud image often ships a generic
  # hostname (e.g. "ubuntu"). k3s auto-detects the node/advertise IP.
  # write-kubeconfig-mode 600 keeps the cluster-admin kubeconfig root-only on
  # the node (the k3s default); the `kubeconfig` subcommand fetches a copy.
  #
  # Download the installer to a temp file and execute it (rather than piping
  # `curl | sh` blind) so it is inspectable/logged. Pinning INSTALL_K3S_VERSION
  # makes the fetched k3s binary deterministic; the official installer then
  # sha256-verifies that binary against the release checksum file it retrieves
  # over TLS. Set INSTALL_K3S_VERSION in inventory.env to a release you tested.
  nssh "$srv" "tmp=\$(mktemp) && \
    curl -fsSL https://get.k3s.io -o \"\$tmp\" && \
    INSTALL_K3S_VERSION='$k3s_ver' \
    INSTALL_K3S_EXEC='server --node-name $srv --write-kubeconfig-mode 600' \
    sh \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc"
  log "waiting for $srv to be Ready"
  wait_node_ready "$srv" && { log "$srv Ready"; return 0; }
  die "server $srv did not become Ready in time"
}

# ---- C-T5. AET node label -----------------------------------------------------
cmd_labels() {
  local n
  for n in "${NODES[@]}"; do
    log "C-T5 label $n ($AET_LABEL)"
    skubectl "label node $n $AET_LABEL --overwrite"
  done
}

cmd_status() {
  log "kubectl get nodes -o wide (via $(server_node))"
  skubectl "get nodes -o wide" || warn "server not up yet"
}

# Fetch kubeconfig to $RUNDIR with the API server rewritten to the node's
# reachable IP, so remote kubectl works from a host that can reach the node.
cmd_kubeconfig() {
  local srv sip out
  srv="$(server_node)"; sip="$(node_cluster_ip "$srv")"
  out="$RUNDIR/kubeconfig-${srv}.yaml"
  nssh "$srv" 'sudo cat /etc/rancher/k3s/k3s.yaml' \
    | sed "s#https://127.0.0.1:6443#https://$sip:6443#" > "$out"
  chmod 600 "$out"
  log "wrote $out (server https://$sip:6443)"
  log "use: KUBECONFIG=$out kubectl get nodes -o wide"
}

cmd_up() {
  cmd_prereqs
  # NRI must be enabled AFTER k3s is installed: cmd_nri restarts k3s to apply
  # the containerd template, which only takes effect once the runtime exists.
  cmd_server
  cmd_nri
  local srv; srv="$(server_node)"
  wait_node_ready "$srv" || die "$srv not Ready after enabling NRI"
  cmd_labels
  cmd_status
}

case "${1:-}" in
  prereqs)    cmd_prereqs ;;
  nri)        cmd_nri ;;
  server)     cmd_server ;;
  labels)     cmd_labels ;;
  status)     cmd_status ;;
  kubeconfig) cmd_kubeconfig ;;
  up)         cmd_up ;;
  *) echo "usage: $0 {up|prereqs|nri|server|labels|status|kubeconfig}" >&2; exit 2 ;;
esac
