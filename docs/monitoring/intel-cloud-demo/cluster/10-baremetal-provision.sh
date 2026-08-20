#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/10-baremetal-provision.sh — ALTERNATE Stage 1 for PROVISION_MODE=baremetal.
#
# Re-image a self-managed bare-metal Clearwater Forest node you already have root
# on, IN PLACE, to a clean Ubuntu 26.04, and enable key-based SSH — without any
# BMC/PXE/USB. It kexecs the node's running OS straight into the Ubuntu 26.04
# live-server installer (subiquity), driven unattended by a NoCloud autoinstall
# seed served over HTTP from this workstation. The result (stock Ubuntu 26.04)
# is exactly what Stage 3 (20-kernel-build.sh) rebuilds with AET enabled, so the
# bare-metal and Intel Cloud paths converge here.
#
# WARNING: `reimage` (and `all`) ERASE the node's target disk and take it fully
# offline. They are gated behind ALLOW_REIMAGE=1 and require a confirmed
# out-of-band console/BMC/KVM recovery path. Secure Boot must be OFF (the AET
# kernel is unsigned); autoinstall cannot toggle it.
#
# Storage (REIMAGE_STORAGE in inventory.env):
#   direct (default) wipes the WHOLE target disk (destroys every OS on it).
#   reuse            keeps every other partition (e.g. a Windows dual-boot and a
#                    shared ESP) and reformats ONLY REIMAGE_BOOT_PART (/boot) and
#                    REIMAGE_ROOT_PART (/); the ESP is mounted, never reformatted.
#
# Run from your workstation (direct SSH to the node — no jump host):
#   cd cluster && ./10-baremetal-provision.sh <subcommand>
#     capture      read the live node's disk + network identity (read-only)
#     status       report OS / kernel / reachability / key access (read-only)
#     fetch        download + verify the ISO, extract casper vmlinuz/initrd
#     seed         render the NoCloud autoinstall user-data + meta-data
#     serve        serve the ISO + seed over HTTP (background); serve-stop
#     reimage      kexec the node into the installer      (needs ALLOW_REIMAGE=1)
#     wait         block until the node returns as clean Ubuntu 26.04
#     all          capture -> fetch -> seed -> serve -> reimage -> wait
#
# Seed/ISO delivery: by default the node fetches from this toolkit's built-in
# HTTP server at http://SEED_HTTP_BIND:SEED_HTTP_PORT/. If the node can only
# reach an existing/external web server (e.g. a locked-down lab where only a
# shared host on port 80 is routable), stage the WORK dir under that server and
# set SEED_BASE_URL in inventory.env to its base URL (the dir that exposes
# ./iso/ and ./seed/, e.g. http://10.0.0.5/~user/ab). When SEED_BASE_URL is set,
# 'reimage' builds the kexec URLs from it and does NOT require a local 'serve'.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_inventory
require_baremetal_mode

NODE="$(server_node)"
WORK="${PROVISION_WORK_DIR:-$CLUSTER_DIR/.baremetal}"; WORK="${WORK/#\~/$HOME}"
CAP_FILE="$WORK/capture.env"
TMPL_DIR="$CLUSTER_DIR/autoinstall"
ISO_DIR="$WORK/iso"; BOOT_DIR="$WORK/boot"; SEED_DIR="$WORK/seed"
SERVE_PID="$WORK/serve.pid"; SERVE_LOG="$WORK/serve.log"

iso_basename() { basename "${UBUNTU_ISO_URL:?set UBUNTU_ISO_URL in inventory.env}"; }

# Workstation IP the node dials for the HTTP seed: explicit, else auto-detected.
serve_bind() {
  local b="${SEED_HTTP_BIND:-}"
  [[ -n "$b" ]] || b="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$b" ]] || die "cannot auto-detect the workstation IP; set SEED_HTTP_BIND in inventory.env"
  echo "$b"
}

# ---- BM-T1. capture: read the live node (read-only) --------------------------
cmd_capture() {
  mkdir -p "$WORK"
  log "BM-T1 capture $NODE (disk + network identity)"
  local out; out="$(nssh "$NODE" 'bash -s' <<'EOF'
set -e
IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
MAC=$(cat /sys/class/net/"$IFACE"/address 2>/dev/null)
IPCIDR=$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}')
GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
# Prefer systemd-resolved's real upstream servers over /etc/resolv.conf, which on
# Ubuntu is often just the local stub (127.0.0.53); drop loopback so the
# re-imaged node's Netplan gets working upstream DNS.
DNS=$(
  { awk '/^nameserver/{print $2}' /run/systemd/resolve/resolv.conf 2>/dev/null; \
    awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null; } \
  | grep -vE '^(127\.|::1$)' | awk '!seen[$0]++' | paste -sd, -)
HN=$(hostname)
ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*\]//')
PK=$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null | awk 'NF{print; exit}')
if [ -n "$PK" ]; then DISK=/dev/$PK; else DISK=$ROOTSRC; fi
. /etc/os-release 2>/dev/null || true
# printf %q keeps spaces/parens (e.g. "... (Plow)") safe to `source` back.
printf 'CAP_IFACE=%q\n'       "$IFACE"
printf 'CAP_MAC=%q\n'         "$MAC"
printf 'CAP_IP_CIDR=%q\n'     "$IPCIDR"
printf 'CAP_GATEWAY=%q\n'     "$GW"
printf 'CAP_DNS=%q\n'         "$DNS"
printf 'CAP_HOSTNAME=%q\n'    "$HN"
printf 'CAP_TARGET_DISK=%q\n' "$DISK"
printf 'CAP_OS=%q\n'          "${PRETTY_NAME:-}"
printf 'CAP_KERNEL=%q\n'      "$(uname -r)"
EOF
)" || die "capture failed — is $NODE reachable? (./10-baremetal-provision.sh status)"
  printf '%s\n' "$out" > "$CAP_FILE"
  cat "$CAP_FILE"
  # shellcheck disable=SC1090
  source "$CAP_FILE"
  echo
  log "detected target disk: ${CAP_TARGET_DISK:-?}"

  # REIMAGE_STORAGE=reuse: record the exact partition geometry so `seed` can
  # preserve every other partition and reformat only the named ones.
  if [[ "${REIMAGE_STORAGE:-direct}" == "reuse" ]]; then
    local pdisk="${REIMAGE_DISK:?REIMAGE_STORAGE=reuse needs REIMAGE_DISK (e.g. /dev/nvme0n1)}"
    nssh "$NODE" "sudo -n sfdisk -d '$pdisk'" > "$WORK/partitions.sfdisk" 2>/dev/null \
      && [[ -s "$WORK/partitions.sfdisk" ]] \
      && log "saved partition table of $pdisk -> $WORK/partitions.sfdisk" \
      || { rm -f "$WORK/partitions.sfdisk"; die "could not read partition table of $pdisk on $NODE (needed for REIMAGE_STORAGE=reuse)"; }
    return 0
  fi
  if [[ -n "${REIMAGE_TARGET_DISK:-}" ]]; then
    [[ "$REIMAGE_TARGET_DISK" == "$CAP_TARGET_DISK" ]] ||
      warn "inventory REIMAGE_TARGET_DISK='$REIMAGE_TARGET_DISK' != detected '$CAP_TARGET_DISK' — the inventory value wins and WILL be erased"
  else
    warn "REIMAGE_TARGET_DISK is empty; '$CAP_TARGET_DISK' will be used and ERASED. Set it in inventory.env to confirm before reimage."
  fi
}

# ---- BM-T2. status: reachability + OS + key access (read-only) ----------------
cmd_status() {
  echo "################## $NODE ##################"
  nssh "$NODE" 'bash -s' <<'EOF' 2>&1 || { echo "  (SSH FAILED — unreachable or key not yet installed)"; return 0; }
. /etc/os-release 2>/dev/null || true
echo "  os        : ${PRETTY_NAME:-unknown}"
echo "  kernel    : $(uname -r)"
echo "  user      : $(id -un)"
echo "  sudo      : $(sudo -n true 2>/dev/null && echo passwordless || echo NO)"
EOF
}

# ---- BM-T3. fetch: download + verify ISO, extract vmlinuz/initrd --------------
cmd_fetch() {
  : "${UBUNTU_ISO_URL:?set UBUNTU_ISO_URL in inventory.env}"
  : "${UBUNTU_ISO_SHA256:?set UBUNTU_ISO_SHA256 in inventory.env (from the release SHA256SUMS)}"
  mkdir -p "$ISO_DIR" "$BOOT_DIR"
  local iso; iso="$ISO_DIR/$(iso_basename)"
  if [[ -f "$iso" ]] && echo "$UBUNTU_ISO_SHA256  $iso" | sha256sum -c - >/dev/null 2>&1; then
    log "BM-T3 ISO already present and verified: $iso"
  else
    log "BM-T3 downloading $UBUNTU_ISO_URL"
    curl -fL --retry 3 -C - -o "$iso" "$UBUNTU_ISO_URL"
    echo "$UBUNTU_ISO_SHA256  $iso" | sha256sum -c - || die "sha256 mismatch on $iso — check UBUNTU_ISO_SHA256"
    log "verified sha256"
  fi
  log "extracting casper/vmlinuz + casper/initrd"
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -C "$BOOT_DIR" -xf "$iso" casper/vmlinuz casper/initrd
    mv -f "$BOOT_DIR/casper/vmlinuz" "$BOOT_DIR/vmlinuz"
    mv -f "$BOOT_DIR/casper/initrd" "$BOOT_DIR/initrd"
    rmdir "$BOOT_DIR/casper" 2>/dev/null || true
  elif command -v 7z >/dev/null 2>&1; then
    7z -y -o"$BOOT_DIR" e "$iso" casper/vmlinuz casper/initrd >/dev/null
  else
    local mnt; mnt="$(mktemp -d)"
    sudo mount -o loop,ro "$iso" "$mnt"
    cp -f "$mnt/casper/vmlinuz" "$BOOT_DIR/vmlinuz"
    cp -f "$mnt/casper/initrd" "$BOOT_DIR/initrd"
    sudo umount "$mnt"; rmdir "$mnt"
  fi
  [[ -s "$BOOT_DIR/vmlinuz" && -s "$BOOT_DIR/initrd" ]] || die "failed to extract vmlinuz/initrd from $iso"
  log "ready: $BOOT_DIR/vmlinuz  $BOOT_DIR/initrd"
}

# --- seed block generators (correct YAML indentation matters) ------------------
gen_apt() {  # 2-space indent under autoinstall: installer network hardening
  # No upstream internet on many targets: skip the installer self-refresh and
  # fall back to the ISO package pool instead of stalling on an apt mirror test.
  printf '  refresh-installer:\n    update: false\n'
  printf '  apt:\n    geoip: false\n    fallback: offline-install\n'
  [[ -n "${PROXY_URL:-}" ]] && printf '    proxy: "%s"\n' "$PROXY_URL"
  return 0
}

gen_storage() {    # 4-space indent under storage:
  if [[ "${REIMAGE_STORAGE:-direct}" == "reuse" ]]; then
    gen_storage_reuse
    return
  fi
  printf '    layout:\n      name: direct\n'
  local disk="${REIMAGE_TARGET_DISK:-${CAP_TARGET_DISK:-}}"
  [[ -n "$disk" ]] && printf '      match:\n        path: %s\n' "$disk"
}

# Preserve every existing partition and reformat ONLY the named ones. Emits a
# byte-exact curtin storage config from the geometry captured by `capture`, so
# a shared Windows/Ubuntu ESP and the Windows data partitions survive intact.
gen_storage_reuse() {
  : "${REIMAGE_DISK:?REIMAGE_STORAGE=reuse needs REIMAGE_DISK (e.g. /dev/nvme0n1)}"
  : "${REIMAGE_ESP_PART:?REIMAGE_STORAGE=reuse needs REIMAGE_ESP_PART (e.g. /dev/nvme0n1p2)}"
  : "${REIMAGE_BOOT_PART:?REIMAGE_STORAGE=reuse needs REIMAGE_BOOT_PART (e.g. /dev/nvme0n1p5)}"
  : "${REIMAGE_ROOT_PART:?REIMAGE_STORAGE=reuse needs REIMAGE_ROOT_PART (e.g. /dev/nvme0n1p6)}"
  local pf="$WORK/partitions.sfdisk"
  [[ -f "$pf" ]] || die "no partition table captured ($pf) — run 'capture' first"
  python3 - "$pf" "$REIMAGE_DISK" "$REIMAGE_ESP_PART" "$REIMAGE_BOOT_PART" "$REIMAGE_ROOT_PART" <<'PY'
import re, sys
pf, disk, esp, boot, root = sys.argv[1:6]
sect = 512
parts = []
for line in open(pf):
    line = line.strip()
    m = re.match(r'^sector-size:\s*(\d+)', line)
    if m:
        sect = int(m.group(1)); continue
    m = re.match(r'^(\S+)\s*:\s*start=\s*(\d+),\s*size=\s*(\d+)', line)
    if not m:
        continue
    dev = m.group(1)
    parts.append((int(re.search(r'(\d+)$', dev).group(1)), dev,
                  int(m.group(2)) * sect, int(m.group(3)) * sect))
parts.sort()
if not parts:
    sys.exit('no partitions parsed from ' + pf)
for want in (esp, boot, root):
    if not any(dev == want for _, dev, _, _ in parts):
        sys.exit('partition not found in table: ' + want)
IND = '    '  # 4-space base: sits under `  storage:` in user-data
out = [IND + 'version: 1', IND + 'config:']
def item(lines):
    for i, l in enumerate(lines):
        out.append(IND + ('  - ' if i == 0 else '    ') + l)
item(['type: disk', 'id: disk0', 'path: ' + disk, 'ptable: gpt', 'preserve: true'])
for num, dev, off, size in parts:
    pid = 'part-%d' % num
    role = 'esp' if dev == esp else 'boot' if dev == boot else 'root' if dev == root else None
    p = ['type: partition', 'id: ' + pid, 'device: disk0', 'number: %d' % num,
         'offset: %d' % off, 'size: %d' % size, 'preserve: true']
    if role == 'esp':
        p += ['flag: boot', 'grub_device: true']
    elif role in ('boot', 'root'):
        p += ['wipe: superblock']
    item(p)
    if role == 'esp':
        item(['type: format', 'id: fmt-esp', 'volume: ' + pid, 'fstype: fat32', 'preserve: true'])
    elif role == 'boot':
        item(['type: format', 'id: fmt-boot', 'volume: ' + pid, 'fstype: ext4'])
    elif role == 'root':
        item(['type: format', 'id: fmt-root', 'volume: ' + pid, 'fstype: ext4'])
item(['type: mount', 'id: mount-root', 'device: fmt-root', 'path: /'])
item(['type: mount', 'id: mount-boot', 'device: fmt-boot', 'path: /boot'])
item(['type: mount', 'id: mount-efi', 'device: fmt-esp', 'path: /boot/efi'])
print('\n'.join(out))
PY
}

gen_network() {    # 6-space indent under ethernets:
  local iface="${CAP_IFACE:-}" mac="${CAP_MAC:-}"
  if [[ -n "$iface" && -n "$mac" ]]; then
    printf '      %s:\n        match:\n          macaddress: "%s"\n        set-name: %s\n' "$iface" "$mac" "$iface"
  else
    printf '      alleth:\n        match:\n          name: "en*"\n'
  fi
  if [[ "${REIMAGE_NET:-static}" == "dhcp" ]]; then
    printf '        dhcp4: true\n'
  else
    [[ -n "${CAP_IP_CIDR:-}" && -n "${CAP_GATEWAY:-}" ]] ||
      die "REIMAGE_NET=static needs a capture first (run ./10-baremetal-provision.sh capture)"
    printf '        addresses:\n          - %s\n' "$CAP_IP_CIDR"
    printf '        routes:\n          - to: default\n            via: %s\n' "$CAP_GATEWAY"
    if [[ -n "${CAP_DNS:-}" ]]; then
      printf '        nameservers:\n          addresses:\n'
      local d; IFS=',' read -ra _dns <<<"$CAP_DNS"
      for d in "${_dns[@]}"; do [[ -n "$d" ]] && printf '            - %s\n' "$d"; done
    fi
  fi
}

gen_late_proxy() { # 4-space list items under late-commands:
  [[ -n "${PROXY_URL:-}" ]] || return 0
  local np="${PROXY_NO_PROXY:-localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16}"
  # base64 the file bodies so no quotes/colons reach the YAML parser.
  local b64apt b64env
  b64apt="$(printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY_URL" "$PROXY_URL" | base64 -w0)"
  b64env="$(printf 'http_proxy=%s\nhttps_proxy=%s\nno_proxy=%s\n' "$PROXY_URL" "$PROXY_URL" "$np" | base64 -w0)"
  printf "    - curtin in-target -- bash -c 'echo %s | base64 -d > /etc/apt/apt.conf.d/95proxies'\n" "$b64apt"
  printf "    - curtin in-target -- bash -c 'echo %s | base64 -d >> /etc/environment'\n" "$b64env"
}

# Replace a whole-line @MARKER@ with the contents of a file (empty file => drop it).
splice() { awk -v m="$1" -v f="$2" '$0==m{while((getline l<f)>0)print l; close(f); next} {print}' "$3" > "$3.new" && mv "$3.new" "$3"; }

# ---- BM-T4. seed: render the NoCloud user-data + meta-data --------------------
cmd_seed() {
  : "${REIMAGE_HOSTNAME:?set REIMAGE_HOSTNAME in inventory.env}"
  : "${NODE_USER:?set NODE_USER in inventory.env (the login user to create)}"
  : "${SSH_IDENTITY:?set SSH_IDENTITY in inventory.env}"
  local pub="${SSH_IDENTITY/#\~/$HOME}.pub"
  [[ -f "$pub" ]] || die "public key not found: $pub (ssh-keygen -y -f ${SSH_IDENTITY} > $pub)"
  command -v openssl >/dev/null || die "openssl is required to generate the locked password hash"
  [[ -f "$CAP_FILE" ]] && { : ; # shellcheck disable=SC1090
    source "$CAP_FILE"; } || [[ "${REIMAGE_NET:-static}" == "dhcp" ]] || die "run 'capture' first (REIMAGE_NET=static needs the node's network identity)"

  mkdir -p "$SEED_DIR"
  local pubkey hash ud="$SEED_DIR/user-data" md="$SEED_DIR/meta-data"
  pubkey="$(cat "$pub")"
  # Prefix the hash with the shadow lock marker '!' so the account is truly
  # password-locked: SSH is key-only, and this prevents console login with the
  # (discarded) random password too, matching the key-only guarantee.
  hash="!$(openssl passwd -6 "$(head -c 18 /dev/urandom | base64)")"

  sed -e "s|@REIMAGE_HOSTNAME@|$REIMAGE_HOSTNAME|g" \
      -e "s|@NODE_USER@|$NODE_USER|g" \
      -e "s|@PASSWORD_HASH@|$hash|g" \
      -e "s|@SSH_PUBKEY@|$pubkey|g" \
      "$TMPL_DIR/user-data.tmpl" > "$ud"
  sed -e "s|@REIMAGE_HOSTNAME@|$REIMAGE_HOSTNAME|g" "$TMPL_DIR/meta-data.tmpl" > "$md"

  local t; t="$(mktemp)"
  gen_apt         > "$t"; splice '@APT@'         "$t" "$ud"
  gen_storage     > "$t"; splice '@STORAGE@'     "$t" "$ud"
  gen_network     > "$t"; splice '@NETWORK_ETH@' "$t" "$ud"
  gen_late_proxy  > "$t"; splice '@LATE_PROXY@'  "$t" "$ud"
  rm -f "$t"

  # Fail early on malformed YAML rather than deep inside the installer. PyYAML
  # is not part of the stdlib and is not a documented prerequisite, so treat a
  # missing module as a skipped check (with a hint) rather than a YAML error —
  # only genuinely malformed YAML should abort here.
  if command -v python3 >/dev/null; then
    if python3 -c 'import yaml' >/dev/null 2>&1; then
      python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$ud" \
        || die "rendered $ud is not valid YAML"
    else
      warn "python3 has no PyYAML module (pip3 install pyyaml) — skipping the seed YAML validation"
    fi
  fi
  log "BM-T4 wrote $ud and $md"
}

# ---- BM-T5. serve / serve-stop: HTTP for the ISO + seed -----------------------
cmd_serve() {
  [[ -f "$ISO_DIR/$(iso_basename)" ]] || die "no ISO yet — run 'fetch' first"
  [[ -f "$SEED_DIR/user-data" ]] || die "no seed yet — run 'seed' first"
  cmd_serve_stop >/dev/null 2>&1 || true
  local bind port; bind="$(serve_bind)"; port="${SEED_HTTP_PORT:-8099}"
  mkdir -p "$WORK"
  nohup python3 -m http.server "$port" --bind "$bind" --directory "$WORK" >"$SERVE_LOG" 2>&1 &
  echo $! > "$SERVE_PID"
  sleep 1
  kill -0 "$(cat "$SERVE_PID")" 2>/dev/null || { cat "$SERVE_LOG"; die "HTTP server failed to start"; }
  log "BM-T5 serving on http://$bind:$port/  (iso: /iso/$(iso_basename)  seed: /seed/)"
  log "stop with: ./10-baremetal-provision.sh serve-stop"
}

cmd_serve_stop() {
  [[ -f "$SERVE_PID" ]] || { log "no server pidfile"; return 0; }
  local pid; pid="$(cat "$SERVE_PID")"
  kill "$pid" 2>/dev/null && log "stopped HTTP server (pid $pid)" || log "server not running"
  rm -f "$SERVE_PID"
}

# prefix length -> dotted netmask (for the kernel ip= param)
prefix_to_mask() {
  awk -v p="$1" 'BEGIN{for(i=0;i<4;i++){b=(p>=8?8:(p>0?p:0));p-=b;m=0;for(j=0;j<b;j++)m+=2^(7-j);printf (i?".%d":"%d"),m}}'
}

# ---- BM-T6. reimage: kexec the node into the installer (DESTRUCTIVE) ----------
cmd_reimage() {
  reimage_guard "$NODE"
  # Load the capture result so CAP_TARGET_DISK (and the other CAP_* values)
  # resolve when 'reimage' runs as a separate process from 'capture' — only the
  # single-process 'all' path keeps them in the environment otherwise.
  if [[ -f "$CAP_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CAP_FILE"
  fi
  [[ -s "$BOOT_DIR/vmlinuz" && -s "$BOOT_DIR/initrd" ]] || die "run 'fetch' first (no vmlinuz/initrd)"
  [[ -f "$SEED_DIR/user-data" ]] || die "run 'seed' first (no seed)"
  if [[ -z "${SEED_BASE_URL:-}" ]]; then
    [[ -f "$SERVE_PID" ]] && kill -0 "$(cat "$SERVE_PID")" 2>/dev/null || die "run 'serve' first (the node fetches the ISO + seed over HTTP), or set SEED_BASE_URL for an external server"
  fi
  local target
  if [[ "${REIMAGE_STORAGE:-direct}" == "reuse" ]]; then
    : "${REIMAGE_DISK:?}" "${REIMAGE_BOOT_PART:?}" "${REIMAGE_ROOT_PART:?}"
    [[ -f "$WORK/partitions.sfdisk" ]] || die "run 'capture' first (need partition geometry for REIMAGE_STORAGE=reuse)"
    target="$REIMAGE_BOOT_PART (/boot) + $REIMAGE_ROOT_PART (/) on $REIMAGE_DISK — all other partitions preserved"
  else
    local disk="${REIMAGE_TARGET_DISK:-${CAP_TARGET_DISK:-}}"
    [[ -n "$disk" ]] || die "no target disk resolved — set REIMAGE_TARGET_DISK or run 'capture'"
    target="the ENTIRE disk $disk"
  fi

  local base iso_url seed_url ipparam
  if [[ -n "${SEED_BASE_URL:-}" ]]; then
    base="${SEED_BASE_URL%/}"
  else
    local bind port; bind="$(serve_bind)"; port="${SEED_HTTP_PORT:-8099}"
    base="http://$bind:$port"
  fi
  iso_url="$base/iso/$(iso_basename)"
  seed_url="$base/seed/"
  if [[ "${REIMAGE_NET:-static}" == "dhcp" ]]; then
    ipparam="ip=dhcp"
  else
    # shellcheck disable=SC1090
    [[ -f "$CAP_FILE" ]] && source "$CAP_FILE"
    local ip="${CAP_IP_CIDR%%/*}" pfx="${CAP_IP_CIDR##*/}" mask
    mask="$(prefix_to_mask "$pfx")"
    ipparam="ip=${ip}::${CAP_GATEWAY}:${mask}::${CAP_IFACE}:off"
    [[ -n "${CAP_DNS:-}" ]] && ipparam="$ipparam nameserver=${CAP_DNS%%,*}"
  fi
  local cmdline="autoinstall $ipparam url=$iso_url ds=nocloud-net;s=$seed_url"

  warn "About to re-image $NODE to clean Ubuntu 26.04, erasing: $target"
  warn "kexec command line: $cmdline"
  log "shipping installer vmlinuz/initrd to $NODE:/tmp"
  scp $SSH_OPTS "$BOOT_DIR/vmlinuz" "$NODE:/tmp/aet-vmlinuz" >/dev/null
  scp $SSH_OPTS "$BOOT_DIR/initrd"  "$NODE:/tmp/aet-initrd"  >/dev/null

  log "BM-T6 loading kexec + triggering (the node goes offline now)"
  # The reboot is deliberately backgrounded (sleep 3) so this SSH call returns
  # cleanly; that means package install / `kexec -l` failures surface as a
  # nonzero exit here, so do NOT swallow them — a failed load must abort rather
  # than falsely report that re-imaging started.
  nssh "$NODE" "sudo CMDLINE='$cmdline' bash -s" <<'EOF'
set -e
command -v kexec >/dev/null 2>&1 || { (apt-get update -y && apt-get install -y kexec-tools) || dnf install -y kexec-tools || yum install -y kexec-tools; }
kexec -l /tmp/aet-vmlinuz --initrd=/tmp/aet-initrd --command-line="$CMDLINE"
# Trigger after the SSH call returns so the connection closes cleanly.
( sleep 3; systemctl kexec >/dev/null 2>&1 || kexec -e ) >/dev/null 2>&1 &
EOF
  log "kexec triggered on $NODE — the installer will erase $target and reboot into clean Ubuntu 26.04"
  log "next: ./10-baremetal-provision.sh wait"
}

# ---- BM-T7. wait: block until the node returns as clean Ubuntu 26.04 ----------
cmd_wait() {
  local host="${NODE_HOSTS[0]:-}"
  [[ -n "$host" ]] && ssh-keygen -R "$host" >/dev/null 2>&1 || true
  log "BM-T7 waiting for $NODE to return as clean Ubuntu 26.04 (install + reboot can take many minutes)"
  local vid
  for _ in $(seq 1 60); do
    # single quotes: $VERSION_ID must expand on the NODE, not here.
    # shellcheck disable=SC2016
    vid="$(nssh "$NODE" '. /etc/os-release 2>/dev/null && echo "$VERSION_ID"' 2>/dev/null || true)"
    if [[ "$vid" == "26.04" ]]; then
      log "node is up on Ubuntu $vid"
      cmd_status
      log "converged — next: ./00-probe.sh, then ./20-kernel-build.sh all"
      return 0
    fi
    printf '.'; sleep 30
  done
  echo
  die "timed out waiting for $NODE — check the installer via your out-of-band console and the serve log ($SERVE_LOG)"
}

cmd_all() {
  # `all` runs capture straight into the destructive reimage. In direct-storage
  # mode an empty REIMAGE_TARGET_DISK would silently erase the auto-detected disk
  # with no confirmation, so require it explicitly here; the staged commands
  # (capture -> confirm -> reimage) remain available for detect-then-confirm.
  if [[ "${REIMAGE_STORAGE:-direct}" == "direct" && -z "${REIMAGE_TARGET_DISK:-}" ]]; then
    die "'all' requires REIMAGE_TARGET_DISK to be set explicitly; run 'capture', confirm the detected disk, then set REIMAGE_TARGET_DISK in inventory.env"
  fi
  cmd_capture; cmd_fetch; cmd_seed; cmd_serve; cmd_reimage; cmd_wait
}

usage() {
  sed -n '5,26p' "$0"
  exit "${1:-0}"
}

case "${1:-}" in
  capture)    cmd_capture ;;
  status)     cmd_status ;;
  fetch)      cmd_fetch ;;
  seed)       cmd_seed ;;
  serve)      cmd_serve ;;
  serve-stop) cmd_serve_stop ;;
  reimage)    cmd_reimage ;;
  wait)       cmd_wait ;;
  all)        cmd_all ;;
  ""|-h|--help|help) usage 0 ;;
  *) warn "unknown subcommand: $1"; usage 1 ;;
esac
