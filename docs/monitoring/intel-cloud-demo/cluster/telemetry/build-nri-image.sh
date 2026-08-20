#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/telemetry/build-nri-image.sh — build the nri-resctrl-mon image and
# import it into k3s containerd on every node.
#
# The AET per-Pod RMID plugin (nri-resctrl-mon) depends on the resctrl monitor
# library and OTel collector in goresctrl. Neither is upstream yet, so the image
# is built from public forks/branches (defaults below, overridable in
# inventory.env). Once a published image exists on a registry (e.g. ghcr.io) you
# can skip this script entirely and just set the image in 60-nri-resctrl-mon.yaml.
#
#   nri-plugins  -> NRI_REPO @ NRI_BRANCH             (the nri-resctrl-mon plugin)
#   goresctrl    -> GORESCTRL_REPO @ GORESCTRL_BRANCH (pkg/monitor + OTel export)
#
# The forks are cloned on demand into a cache dir; set NRI_SRC / GORESCTRL_SRC to
# existing checkouts to build from local trees instead (no clone, current HEAD).
#
# The plugin pins goresctrl with a `replace` in nri-plugins/go.mod. When that
# replace is a remote module (=> github.com/<user>/goresctrl vX...), the go.mod
# is self-contained and the image builds straight from it (go fetches the pinned
# commit). Only when the replace is an unreachable local path (=> /abs or ./rel),
# or GORESCTRL_SRC points at a local checkout, do we vendor the goresctrl tree
# into the build context as ./_goresctrl-fork and rewrite the replace to it. The
# image is built here (where Go-proxy access exists), exported, and imported into
# containerd on each node (which persists it across reboots).
#
#   ./build-nri-image.sh            # clone/refresh + build + save + import on all nodes
#   ./build-nri-image.sh build      # clone/refresh + build + save only (no import)
#   ./build-nri-image.sh import     # import a previously-saved tar on all nodes
#
# Env overrides: NRI_REPO, NRI_BRANCH, GORESCTRL_REPO, GORESCTRL_BRANCH,
# NRI_SRC, GORESCTRL_SRC, SRC_CACHE, IMAGE, TAR, NODES (space list; defaults
# from cluster/inventory.env).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib.sh
source "$HERE/../lib.sh"

# Capture an explicit NODES override before load_inventory sources inventory.env
# (which would otherwise overwrite it with the inventory's own NODES array).
NODES_OVERRIDE="${NODES:-}"

# Populate inventory-provided defaults (NRI_REPO/BRANCH, GORESCTRL_REPO/BRANCH,
# and any NRI_SRC/GORESCTRL_SRC overrides) unless the caller already exported
# them. load_inventory also fills the NODES array.
load_inventory

NRI_REPO="${NRI_REPO:-https://github.com/cmcantalupo/nri-plugins.git}"
NRI_BRANCH="${NRI_BRANCH:-resctrl-mon-goresctrl}"
GORESCTRL_REPO="${GORESCTRL_REPO:-https://github.com/cmcantalupo/goresctrl.git}"
GORESCTRL_BRANCH="${GORESCTRL_BRANCH:-resctrl-mon}"
IMAGE="${IMAGE:-localhost/nri-resctrl-mon:aet}"
TAR="${TAR:-nri-resctrl-mon-aet.tar}"
STAGE_DIR="${STAGE_DIR:-$HERE/images}"
SRC_CACHE="${SRC_CACHE:-$HERE/.src}"

# Source trees: use an explicit NRI_SRC/GORESCTRL_SRC checkout if given,
# otherwise clone/refresh the fork branch into the cache dir.
NRI_SRC="${NRI_SRC:-$SRC_CACHE/nri-plugins}"
GORESCTRL_SRC="${GORESCTRL_SRC:-$SRC_CACHE/goresctrl}"

# Node list: honour an explicit NODES override, else use the inventory array.
if [[ -n "$NODES_OVERRIDE" ]]; then
  read -r -a NODES <<< "$NODES_OVERRIDE"
fi

# sync_fork <src_dir> <repo_url> <branch>: clone the branch if <src_dir> is
# absent, else fetch + hard-reset it to the fork branch tip. Skipped entirely
# when the operator points *_SRC at an existing checkout of their own.
sync_fork() {
  local dir="$1" repo="$2" branch="$3"
  if [[ -e "$dir/.git" ]]; then
    log "refresh $(basename "$dir") <- $repo @ $branch"
    # Re-point origin at the requested repo: a cached checkout may have been
    # fetched from a different NRI_REPO/GORESCTRL_REPO, and fetching the stale
    # origin would build the wrong source while the OCI labels claim this one.
    git -C "$dir" remote set-url origin "$repo"
    git -C "$dir" fetch --depth 1 origin "$branch"
    git -C "$dir" checkout -q -B "$branch" FETCH_HEAD
  else
    log "clone $repo @ $branch -> $dir"
    mkdir -p "$(dirname "$dir")"
    git clone --depth 1 --branch "$branch" "$repo" "$dir"
  fi
}

# Describe a checkout's revision for provenance: the HEAD sha, suffixed `-dirty`
# when the working tree has uncommitted or untracked changes. rsync copies the
# working tree (not HEAD) into the build context, so a user-supplied local
# checkout that has been edited must not be stamped as its clean HEAD commit.
git_rev() {
  local dir="$1" sha
  sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || { echo unknown; return; }
  [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]] && sha="$sha-dirty"
  echo "$sha"
}

cmd_build() {
  # Host git clones don't use Docker's daemon/client proxy config; export the
  # inventory proxy so the fork fetches work behind one (no-op if PROXY_URL is
  # unset, e.g. an Intel Cloud build host with direct egress).
  apply_host_proxy
  # nri-plugins is always vendored into the build context; clone/refresh it when
  # we own the checkout, else leave a user-supplied NRI_SRC on its current HEAD.
  [[ "$NRI_SRC" == "$SRC_CACHE/nri-plugins" ]] && sync_fork "$NRI_SRC" "$NRI_REPO" "$NRI_BRANCH"
  [[ -f "$NRI_SRC/go.mod" ]] || die "nri-plugins not found: $NRI_SRC (set NRI_SRC or NRI_REPO/NRI_BRANCH)"

  # Decide whether goresctrl must be vendored into the build context. The plugin
  # pins goresctrl with a `replace` in go.mod. When that replace is a *remote*
  # module (=> github.com/<user>/goresctrl vX.Y.Z-...) the go.mod is already
  # self-contained: `go build` fetches the pinned commit, so no local copy or
  # rewrite is needed. We only vendor when the replace is an unreachable local
  # path (=> /abs or ./rel, invisible to a Docker build) or when the operator
  # points GORESCTRL_SRC at their own checkout to iterate on goresctrl locally.
  local gores_replace gores_target vendor_goresctrl=0
  gores_replace="$(grep -E 'goresctrl[^=]*=>' "$NRI_SRC/go.mod" | sed -E 's#.*=> *##' | head -1)"
  gores_target="${gores_replace%% *}"
  if [[ "$GORESCTRL_SRC" != "$SRC_CACHE/goresctrl" ]]; then
    vendor_goresctrl=1
  elif [[ "$gores_target" == /* || "$gores_target" == ./* || "$gores_target" == ../* ]]; then
    vendor_goresctrl=1
  fi

  # Record the source each fork was built from so the locally imported image (no
  # registry digest to pin) stays traceable. Stamped as OCI labels + provenance.
  local nri_sha goresctrl_sha goresctrl_source
  nri_sha="$(git_rev "$NRI_SRC")"
  log "nri-plugins  @ $nri_sha ($NRI_REPO @ $NRI_BRANCH)"

  local stage; stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN
  log "staging build context in $stage"
  rsync -a --exclude '.git' --exclude 'build/' --exclude 'vendor/' "$NRI_SRC"/ "$stage"/

  if [[ "$vendor_goresctrl" == 1 ]]; then
    # Provide goresctrl in-context and repoint the replace at it.
    [[ "$GORESCTRL_SRC" == "$SRC_CACHE/goresctrl" ]] && sync_fork "$GORESCTRL_SRC" "$GORESCTRL_REPO" "$GORESCTRL_BRANCH"
    [[ -d "$GORESCTRL_SRC/pkg" ]] || die "goresctrl source not found: $GORESCTRL_SRC (set GORESCTRL_SRC or GORESCTRL_REPO/GORESCTRL_BRANCH)"
    goresctrl_sha="$(git_rev "$GORESCTRL_SRC")"
    goresctrl_source="$GORESCTRL_REPO@$GORESCTRL_BRANCH (vendored ./_goresctrl-fork)"
    log "goresctrl    @ $goresctrl_sha $goresctrl_source"
    rsync -a --exclude '.git' "$GORESCTRL_SRC"/ "$stage"/_goresctrl-fork/
    # Repoint the goresctrl replace at the in-context copy. Restrict to the
    # goresctrl replace line and swap its whole RHS, so a local path OR a remote
    # fork pin (=> github.com/<user>/goresctrl vX...) both land on the copy.
    sed -i -E '/goresctrl[^=]*=>/ s#=>.*#=> ./_goresctrl-fork#' "$stage/go.mod"
    grep -q '=> ./_goresctrl-fork' "$stage/go.mod" \
      || die "no goresctrl replace to repoint in $NRI_SRC/go.mod (add one, or unset GORESCTRL_SRC)"
  else
    # go.mod already pins a fetchable goresctrl module; build straight from it.
    goresctrl_source="${gores_replace:-<none> (goresctrl unmodified)}"
    goresctrl_sha="${gores_replace##*-}"
    [[ "$gores_replace" == *-* ]] || goresctrl_sha="unknown"
    log "goresctrl    <- go.mod replace: $goresctrl_source"
  fi

  cat > "$stage/Dockerfile.aet" <<'DOCKER'
ARG GO_VERSION=1.26
FROM golang:${GO_VERSION}-bookworm AS builder
WORKDIR /go/builder
COPY . .
RUN make PLUGINS=nri-resctrl-mon OTHER_IMAGE_TARGETS="" BINARIES="" build-plugins-static

FROM gcr.io/distroless/static
ARG NRI_SOURCE=unknown
ARG NRI_REVISION=unknown
ARG GORESCTRL_SOURCE=unknown
ARG GORESCTRL_REVISION=unknown
LABEL org.opencontainers.image.title="nri-resctrl-mon" \
      org.opencontainers.image.source="${NRI_SOURCE}" \
      org.opencontainers.image.revision="${NRI_REVISION}" \
      com.intel.aet.goresctrl.source="${GORESCTRL_SOURCE}" \
      com.intel.aet.goresctrl.revision="${GORESCTRL_REVISION}"
COPY --from=builder /go/builder/build/bin/nri-resctrl-mon /bin/nri-resctrl-mon
COPY --from=builder /go/builder/sample-configs/nri-resctrl-mon.yaml /etc/nri/resctrl-mon/config.yaml
ENTRYPOINT ["/bin/nri-resctrl-mon", "-idx", "90", "-config", "/etc/nri/resctrl-mon/config.yaml"]
DOCKER

  log "docker build -> $IMAGE"
  docker build -t "$IMAGE" -f "$stage/Dockerfile.aet" \
    --build-arg "NRI_SOURCE=$NRI_REPO@$NRI_BRANCH" \
    --build-arg "NRI_REVISION=$nri_sha" \
    --build-arg "GORESCTRL_SOURCE=$goresctrl_source" \
    --build-arg "GORESCTRL_REVISION=$goresctrl_sha" \
    "$stage"

  mkdir -p "$STAGE_DIR"
  # Provenance sidecar: which fork commits produced this tar.
  cat > "$STAGE_DIR/${TAR%.tar}.provenance" <<PROV
image=$IMAGE
nri_source=$NRI_REPO@$NRI_BRANCH
nri_revision=$nri_sha
goresctrl_source=$goresctrl_source
goresctrl_revision=$goresctrl_sha
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROV
  log "wrote provenance -> $STAGE_DIR/${TAR%.tar}.provenance"
  log "docker save -> $STAGE_DIR/$TAR"
  docker save "$IMAGE" -o "$STAGE_DIR/$TAR"
}

cmd_import() {
  [[ -f "$STAGE_DIR/$TAR" ]] || die "image tar not found: $STAGE_DIR/$TAR (run build first)"
  local n
  for n in "${NODES[@]}"; do
    log "ship + import into containerd on $n"
    scp $SSH_OPTS -q "$STAGE_DIR/$TAR" "$n:/tmp/$TAR"
    nssh "$n" "sudo k3s ctr images import /tmp/$TAR && sudo rm -f /tmp/$TAR"
  done
  log "import complete on: ${NODES[*]}"
}

case "${1:-all}" in
  build)  cmd_build ;;
  import) cmd_import ;;
  all)    cmd_build; cmd_import ;;
  *) echo "usage: $0 {build|import|all}" >&2; exit 2 ;;
esac
