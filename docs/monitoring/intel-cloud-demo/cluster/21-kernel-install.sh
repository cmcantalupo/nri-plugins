#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/21-kernel-install.sh — ship the AET kernel package to every node and
# install it WITHOUT changing the boot default, so a bad new-kernel boot
# self-recovers to the known-good stock kernel. Reboot steps are gated behind
# ALLOW_REBOOT=1 — never reboot a cloud node without a confirmed out-of-band
# recovery path.
#
# Works for both packaging families, chosen per node by node_pkg_family (or an
# explicit KERNEL_PKG in inventory): 'deb' (Debian/Ubuntu — dpkg + update-grub /
# grub-set-default) and 'rpm' (RHEL/Rocky/Fedora — rpm + grubby / grub2-reboot).
#
# Run from your workstation (SSH access to every node):  cd cluster && ./21-kernel-install.sh ship install
#   ship               copy build/{deb,rpm}/* to a fresh per-node staging dir (+ sha256)
#   install            install the package, pin the boot default to the STOCK
#                      kernel and add the AET boot args (no reboot)
#   status             show installed kernels, boot default, running kernel per node
#   oneshot <node>     one-shot boot into $KERNEL_TAG   (needs ALLOW_REBOOT=1)
#   promote <node>     make $KERNEL_TAG the default       (needs ALLOW_REBOOT=1)
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_inventory

BUILD_DIR="${KERNEL_BUILD_DIR:?}"; BUILD_DIR="${BUILD_DIR/#\~/$HOME}"
DEB_DIR="$BUILD_DIR/build/deb"
RPM_DIR="$BUILD_DIR/build/rpm"

# Per-invocation staging dir on each node. Recreated fresh by `ship` and the
# only place `install` reads from, so a rebuilt kernel never installs alongside
# leftover packages from an earlier build sitting in shared /tmp.
NODE_STAGE="${NODE_STAGE:-/tmp/aet-kernel-stage}"

# Ship the bootable image + matching headers; skip the huge -dbg symbols package.
debs() {
  { ls "$DEB_DIR"/linux-image-*.deb 2>/dev/null | grep -v -- '-dbg_'
    ls "$DEB_DIR"/linux-headers-*.deb 2>/dev/null; } || true
}

# RPM equivalent: the kernel package(s) 20-kernel-build.sh produced for an
# RPM-based node; skip the large -debuginfo package and the source RPM
# (kernel-*.src.rpm is not a boot artifact and must never be installed on the node).
rpms() {
  { ls "$RPM_DIR"/kernel-*.rpm 2>/dev/null | grep -viE 'debuginfo|debug-|\.src\.rpm$'; } || true
}

# Package list + source dir for a node's family (deb|rpm).
pkg_list_for() { [[ "$1" == rpm ]] && rpms || debs; }
pkg_dir_for()  { [[ "$1" == rpm ]] && echo "$RPM_DIR" || echo "$DEB_DIR"; }

# ---- K-T3. Ship the built package(s) to every node ---------------------------
cmd_ship() {
  local n fam list f a b
  for n in "${NODES[@]}"; do
    fam="$(node_pkg_family "$n")"
    list="$(pkg_list_for "$fam")"
    [[ -n "$list" ]] || die "no $fam kernel packages in $(pkg_dir_for "$fam") — build first (20-kernel-build.sh)"
    log "K-T3 ship ($fam) to $n:$NODE_STAGE"
    # Recreate the staging dir so only this invocation's packages are present.
    nssh "$n" "rm -rf '$NODE_STAGE' && mkdir -p '$NODE_STAGE'"
    for f in $list; do
      scp $SSH_OPTS "$f" "$n:$NODE_STAGE/" >/dev/null
      a="$(sha256sum "$f" | cut -d' ' -f1)"
      b="$(nssh "$n" "sha256sum '$NODE_STAGE/$(basename "$f")'" | cut -d' ' -f1)"
      [[ "$a" == "$b" ]] && echo "  OK   $(basename "$f")" || die "sha256 mismatch for $(basename "$f") on $n"
    done
  done
}

# ---- K-T4. Install SSH-safe: pin default to the STOCK kernel, do NOT reboot ---
cmd_install() {
  local n fam
  # STOCK_KERNEL is the boot-default fallback: the deb path greps grub for it and
  # the rpm path pins it as the default so a bad new kernel self-recovers. An
  # empty value silently loses that guarantee (the Debian grep matches every
  # entry; the rpm path cannot restore a stock default), so fail before touching
  # the node.
  [[ -n "${STOCK_KERNEL:-}" ]] || die "STOCK_KERNEL is empty in the inventory — set it to the node's current stock kernel (see ./00-probe.sh) so the boot default can fall back to a known-good kernel"
  for n in "${NODES[@]}"; do
    fam="$(node_pkg_family "$n")"
    log "K-T4 install ($fam) on $n (default stays $STOCK_KERNEL)"
    if [[ "$fam" == rpm ]]; then install_rpm "$n"; else install_deb "$n"; fi
  done
  warn "K-T5 (one-shot boot into $KERNEL_TAG) needs explicit reboot approval + P-T4 recovery path."
}

# Debian/Ubuntu install: dpkg + GRUB (update-grub / grub-set-default).
install_deb() {
  local n="$1"
  nssh "$n" "sudo bash -s -- '$STOCK_KERNEL' '$KERNEL_TAG' '${KERNEL_CMDLINE_ADD:-rdt=perf}' '$NODE_STAGE'" <<'EOF'
set -e
STOCK_KERNEL="$1"; KERNEL_TAG="$2"; KERNEL_CMDLINE_ADD="$3"; STAGE="$4"
shopt -s nullglob
# Verify the documented stock fallback kernel is actually present BEFORE
# installing anything, so a mistyped/missing STOCK_KERNEL can't leave the
# freshly-installed (untested) kernel as the boot default with no known-good
# entry to fall back to.
[ -e "/boot/vmlinuz-$STOCK_KERNEL" ] || { echo "FATAL: stock kernel /boot/vmlinuz-$STOCK_KERNEL not found on the node — set STOCK_KERNEL to the node's current stock kernel (see ./00-probe.sh) before installing" >&2; exit 1; }
dpkg -i "$STAGE"/linux-image-*.deb "$STAGE"/linux-headers-*.deb 2>/dev/null || dpkg -i "$STAGE"/linux-image-*.deb
# Put required boot args (e.g. rdt=perf for AET) on the deployed kernel command
# line. Append to GRUB_CMDLINE_LINUX so every menu entry (incl. the new kernel)
# gets them; create the line if the distro omits it. AET exposes no resctrl
# counters without rdt=perf, so this must actually land in grub.cfg (verified
# after update-grub below).
for tok in $KERNEL_CMDLINE_ADD; do
  if grep -qE "^GRUB_CMDLINE_LINUX=\"([^\"]*[[:space:]])?${tok}([[:space:]][^\"]*)?\"" /etc/default/grub; then
    :  # already present on the command line
  elif grep -qE '^GRUB_CMDLINE_LINUX="' /etc/default/grub; then
    sed -i "s|^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"|\1 ${tok}\"|" /etc/default/grub
  else
    echo "GRUB_CMDLINE_LINUX=\"${tok}\"" >> /etc/default/grub
  fi
done
# Pin GRUB to boot the *saved* entry, and set that saved entry to the STOCK kernel.
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
update-grub
# Fail loudly if a required boot arg did not make it into the generated config.
for tok in $KERNEL_CMDLINE_ADD; do
  grep -q -- "$tok" /boot/grub/grub.cfg \
    || { echo "FATAL: '$tok' missing from /boot/grub/grub.cfg after update-grub" >&2; exit 1; }
done
STOCK_ID=$(grep 'menuentry ' /boot/grub/grub.cfg | grep -- "$STOCK_KERNEL" | grep -v recovery \
           | sed -n "s/.*\\\$menuentry_id_option '\\([^']*\\)'.*/\\1/p" | head -1)
[ -n "$STOCK_ID" ] || { echo "FATAL: could not find stock grub entry for $STOCK_KERNEL" >&2; exit 1; }
grub-set-default "$STOCK_ID"
echo "  installed: $(ls /boot/vmlinuz-*"$KERNEL_TAG"* 2>/dev/null || echo MISSING)"
echo "  initramfs: $(ls /boot/initrd.img-*"$KERNEL_TAG"* 2>/dev/null || echo MISSING)"
echo "  cmdline_add: $(sed -n 's/^GRUB_CMDLINE_LINUX=//p' /etc/default/grub)"
echo "  saved_entry=$(grub-editenv list | sed -n 's/^saved_entry=//p')"
echo "  stock_id=$STOCK_ID"
echo "  running=$(uname -r)  (unchanged — no reboot)"
EOF
}

# RHEL-family install: rpm + grubby (which edits grub.cfg / BLS entries in place,
# so no grub2-mkconfig is needed). rpm keeps the stock kernel (kernel packages
# are install-only), and we force the boot default back to the stock kernel so a
# bad new-kernel boot self-recovers — mirroring the deb path.
install_rpm() {
  local n="$1"
  nssh "$n" "sudo bash -s -- '$STOCK_KERNEL' '$KERNEL_TAG' '${KERNEL_CMDLINE_ADD:-rdt=perf}' '$NODE_STAGE'" <<'EOF'
set -e
STOCK_KERNEL="$1"; KERNEL_TAG="$2"; KERNEL_CMDLINE_ADD="$3"; STAGE="$4"
shopt -s nullglob
command -v grubby >/dev/null || { echo "FATAL: grubby not found (RHEL-family expected)" >&2; exit 1; }
# Verify the documented stock fallback kernel is actually present BEFORE
# installing anything: rpm -ivh can promote the new kernel to default, so a
# mistyped/missing STOCK_KERNEL must fail here rather than after the install
# leaves the untested kernel as the boot default.
STOCK_VMLINUZ="/boot/vmlinuz-$STOCK_KERNEL"
[ -e "$STOCK_VMLINUZ" ] || { echo "FATAL: stock kernel $STOCK_VMLINUZ not found on the node — set STOCK_KERNEL to the node's current stock kernel (see ./00-probe.sh) before installing" >&2; exit 1; }
# Install alongside the stock kernel (kernel rpms are install-only). --replacepkgs
# keeps this idempotent on re-run; --oldpackage tolerates a lower version string
# than one already installed.
rpm -ivh --replacepkgs --oldpackage "$STAGE"/kernel-*.rpm
NEW_VMLINUZ="/boot/vmlinuz-$KERNEL_TAG"
[ -e "$NEW_VMLINUZ" ] || { echo "FATAL: $NEW_VMLINUZ not installed (check KERNEL_TAG vs the built release)" >&2; exit 1; }
# Put required boot args (e.g. rdt=perf for AET) on the new kernel's entry.
for tok in $KERNEL_CMDLINE_ADD; do
  grubby --info="$NEW_VMLINUZ" | grep -q -- "$tok" || grubby --update-kernel="$NEW_VMLINUZ" --args="$tok"
done
# Force the boot default back to the STOCK kernel (installing a kernel rpm
# otherwise promotes the new one). Its presence was verified before install, so
# this always restores a known-good default that a bad new-kernel boot recovers to.
grubby --set-default="$STOCK_VMLINUZ"
# Fail loudly if a required boot arg did not land on the new entry.
for tok in $KERNEL_CMDLINE_ADD; do
  grubby --info="$NEW_VMLINUZ" | grep -q -- "$tok" \
    || { echo "FATAL: '$tok' missing from $NEW_VMLINUZ grubby entry" >&2; exit 1; }
done
echo "  installed: $(ls /boot/vmlinuz-*"$KERNEL_TAG"* 2>/dev/null || echo MISSING)"
echo "  initramfs: $(ls /boot/initramfs-*"$KERNEL_TAG"*.img 2>/dev/null || echo MISSING)"
echo "  default  : $(grubby --default-kernel)"
echo "  args     : $(grubby --info="$NEW_VMLINUZ" | sed -n 's/^args=//p')"
echo "  running  : $(uname -r)  (unchanged — no reboot)"
EOF
}

cmd_status() {
  local n fam
  for n in "${NODES[@]}"; do
    echo "################## $n ##################"
    fam="$(node_pkg_family "$n")"
    if [[ "$fam" == rpm ]]; then status_rpm "$n"; else status_deb "$n"; fi
  done
}

status_deb() {
  nssh "$1" "KERNEL_TAG='$KERNEL_TAG' bash -s" <<'EOF' 2>&1 || echo "  (SSH FAILED)"
echo "  running   : $(uname -r)"
echo "  cmdline   : $(cat /proc/cmdline)"
echo "  installed : $(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | paste -sd' ')"
echo "  grub_dflt : GRUB_DEFAULT=$(sed -n 's/^GRUB_DEFAULT=//p' /etc/default/grub)  saved_entry=$(sudo grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p')"
EOF
}

status_rpm() {
  nssh "$1" "KERNEL_TAG='$KERNEL_TAG' bash -s" <<'EOF' 2>&1 || echo "  (SSH FAILED)"
echo "  running   : $(uname -r)"
echo "  cmdline   : $(cat /proc/cmdline)"
echo "  installed : $(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | paste -sd' ')"
echo "  default   : $(sudo grubby --default-kernel 2>/dev/null)"
EOF
}

# resolve a node's grub menuentry_id_option for a given kernel version substring
grub_id_for() { # <node> <kver-substr>
  nssh "$1" "sudo grep 'menuentry ' /boot/grub/grub.cfg | grep -- '$2' | grep -v recovery \
    | sed -n \"s/.*\\\$menuentry_id_option '\\([^']*\\)'.*/\\1/p\" | head -1"
}

# resolve a node's grubby boot index for the given kernel release (RHEL-family)
grubby_index_for() { # <node> <kver>
  nssh "$1" "sudo grubby --info=/boot/vmlinuz-$2 2>/dev/null | sed -n 's/^index=//p' | head -1"
}

reboot_guard() {
  [[ "${ALLOW_REBOOT:-0}" == "1" ]] || die "refusing to reboot $1: set ALLOW_REBOOT=1 AND confirm P-T4 recovery path first"
}

# ---- K-T5. One-shot boot into the new kernel (reversible) ---------------------
cmd_oneshot() {
  local n="${1:?usage: $0 oneshot <node>}"; reboot_guard "$n"
  local fam; fam="$(node_pkg_family "$n")"
  if [[ "$fam" == rpm ]]; then
    local idx; idx="$(grubby_index_for "$n" "$KERNEL_TAG")"; [[ -n "$idx" ]] || die "no $KERNEL_TAG entry on $n (grubby)"
    log "K-T5 one-shot boot $n -> $KERNEL_TAG (index $idx); stock remains the default on next boot"
    nssh "$n" "sudo grub2-reboot '$idx' && sudo reboot" || true
  else
    local id; id="$(grub_id_for "$n" "$KERNEL_TAG")"; [[ -n "$id" ]] || die "no $KERNEL_TAG grub entry on $n"
    log "K-T5 one-shot boot $n -> $KERNEL_TAG ($id); stock remains the default on next boot"
    nssh "$n" "sudo grub-reboot '$id' && sudo reboot" || true
  fi
  log "$n rebooting; when back check: ./21-kernel-install.sh status  (expect running=$KERNEL_TAG)"
}

# ---- K-T7. Promote the new kernel to default ---------------------------------
cmd_promote() {
  local n="${1:?usage: $0 promote <node>}"; reboot_guard "$n"
  local fam running; fam="$(node_pkg_family "$n")"
  running="$(nssh "$n" 'uname -r' 2>/dev/null)"
  if [[ "$fam" == rpm ]]; then
    nssh "$n" "sudo test -e /boot/vmlinuz-$KERNEL_TAG" || die "no $KERNEL_TAG installed on $n"
    if [[ "$running" == "$KERNEL_TAG" ]]; then
      log "K-T7 promote $KERNEL_TAG on $n; already running it — set default, NO reboot"
      nssh "$n" "sudo grubby --set-default=/boot/vmlinuz-$KERNEL_TAG && echo '  default='\$(sudo grubby --default-kernel)"
    else
      die "refusing to promote: $n is running '$running', not $KERNEL_TAG — run the one-shot boot first (ALLOW_REBOOT=1 ./21-kernel-install.sh oneshot $n), confirm it is healthy, THEN promote. Promoting an unbooted kernel bypasses the self-recovering one-shot path."
    fi
  else
    local id; id="$(grub_id_for "$n" "$KERNEL_TAG")"; [[ -n "$id" ]] || die "no $KERNEL_TAG grub entry on $n"
    if [[ "$running" == "$KERNEL_TAG" ]]; then
      log "K-T7 promote $KERNEL_TAG on $n ($id); already running it — set default, NO reboot"
      nssh "$n" "sudo grub-set-default '$id'"
      nssh "$n" "echo '  saved_entry='\$(sudo grub-editenv list | sed -n 's/^saved_entry=//p')"
    else
      die "refusing to promote: $n is running '$running', not $KERNEL_TAG — run the one-shot boot first (ALLOW_REBOOT=1 ./21-kernel-install.sh oneshot $n), confirm it is healthy, THEN promote. Promoting an unbooted kernel bypasses the self-recovering one-shot path."
    fi
  fi
}

[[ $# -gt 0 ]] || { echo "usage: $0 {ship|install|status|oneshot <node>|promote <node>} ..." >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    ship)    cmd_ship; shift ;;
    install) cmd_install; shift ;;
    status)  cmd_status; shift ;;
    oneshot) cmd_oneshot "${2:?usage: $0 oneshot <node>}"; shift 2 ;;
    promote) cmd_promote "${2:?usage: $0 promote <node>}"; shift 2 ;;
    *) echo "usage: $0 {ship|install|status|oneshot <node>|promote <node>} ..." >&2; exit 2 ;;
  esac
done
