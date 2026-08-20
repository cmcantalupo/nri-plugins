# `cluster/autoinstall/` — NoCloud autoinstall seed for the bare-metal path

These templates drive an **unattended, in-place re-image** of a self-managed
bare-metal Clearwater Forest node to a clean **Ubuntu 26.04**, used only when
`PROVISION_MODE=baremetal` (see the README *"Alternative start"* section and
`SKILLS.md` Skill 1-BM). They are consumed by
[`../10-baremetal-provision.sh`](../10-baremetal-provision.sh).

## What they are

- `user-data.tmpl` — the NoCloud `#cloud-config` document containing the
  `autoinstall:` block subiquity reads. `@NAME@` tokens are substituted from
  `inventory.env`; whole-line `@BLOCK@` markers (`@APT@`, `@STORAGE@`,
  `@NETWORK_ETH@`, `@LATE_PROXY@`) are replaced with generated YAML or removed.
- `meta-data.tmpl` — the minimal NoCloud `meta-data` (instance-id, hostname).

## How they are used

`10-baremetal-provision.sh seed` renders both into `<work-dir>/seed/`
(`user-data`, `meta-data`); `serve` publishes that directory plus the ISO over
HTTP; `reimage` kexecs the node into the live-server installer with a kernel
command line that points cloud-init at the seed:

```
autoinstall ip=<static-or-dhcp> url=http://<workstation>:<port>/iso/<iso> ds=nocloud-net;s=http://<workstation>:<port>/seed/
```

## Rendered decisions

- **`@APT@` / `@LATE_PROXY@`** — `@APT@` is always emitted: it disables the
  installer self-refresh and sets `apt: {geoip: false, fallback: offline-install}`
  so an offline node falls back to the ISO package pool. Its `proxy:` field, and
  the whole `@LATE_PROXY@` block, are added only when `PROXY_URL` is set — the
  first points the installer's apt at the proxy, the second persists apt + env
  proxy into the installed system (so the Intel-network node can build the
  kernel and pull images afterwards).
- **`@STORAGE@`** — `layout: {name: direct}`, matched to `REIMAGE_TARGET_DISK`
  when set. **This wipes that disk.**
- **`@NETWORK_ETH@`** — a MAC-matched, `set-name` netplan stanza from `capture`
  (static, preserving the node's IP) or `dhcp4: true` when `REIMAGE_NET=dhcp`.
- **`@PASSWORD_HASH@`** — a random locked SHA-512 hash: console password login
  is disabled, access is key-only via the injected `SSH_IDENTITY.pub`.

## Hand-driven fallback

If you cannot run the script, render the seed by substituting the tokens
yourself, serve `user-data`/`meta-data` and the ISO over HTTP, and on the node
(as root):

```bash
sudo kexec -l /tmp/aet-vmlinuz --initrd=/tmp/aet-initrd \
  --command-line="autoinstall ip=dhcp url=http://<ws>:<port>/iso/<iso> ds=nocloud-net;s=http://<ws>:<port>/seed/"
sudo kexec -e   # or: sudo systemctl kexec
```

> The `casper/vmlinuz` and `casper/initrd` come from the live-server ISO
> (`fetch` extracts them). This **wipes the node** — keep an out-of-band
> console/BMC/KVM recovery path and confirm Secure Boot is off first.
