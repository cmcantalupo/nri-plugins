# `cluster/` — the AET cluster toolkit

An inventory-driven set of Bash scripts that take a fresh allocation of a single
Intel® Xeon 6+ node and turn it into a k3s cluster that measures **per-Pod
energy** with Intel® Application Energy Telemetry (AET) and visualizes it in
Grafana.

You describe the allocation once in `inventory.env`; the numbered scripts do the
rest. Every step is idempotent and can also be run by hand.

## Quick start

```bash
cp inventory.env.example inventory.env   # then edit for your allocation
./00-probe.sh                            # read-only: what does the node look like?
./20-kernel-build.sh all                 # build the AET kernel (Docker; see ../kernel)
./21-kernel-install.sh ship install      # copy the package + install (SSH-safe; default stays stock)
# One-shot boot into the AET kernel, confirm the counters, THEN promote it as the
# default. These reboot the node (ALLOW_REBOOT=1) and must all finish before k3s:
ALLOW_REBOOT=1 ./21-kernel-install.sh oneshot <node>   # one-shot boot into the AET kernel
ssh <node> sudo bash -s < ./aet-check.sh                # confirm the running kernel exposes AET counters (runs on the node)
ALLOW_REBOOT=1 ./21-kernel-install.sh promote <node>   # make it the default (only after a healthy oneshot)
./30-k3s-up.sh up                        # stand up k3s (NRI enabled, node labelled)
./40-deploy-telemetry.sh dt1             # namespace + kube-state-metrics + Prometheus + Grafana
./telemetry/build-nri-image.sh           # build + import the local-only nri-resctrl-mon image (before dt2)
./40-deploy-telemetry.sh dt2             # otel-collector-resctrl + rapl-node-exporter + nri-resctrl-mon
./60-validate.sh snapshot                # per-node RAPL + AET power, live
./70-grafana-tunnel.sh local             # view Grafana at http://localhost:3000
```

> The `nri-resctrl-mon` image is not yet on a public registry, so it must be
> built and imported (the `build-nri-image.sh` step above, between `dt1` and
> `dt2`) before `dt2` deploys the plugin — otherwise the Pod lands in
> `ImagePullBackOff`. `telemetry/build-nri-image.sh` clones the plugin and its
> `goresctrl` dependency from the public forks named by `NRI_REPO`/`NRI_BRANCH`
> and `GORESCTRL_REPO`/`GORESCTRL_BRANCH` in `inventory.env` (or point
> `60-nri-resctrl-mon.yaml` at a published image).

## Scripts

| Script | Purpose |
|--------|---------|
| `lib.sh` | Shared helpers (inventory loader, `nssh`, node lookups). Sourced, not run. |
| `inventory.env.example` | Template describing the node, kernel, and Grafana publishing. |
| `00-probe.sh` | Read-only node capability/topology probe. |
| `20-kernel-build.sh` | Build the AET-enabled kernel `.deb`/`.rpm` (containerized, see `../kernel`). |
| `21-kernel-install.sh` | Install and promote the AET kernel on the node (SSH-safe, reversible). |
| `aet-check.sh` | Confirm the running kernel exposes AET resctrl counters. |
| `30-k3s-up.sh` | Install k3s with NRI enabled and label the AET node. |
| `40-deploy-telemetry.sh` | Apply the telemetry stack under `telemetry/`. |
| `60-validate.sh` | Query Prometheus for per-node RAPL + AET power / efficiency. |
| `70-grafana-tunnel.sh` | Publish Grafana over an SSH tunnel + TLS reverse proxy. |
| `telemetry/build-nri-image.sh` | Build the `nri-resctrl-mon` image and import it into each node. |

## The telemetry stack (`telemetry/`)

Applied by `40-deploy-telemetry.sh` into the `monitoring` namespace:

| Manifest | Component |
|----------|-----------|
| `00-namespace.yaml` | `monitoring` namespace |
| `10-kube-state-metrics.yaml` | Kubernetes object metrics (`kube_pod_info`, …) |
| `20-prometheus.yaml` | Prometheus (NodePort 30090) |
| `30-grafana.yaml` | Grafana + pre-provisioned dashboards (NodePort 30030) |
| `40-otel-collector-resctrl.yaml` | OTLP sink; renders per-Pod AET on `:8889` |
| `50-rapl-node-exporter.yaml` | Per-node RAPL package/DRAM energy + TDP cap |
| `60-nri-resctrl-mon.yaml` | NRI plugin: per-Pod resctrl `mon_group` + RMID |

Data flow: `nri-resctrl-mon` (per-Pod RMID) → `otel-collector-resctrl` (OTLP) →
Prometheus → Grafana, with `rapl-node-exporter` providing a per-node reference.

## Data model

The collector keeps the plugin's **dotted OTLP names**
(`translation_strategy: NoUTF8EscapingWithSuffixes`), so series are named
`perf.core.energy_joules_total` and carry `k8s.pod.uid` and
`resctrl.group.source="pod"`. These are UTF-8 names: they must be quoted inside
the selector, which requires **Prometheus 3.x**.

Join them to Pod/namespace/node with `kube_pod_info`, which is a native
Prometheus exporter and so carries a plain `uid` label:

```promql
sum by (pod, namespace) (
  rate({__name__="perf.core.energy_joules_total", "resctrl.group.source"="pod"}[$__rate_interval])
  * on("k8s.pod.uid") group_left(pod, namespace)
    label_replace(last_over_time(kube_pod_info[$__range]), "k8s.pod.uid", "$1", "uid", "(.+)")
)
```

The **Kubernetes Pod Energy (Intel AET / resctrl-mon)** and **Kubernetes Pod
Perf Counters (Intel AET / resctrl-mon)** dashboards use exactly this pattern.
They are not written here: `40-deploy-telemetry.sh` installs the dashboards
published with the plugin itself, from
`deployment/helm/resctrl-mon/optional/grafana-resctrl-*.json` on
`NRI_REPO@NRI_BRANCH`.

## Inventory

`inventory.env` is the single source of truth. Key fields:

- `NODES` — a one-element array naming the single node (the k3s server).
- Kernel build vars — where and how `20-kernel-build.sh` builds the AET kernel.
- Grafana publishing vars — `PUBLISH_HOST` and ports for `70-grafana-tunnel.sh`.

No secrets live in the inventory: only SSH aliases are referenced (keys stay in
`~/.ssh`).

## Pinned images (review quarterly)

Every telemetry image is pinned to an explicit tag. Review this table each
quarter and bump to the current patched releases; keep the tags below in sync
with the `image:` fields in `telemetry/*.yaml`.

_Last reviewed: 2026-08-14._

| Component | Image | Manifest |
|-----------|-------|----------|
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0` | `telemetry/10-kube-state-metrics.yaml` |
| Prometheus | `prom/prometheus:v3.13.2` | `telemetry/20-prometheus.yaml` |
| Grafana | `grafana/grafana:11.2.0` | `telemetry/30-grafana.yaml` |
| OTel Collector (contrib) | `otel/opentelemetry-collector-contrib:0.158.0` | `telemetry/40-otel-collector-resctrl.yaml` |
| node-exporter (RAPL) | `quay.io/prometheus/node-exporter:v1.8.2` | `telemetry/50-rapl-node-exporter.yaml` |
| busybox (init) | `docker.io/library/busybox:1.36` | `telemetry/50-rapl-node-exporter.yaml` |
| nri-resctrl-mon | `localhost/nri-resctrl-mon:aet` (built locally by `telemetry/build-nri-image.sh`) | `telemetry/60-nri-resctrl-mon.yaml` |
