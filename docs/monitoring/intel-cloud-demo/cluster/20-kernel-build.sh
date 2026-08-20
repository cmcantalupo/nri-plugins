#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/20-kernel-build.sh — build the AET .deb on the build host
# (KERNEL_BUILD_HOST, usually your workstation). Runs the containerized build
# system bundled under KERNEL_BUILD_DIR (../kernel), based on the *cloud node's
# own* running config (captured over SSH, not this build host's config) so the
# result keeps the drivers this cloud node needs to boot + reach the network.
#
# Source: by default (KERNEL_SOURCE=ubuntu) the build container rebuilds the
# node's own distro kernel from Ubuntu's `linux` source package, so Ubuntu's
# patches and LTS security updates are kept and only the AET config option is
# added. Set KERNEL_SOURCE=git to clone a mainline tree instead (KERNEL_REPO at
# KERNEL_BRANCH); on a firewalled build host, KERNEL_LOCAL_REPO points at a
# local clone which is served to the container over the docker bridge
# (read-only `git daemon`, no key, no egress).
#
# Package format: 'deb' (Debian/Ubuntu) or 'rpm' (RHEL/Rocky/Fedora), selected
# per the target node by KERNEL_PKG (deb|rpm|auto; auto = detect from the node,
# recorded as NODE_PKG on `capture`). An RPM node has no Ubuntu source package,
# so KERNEL_PKG=rpm requires KERNEL_SOURCE=git (a mainline tag that carries AET).
# The .deb build uses ubuntu-build.Docker; the .rpm build uses rocky-build.Docker.
#
# Run ON the build host:  cd cluster && ./20-kernel-build.sh all
#   capture       pull the server node's stock /boot/config (its live uname -r)
#   build         start the dockerized .deb build (detached)
#   build-status  tail the build log + show whether it is still running
#   build-wait    block until the detached build exits
#   verify        check the built .deb's embedded config for the required symbols
#   all           capture -> build -> build-wait -> verify
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_inventory

RUNDIR="${AET_RUNDIR:-$HOME/.aet-toolkit}"; mkdir -p "$RUNDIR"
BUILD_DIR="${KERNEL_BUILD_DIR:?}"; BUILD_DIR="${BUILD_DIR/#\~/$HOME}"
CONFIG_SRC="$BUILD_DIR/cwf-stock.config"
STOCK_ENV="$BUILD_DIR/cwf-stock.env"
BUILD_LOG="$RUNDIR/kernel-build.log"
BUILD_PID="$RUNDIR/kernel-build.pid"
DAEMON_PID="$RUNDIR/kernel-gitdaemon.pid"

on_build_host() { [[ -d "$BUILD_DIR" ]] && command -v docker >/dev/null; }
require_build_host() { on_build_host || die "run this on $KERNEL_BUILD_HOST ($BUILD_DIR + docker required)"; }

stock_env_get() {
  [[ -f "$STOCK_ENV" ]] || return 0
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$STOCK_ENV"
}

# ---- K-T1. Capture the node's stock kernel config -----------------------------
# The base config MUST come from the cloud node's own running image (the Intel
# Cloud Services offering), not this build host — the build host may be an older
# or unrelated OS. We detect the node's live kernel with `uname -r` rather than
# trusting the inventory STOCK_KERNEL, so the captured config always matches
# what the node actually boots (NIC/NVMe drivers, etc.). The same pass records
# the node's Ubuntu series and `linux` source version, which pin the build
# container's base image and the exact source package it rebuilds.
cmd_capture() {
  local srv running series vid srcver
  srv="$(server_node)"
  running="$(nssh "$srv" 'uname -r')"
  [[ -n "$running" ]] || die "could not read running kernel (uname -r) from $srv"
  if [[ -n "${STOCK_KERNEL:-}" && "$running" != "$STOCK_KERNEL" ]]; then
    warn "server $srv runs $running but inventory STOCK_KERNEL=$STOCK_KERNEL — capturing $running"
  fi
  log "K-T1 capture /boot/config-$running from $srv (the cloud node's running kernel)"
  nssh "$srv" "sudo cat /boot/config-$running" > "$CONFIG_SRC"
  [[ -s "$CONFIG_SRC" ]] || die "captured config is empty"
  log "wrote $CONFIG_SRC ($(wc -l < "$CONFIG_SRC") lines)"

  series="$(nssh "$srv" '. /etc/os-release && echo "${VERSION_CODENAME:-}"')"
  vid="$(nssh "$srv" '. /etc/os-release && echo "${VERSION_ID:-}"')"
  srcver="$(nssh "$srv" "dpkg-query -W -f='\${source:Version}' linux-image-$running 2>/dev/null || true")"
  local pkg; pkg="$(node_pkg_family "$srv")"
  { echo "STOCK_KERNEL=$running"
    echo "UBUNTU_SERIES=$series"
    echo "UBUNTU_VERSION_ID=$vid"
    echo "NODE_KERNEL_VERSION=$srcver"
    echo "NODE_PKG=$pkg"
  } > "$STOCK_ENV"
  log "node: ${series:+Ubuntu }${vid:-?} (${series:-?}), kernel $running, ${pkg}-based, linux source ${srcver:-unknown}"
  log "wrote $STOCK_ENV"
  # The archive keeps only the current linux source, so the node's own version is
  # recorded for reference; the build tracks the current (fully patched) one.
  log "record in inventory.env:  STOCK_KERNEL=$running"
}

# Serve KERNEL_LOCAL_REPO to the build container over the docker bridge, so the
# in-container `git clone` needs no network egress and no SSH key. Echoes the URL.
start_git_daemon() {
  local repo base name gw
  repo="${KERNEL_LOCAL_REPO/#\~/$HOME}"
  [[ -d "$repo/.git" || -d "$repo/objects" ]] || die "KERNEL_LOCAL_REPO not a git repo: $repo"
  base="$(dirname "$repo")"; name="$(basename "$repo")"
  gw="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo 172.17.0.1)"
  git daemon --reuseaddr --listen="$gw" --port=9418 \
    --base-path="$base" --export-all "$base/$name" >/dev/null 2>&1 &
  echo $! > "$DAEMON_PID"
  sleep 1
  kill -0 "$(cat "$DAEMON_PID")" 2>/dev/null || die "git daemon failed to start"
  echo "git://$gw:9418/$name"
}
stop_git_daemon() { [[ -f "$DAEMON_PID" ]] && { kill "$(cat "$DAEMON_PID")" 2>/dev/null || true; rm -f "$DAEMON_PID"; }; }

# ---- K-T2. Build the AET .deb (detached) --------------------------------------
cmd_build() {
  require_build_host
  [[ -s "$CONFIG_SRC" ]] || die "no $CONFIG_SRC — run: $0 capture"
  if [[ -f "$BUILD_PID" ]] && kill -0 "$(cat "$BUILD_PID")" 2>/dev/null; then
    die "a build is already running (pid $(cat "$BUILD_PID")); see: $0 build-status"
  fi
  local source="${KERNEL_SOURCE:-ubuntu}"
  local series vid srcver image repo_url="" branch=""
  # Package format: explicit KERNEL_PKG, else what capture detected (default deb).
  local pkg; pkg="${KERNEL_PKG:-auto}"
  if [[ "$pkg" == auto ]]; then pkg="$(stock_env_get NODE_PKG)"; pkg="${pkg:-deb}"; fi
  [[ "$pkg" == deb || "$pkg" == rpm ]] || die "KERNEL_PKG must be 'deb', 'rpm', or 'auto' (got '$pkg')"
  # A non-Ubuntu node has no Ubuntu `linux` source package to rebuild, so an RPM
  # build must come from a mainline tag that already carries the AET resctrl code.
  [[ "$pkg" == rpm && "$source" == ubuntu ]] && \
    die "KERNEL_PKG=rpm needs KERNEL_SOURCE=git (an RPM/non-Ubuntu node has no Ubuntu source to rebuild); set KERNEL_SOURCE=git + KERNEL_BRANCH to a tag with AET"
  # Inventory wins over what capture found, so a user can pin either explicitly.
  series="${UBUNTU_SERIES:-$(stock_env_get UBUNTU_SERIES)}"
  vid="${UBUNTU_VERSION_ID:-$(stock_env_get UBUNTU_VERSION_ID)}"
  # Only an explicit inventory pin; empty means "the archive's current version",
  # because Ubuntu keeps just the newest linux source (older ones are removed).
  srcver="${UBUNTU_KERNEL_VERSION:-}"
  image="${KERNEL_BUILD_IMAGE:-ubuntu:${vid:-26.04}}"

  case "$source" in
    ubuntu)
      if [[ -n "$srcver" ]]; then
        log "K-T2 build $KERNEL_TAG from pinned Ubuntu source linux=$srcver on $image"
      else
        local nodever; nodever="$(stock_env_get NODE_KERNEL_VERSION)"
        log "K-T2 build $KERNEL_TAG from Ubuntu's current linux source on $image (node runs ${nodever:-unknown})"
      fi
      ;;
    git)
      branch="${KERNEL_BRANCH:?}"
      if [[ -n "${KERNEL_LOCAL_REPO:-}" ]]; then
        repo_url="$(start_git_daemon)"; log "serving local tree at $repo_url"
      else
        repo_url="${KERNEL_REPO:?set KERNEL_LOCAL_REPO or a reachable KERNEL_REPO}"
      fi
      log "K-T2 build $KERNEL_TAG from $repo_url @ $branch (base $(basename "$CONFIG_SRC"))"
      ;;
    *) die "KERNEL_SOURCE must be 'ubuntu' or 'git' (got '$source')" ;;
  esac
  log "packaging as .$pkg (build image: $([[ "$pkg" == rpm ]] && echo rocky-build.Docker || echo "$image"))"
  # Detach: a plain nohup over ssh inherits the ssh stdout pipe and hangs it.
  setsid env \
    AET_HOST_CONFIG_SOURCE="$CONFIG_SRC" \
    AET_KERNEL_SOURCE="$source" \
    AET_UBUNTU_SERIES="$series" \
    AET_UBUNTU_KERNEL_VERSION="$srcver" \
    AET_UBUNTU_IMAGE="$image" \
    AET_KERNEL_REPO="$repo_url" \
    AET_KERNEL_BRANCH="$branch" \
    AET_KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:--aet}" \
    AET_SLIM_DEBUG="${KERNEL_SLIM_DEBUG:-0}" \
    bash -c "cd '$BUILD_DIR' && ./build.sh $pkg; rc=\$?; \
             kill \$(cat '$DAEMON_PID' 2>/dev/null) 2>/dev/null; \
             echo BUILD-EXIT=\$rc" \
    >"$BUILD_LOG" 2>&1 < /dev/null &
  echo $! > "$BUILD_PID"
  log "build started (pid $!), log=$BUILD_LOG — monitor: $0 build-status | build-wait"
}

cmd_build_status() {
  if [[ -f "$BUILD_PID" ]] && kill -0 "$(cat "$BUILD_PID")" 2>/dev/null; then
    echo "build: RUNNING (pid $(cat "$BUILD_PID"))"
  else
    echo "build: not running ($(grep -o 'BUILD-EXIT=[0-9]*' "$BUILD_LOG" 2>/dev/null | tail -1 || echo 'no exit marker'))"
  fi
  echo "-- tail $BUILD_LOG --"; tail -n "${TAIL:-20}" "$BUILD_LOG" 2>/dev/null || echo "  (no log yet)"
}

cmd_build_wait() {
  [[ -f "$BUILD_PID" ]] || die "no build pidfile; nothing to wait on"
  local p; p="$(cat "$BUILD_PID")"
  log "waiting for build pid $p ..."
  while kill -0 "$p" 2>/dev/null; do sleep 15; done
  # `|| true`: without the marker the pipeline fails and `set -e` would abort
  # here, losing the diagnostic below that says the build died.
  local rc; rc="$(grep -o 'BUILD-EXIT=[0-9]*' "$BUILD_LOG" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
  [[ "$rc" == "0" ]] && log "build finished OK" || { tail -n 30 "$BUILD_LOG"; die "build failed (exit ${rc:-?})"; }
}

# ---- verify the produced package ---------------------------------------------
cmd_verify() {
  require_build_host
  local pkg; pkg="${KERNEL_PKG:-auto}"
  if [[ "$pkg" == auto ]]; then pkg="$(stock_env_get NODE_PKG)"; pkg="${pkg:-deb}"; fi
  if [[ "$pkg" == rpm ]]; then verify_rpm; else verify_deb; fi
}

# Verify the built .deb embeds the required CONFIG_* symbols, kept the node's
# drivers, and matches KERNEL_TAG.
verify_deb() {
  local deb
  deb="$(ls -t "$BUILD_DIR"/build/deb/linux-image-*.deb 2>/dev/null | grep -v -- '-dbg_' | head -1)" \
    || die "no linux-image .deb in $BUILD_DIR/build/deb"
  [[ -n "$deb" ]] || die "no non-debug linux-image .deb in $BUILD_DIR/build/deb"
  log "verifying $(basename "$deb")"
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  ( cd "$tmp" && dpkg-deb --fsys-tarfile "$deb" | tar -xO --wildcards './boot/config-*' 2>/dev/null > cfg )
  [[ -s "$tmp/cfg" ]] || die "could not extract embedded config from $deb"
  local ok=1 sym
  for sym in \
    "CONFIG_X86_CPU_RESCTRL_INTEL_AET=y" \
    "CONFIG_CGROUP_BPF=y" \
    "CONFIG_INTEL_RAPL_TPMI=m"; do
    if grep -qx "$sym" "$tmp/cfg"; then echo "  OK   $sym"; else echo "  MISS $sym"; ok=0; fi
  done
  # Driver sanity vs the node's stock config (must not regress to =n).
  if [[ -s "$CONFIG_SRC" ]]; then
    for sym in CONFIG_E1000E CONFIG_IGB CONFIG_IXGBE CONFIG_I40E CONFIG_ICE CONFIG_NVME_CORE CONFIG_VIRTIO_NET; do
      local want; want="$(grep -E "^$sym=" "$CONFIG_SRC" || true)"
      [[ -z "$want" ]] && continue
      grep -qE "^$sym=(y|m)" "$tmp/cfg" && echo "  OK   $sym (driver kept)" || { echo "  MISS $sym (driver dropped!)"; ok=0; }
    done
  fi
  # A release string that disagrees with KERNEL_TAG makes 21-kernel-install pin
  # the wrong grub entry — which fails silently at boot rather than here.
  local release; release="$(basename "$deb")"; release="${release#linux-image-}"; release="${release%%_*}"
  if [[ -n "${KERNEL_TAG:-}" && "$release" != "$KERNEL_TAG" ]]; then
    echo "  MISS kernel release '$release' != inventory KERNEL_TAG '$KERNEL_TAG'"
    echo "       fix: set KERNEL_TAG=$release in inventory.env"
    ok=0
  else
    echo "  OK   kernel release $release matches KERNEL_TAG"
  fi
  # Record it so the release never has to be guessed: it follows the upstream
  # point release of whatever Ubuntu source was built, and moves with each SRU.
  if [[ -f "$STOCK_ENV" ]]; then
    sed -i '/^BUILT_KERNEL_TAG=/d' "$STOCK_ENV"
    echo "BUILT_KERNEL_TAG=$release" >> "$STOCK_ENV"
  fi

  local prov="$BUILD_DIR/build/deb/aet-build-provenance.txt" want
  if [[ -f "$prov" ]]; then
    log "provenance:"; sed 's/^/    /' "$prov"
    # Only an explicit inventory pin is enforceable; the unpinned build tracks
    # whatever the archive currently ships.
    want="${UBUNTU_KERNEL_VERSION:-}"
    if [[ -n "$want" ]] && grep -qx 'source-mode=ubuntu' "$prov" &&
       ! grep -qx "ubuntu-source-version=$want" "$prov"; then
      echo "  MISS built source version != pinned '$want'"; ok=0
    fi
  else
    warn "no provenance file next to the .deb"
  fi

  [[ "$ok" == "1" ]] && log "verify PASSED — $(basename "$deb")" || die "verify FAILED — do NOT install this .deb"
}

# Verify the built .rpm embeds the required CONFIG_* symbols, kept the node's
# drivers, and matches KERNEL_TAG. The in-container build already refuses a tree
# that does not define the AET symbol and re-asserts it after olddefconfig; this
# is the belt-and-suspenders check on the produced artifact.
verify_rpm() {
  local rpm
  # Exclude source RPMs (kernel-*.src.rpm): they are not bootable artifacts and
  # carry no /boot/config-* to verify. If the .src.rpm has the newest mtime it
  # would otherwise be picked here.
  rpm="$(ls -t "$BUILD_DIR"/build/rpm/kernel-*.rpm 2>/dev/null | grep -viE 'debuginfo|debug-|headers|devel|\.src\.rpm$' | head -1)" \
    || die "no kernel .rpm in $BUILD_DIR/build/rpm"
  [[ -n "$rpm" ]] || die "no kernel .rpm in $BUILD_DIR/build/rpm"
  log "verifying $(basename "$rpm")"
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  # Stream the embedded /boot/config out of the rpm. Prefer bsdtar (libarchive
  # reads rpm payloads directly, so the build host needs no rpm tooling); fall
  # back to rpm2cpio|cpio when present.
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xOf "$rpm" '*boot/config-*' 2>/dev/null > "$tmp/cfg" || true
  elif command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
    ( cd "$tmp" && rpm2cpio "$rpm" | cpio -idm --quiet 2>/dev/null ) || true
  fi
  local cfg="$tmp/cfg"
  if [[ ! -s "$cfg" ]]; then
    local found; found="$(ls "$tmp"/boot/config-* 2>/dev/null | head -1 || true)"
    [[ -n "$found" ]] && cfg="$found"
  fi

  local ok=1 sym release
  # Kernel release: the true `-aet` release from the embedded config name (the
  # rpm NVR mangles '-' to '_', so it is not a reliable source for KERNEL_TAG).
  release="$(bsdtar -tf "$rpm" 2>/dev/null | grep -m1 -oE 'boot/config-[^/]+' | sed 's#boot/config-##' || true)"
  if [[ -z "$release" && -f "$cfg" && "$(basename "$cfg")" == config-* ]]; then
    release="$(basename "$cfg" | sed 's/^config-//')"
  fi

  if [[ -s "$cfg" ]]; then
    for sym in \
      "CONFIG_X86_CPU_RESCTRL_INTEL_AET=y" \
      "CONFIG_CGROUP_BPF=y" \
      "CONFIG_INTEL_RAPL_TPMI=m"; do
      if grep -qx "$sym" "$cfg"; then echo "  OK   $sym"; else echo "  MISS $sym"; ok=0; fi
    done
    if [[ -s "$CONFIG_SRC" ]]; then
      for sym in CONFIG_E1000E CONFIG_IGB CONFIG_IXGBE CONFIG_I40E CONFIG_ICE CONFIG_NVME_CORE CONFIG_VIRTIO_NET; do
        local want; want="$(grep -E "^$sym=" "$CONFIG_SRC" || true)"
        [[ -z "$want" ]] && continue
        grep -qE "^$sym=(y|m)" "$cfg" && echo "  OK   $sym (driver kept)" || { echo "  MISS $sym (driver dropped!)"; ok=0; }
      done
    fi
  else
    # No embedded config means we verified nothing about the artifact — fail
    # rather than printing PASSED on an unchecked package.
    echo "  MISS could not extract the embedded /boot/config from the .rpm"
    echo "       install bsdtar (or rpm2cpio+cpio) on the build host so the AET config can be verified"
    ok=0
  fi

  # Release must match KERNEL_TAG so 21-kernel-install pins the right entry. An
  # empty release means we could not read the artifact's release at all, so the
  # comparison would be silently skipped — treat that as a failure too.
  if [[ -z "$release" ]]; then
    echo "  MISS could not determine the kernel release from the .rpm"
    ok=0
  elif [[ -n "${KERNEL_TAG:-}" && "$release" != "$KERNEL_TAG" ]]; then
    echo "  MISS kernel release '$release' != inventory KERNEL_TAG '$KERNEL_TAG'"
    echo "       fix: set KERNEL_TAG=$release in inventory.env"
    ok=0
  else
    echo "  OK   kernel release $release matches KERNEL_TAG"
  fi
  if [[ -f "$STOCK_ENV" && -n "$release" ]]; then
    sed -i '/^BUILT_KERNEL_TAG=/d' "$STOCK_ENV"
    echo "BUILT_KERNEL_TAG=$release" >> "$STOCK_ENV"
  fi

  local prov="$BUILD_DIR/build/rpm/aet-build-provenance.txt"
  if [[ -f "$prov" ]]; then log "provenance:"; sed 's/^/    /' "$prov"; else warn "no provenance file next to the .rpm"; fi

  [[ "$ok" == "1" ]] && log "verify PASSED — $(basename "$rpm")" || die "verify FAILED — do NOT install this .rpm"
}

cmd_all() { cmd_capture; cmd_build; cmd_build_wait; cmd_verify; }

case "${1:-}" in
  capture)      cmd_capture ;;
  build)        cmd_build ;;
  build-status) cmd_build_status ;;
  build-wait)   cmd_build_wait ;;
  verify)       cmd_verify ;;
  all)          cmd_all ;;
  *) echo "usage: $0 {all|capture|build|build-status|build-wait|verify}" >&2; exit 2 ;;
esac
