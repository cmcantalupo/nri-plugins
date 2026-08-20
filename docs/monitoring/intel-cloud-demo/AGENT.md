# AGENT.md — guidance for an AI assistant helping deploy this demo

This file tells a generative-AI coding assistant (Copilot, Claude, etc.) how to
help a **first-time user** stand up the Intel® Application Energy Telemetry (AET)
demo in this repository. Read it in full before advising the user or running any
command. Pair it with [SKILLS.md](SKILLS.md), which breaks the workflow into
discrete, checkable skills.

Your job: take a user who may have never touched Kubernetes or kernel builds,
and get them to a working Grafana dashboard showing **per-Pod energy** on a
single Intel Xeon 6+ cloud instance — safely, one verifiable step at a time.

## What this repo does (mental model)

The user rents a bare-metal **Intel® Xeon® 6+** node (code name Clearwater
Forest, or newer) on [Intel® Cloud Services](https://cloud.intel.com). That
silicon exposes **measured** per-hardware-thread energy and activity counters
through the Linux `resctrl` filesystem. This repo's toolkit builds an
AET-enabled kernel, stands up a single-node k3s cluster, and deploys a telemetry
pipeline so every Kubernetes Pod's real energy shows up live in Grafana:

```
Xeon 6+ (resctrl core_energy) → nri-resctrl-mon (per-Pod RMID)
  → otel-collector-resctrl (OTLP) → Prometheus → Grafana dashboards
```

There is **no software estimation and no external power meter** — that is the
differentiating value you are helping the user demonstrate.

The node's Ubuntu 26.04 image already ships Linux v7.0 with a complete AET
implementation; Canonical simply does not enable
`CONFIG_X86_CPU_RESCTRL_INTEL_AET`. So the kernel stage **rebuilds the node's own
Ubuntu kernel from Ubuntu's source package with that one option turned on** —
not a mainline tag. `CONFIG_CGROUP_BPF` and `CONFIG_INTEL_RAPL_TPMI` are already
set in the stock config. Say this plainly to the user: it is a config change, not
a kernel swap. (On a *non-Ubuntu* node that has no Ubuntu source to rebuild, the
AET kernel instead comes from a mainline git tag packaged as an `.rpm` — see the
kernel-source safety rule.)

**Meet the user where their hardware is.** The end state is always the same — a
bare-metal Xeon 6+ running an AET-enabled kernel with `rdt=perf` — but users
arrive from different starting points. Before choosing a path, **ask** (see
"How to work with the user", step 0): *Do you already have a Clearwater-Forest
(or newer) node? What OS does it run? Is an AET kernel already booted? Are you
willing to re-image / rebuild the kernel?* Their answers select one of five
entry points (this mirrors the README "Where do you start?" table):

| User's situation | `PROVISION_MODE` | Kernel settings | Start at |
|------------------|------------------|-----------------|----------|
| No node yet — provision one | `icloud` (default) | `KERNEL_SOURCE=ubuntu`, `KERNEL_PKG=auto` | Skill 1 (request allocation) |
| Own a CWF node, OK to wipe | `baremetal` | `KERNEL_SOURCE=ubuntu`, `KERNEL_PKG=auto` | Skill 1-BM (re-image) |
| Own an **Ubuntu** CWF node, keep the OS | `icloud`, **skip Stage 1** | `KERNEL_SOURCE=ubuntu`, `KERNEL_PKG=auto` | Skill 3 (kernel build) |
| Own a **non-Ubuntu** CWF node (RHEL/Rocky/Fedora), keep the OS | `icloud`, **skip Stage 1** | `KERNEL_SOURCE=git`, `KERNEL_PKG=rpm`, `KERNEL_BRANCH`=AET tag | Skill 3 → Skill 4 |
| Node **already runs an AET kernel** | `icloud`, **skip Stage 1** | *(kernel stages skipped)* | Skill 5 (aet-check) → Skill 6 |

**Two provisioning modes** cover the "need a clean node" rows, selected by
`PROVISION_MODE` in `inventory.env`:

- **`icloud` (default)** — the user rents a bare-metal Xeon 6+ node on Intel
  Cloud Services, which provisions a clean Ubuntu 26.04 image and jump-host SSH
  (Skills 1 / 1b / 1c).
- **`baremetal`** — the user already has root on their own Clearwater Forest
  node and re-images it **in place** to a clean Ubuntu 26.04 with
  `cluster/10-baremetal-provision.sh` (Skill 1-BM): kexec into the Ubuntu
  live-server installer driven by a NoCloud autoinstall seed. Directly reachable,
  no jump host.

**Bring-your-own existing node (the three "keep the OS" rows) is NOT a third
mode.** Leave `PROVISION_MODE=icloud`, do **not** run any Stage 1 script, and
have the user fill in the direct-SSH block of `inventory.env`
(`NODE_JUMPS=('')`, their real login user + node IP). Then begin at the "Start
at" skill for their row. The `icloud`/`baremetal` split only affects Stage 1;
from the kernel build (or aet-check) onward every path is identical. Pick exactly
one entry point — never mix Stage 1 scripts with a bring-your-own node.

## The user you are helping

Assume the user is a **naive consumer of this documentation**:

- They may not know k8s, `resctrl`, RAPL, NRI, or kernel `.deb` builds.
- They can copy/paste commands and read output back to you.
- They control one Linux **workstation / control host** (Ubuntu, a Linux VM, or
  WSL) with `ssh`, `git`, and `docker`. It does **not** need to be a Xeon 6+
  machine — it drives everything over SSH.
- They have (or will request) an Intel Cloud Services allocation.

Explain jargon the first time you use it. Prefer showing them the exact command
from the toolkit over improvising your own.

## The workflow you are guiding

The whole demo is automated by inventory-driven scripts under `cluster/`. The
user describes their allocation **once** in `cluster/inventory.env`, then runs
the numbered scripts in order. Every script is idempotent and re-runnable.

| Order | Script | Stage | Runs on |
|-------|--------|-------|---------|
| 1 (icloud) | *(none — web console)* | Request the allocation | workstation |
| 1-BM (baremetal) | `cluster/10-baremetal-provision.sh` | Re-image a self-managed node to clean Ubuntu 26.04 | workstation → node |
| 1b | `cluster/01-ssh-config.sh` | Generate / check / retire the SSH stanza | workstation |
| 1c | `ssh-copy-id` | Install your key on the jump host + node (kill the password) | workstation |
| 2 | `cluster/00-probe.sh` | Describe + probe the allocation (read-only) | workstation |
| 2b | `cluster/05-proxy-setup.sh` | (Optional) Configure a corporate proxy | workstation |
| 3 | `cluster/20-kernel-build.sh` | Build the AET kernel package — `.deb` or `.rpm` (Docker) | build host |
| 4 | `cluster/21-kernel-install.sh` | Install + promote the kernel (deb→update-grub, rpm→grubby) | workstation → node |
| 5 | `cluster/aet-check.sh` | Smoke-test AET on a booted node | node (root) |
| 6 | `cluster/30-k3s-up.sh` | Stand up k3s (NRI on, node labelled) | workstation → node |
| 7 | `cluster/40-deploy-telemetry.sh` | Deploy the AET telemetry stack | workstation → node |
| 8 | `cluster/60-validate.sh` | Validate live per-Pod telemetry | workstation → node |
| 9 | `cluster/70-grafana-tunnel.sh` | View / publish Grafana | workstation / publish host |
| 10 | `cluster/01-ssh-config.sh remove` | Retire the SSH stanza at cleanup | workstation |

`SKILLS.md` has one skill per stage with preconditions, commands, success
criteria, and common failures. Consult it as you go.

## How to work with the user

**Step 0 — determine the starting state by asking, before touching
`inventory.env`.** Do not assume the user needs a fresh allocation. Ask four
questions and route with the table in "What this repo does":

1. *Do you already have a bare-metal Clearwater-Forest (or newer) Xeon 6+ node,
   or do you need one provisioned?*
2. If they have one: *what OS does it run?* (Ubuntu 26.04 vs an RPM distro vs
   something else)
3. *Is an AET kernel already booted?* Have them run `cluster/aet-check.sh` (or
   check `ls /sys/fs/resctrl/mon_data/mon_PERF_PKG_00/` and `grep rdt=perf
   /proc/cmdline`). If the counters are already present, the whole kernel stage
   is skipped — go straight to Skill 5 then k3s.
4. *Are you willing to re-image the OS and/or rebuild the kernel?* A user who
   will not reboot or rebuild cannot enable AET on a stock kernel; say so plainly.

Then set `PROVISION_MODE`, `KERNEL_SOURCE`, and `KERNEL_PKG` per their row and
begin at the listed skill. For any "keep the OS" (bring-your-own) row, leave
`PROVISION_MODE=icloud`, skip every Stage 1 script, and fill the direct-SSH block
(`NODE_JUMPS=('')`). For a non-Ubuntu node choosing to build, set
`KERNEL_SOURCE=git`, `KERNEL_PKG=rpm`, and `KERNEL_BRANCH` to a mainline tag that
carries AET; the rest of the pipeline is unchanged.

**Then, for the "need a node" rows, pick the provisioning mode.** Read
`PROVISION_MODE` from `inventory.env` (default `icloud` when unset). For
`baremetal`, Stage 1 is **Skill 1-BM** (`10-baremetal-provision.sh`) instead of
Skills 1 / 1c, and the SSH stanza is jump-less (`NODE_JUMPS=('')`); everything
from Skill 2 onward is identical. Do not mix the two modes.

1. **Confirm prerequisites first.** Before anything else, verify the workstation
   has `ssh`, `git`, and `docker`, outbound internet, and an Intel Cloud
   Services account. Do not start the kernel build if `docker` is missing. If
   the user is on a corporate network behind an HTTP/SOCKS proxy, do **Skill 0**
   in `SKILLS.md` (proxy/firewall setup) before anything that reaches the
   internet. Check for the proxy directly rather than waiting for a hang:
   `env | grep -i proxy` and `grep -i 'ProxyCommand\|ProxyJump' ~/.ssh/config`.
2. **Check whether the allocation is actually live before trusting
   `~/.ssh/config`.** Users rarely clean up aliases from an expired allocation,
   so stale `Host icloud-aet*` stanzas look like a working setup. Start with
   `cluster/01-ssh-config.sh check`, which classifies every alias as
   `LIVE` / `STALE` / `UNREACHABLE` / `NO-STANZA` / `HOSTKEY`. `STALE` has two
   very different causes, so disambiguate before acting: if the **jump host**
   accepts your key but the **node** answers `Permission denied
   (publickey,password)`, the key simply is not in the node's
   `authorized_keys` yet — do **Skill 1c**, not a new allocation. Only when the
   jump host *itself* rejects the key has the reservation ended — then go back
   to **Skill 1**; do not debug SSH. Old stanzas also *shadow* new ones, because
   ssh takes the first matching `Host`: retire them with
   `01-ssh-config.sh prune --force` before `apply`.
3. **Get the connection facts from the portal, not from guesswork.** Ask the
   user to open the instance's page, click **How to Connect via SSH**, choose
   the **Linux / macOS** option, and paste the whole output back to you. That
   single paste carries everything you need: the Intel SOCKS `ProxyCommand`
   (`nc -x proxy-dmz.intel.com:1080`), the jump host and its user, the node IP
   and its user, and the default password. Map it onto `inventory.env`
   (`NODE_HOSTS`, `NODE_JUMPS`, `NODE_USER`, `JUMP_USER`, `PROXY_*`) — never
   invent an IP, user, or alias.
4. **Expect password-only access at first, and convert it to key access.** The
   panel hands out `devcloud`/`devcloud`; a freshly provisioned node has no
   authorized key at all. Every toolkit script is non-interactive, so do
   **Skill 1c** (`ssh-copy-id`) before `check`, `00-probe.sh`, or anything else,
   then have the user change the password.
5. **Read `inventory.env` before running scripts.** It is the single source of
   truth (node SSH alias, kernel vars, Grafana publish vars). If it does not
   exist yet, have the user copy `cluster/inventory.env.example` to
   `cluster/inventory.env` and fill it in. Never invent node names — use the
   alias the user put in their `~/.ssh/config` and in `inventory.env`.
6. **Go one stage at a time.** Run the stage, then run its `status`/`verify`
   subcommand, and read the output back before moving on. Do not chain the whole
   pipeline blind.
7. **Use `status` / `verify` / `snapshot` subcommands to check state**, not
   guesses. Most scripts expose them (e.g. `21-kernel-install.sh status`,
   `30-k3s-up.sh status`, `40-deploy-telemetry.sh verify`,
   `60-validate.sh snapshot`, `70-grafana-tunnel.sh status`).
8. **Prefer the toolkit over hand commands.** Every step *can* be done by hand,
   but the scripts encode the safe/idempotent path. Reach for raw `kubectl`,
   `dpkg`, or `ssh` only to diagnose, and explain what you are doing.

## Safety rules (do not violate)

- **Reboots are gated behind `ALLOW_REBOOT=1`.** Never set it for the user
  without first confirming they have an **out-of-band power-cycle / recovery
  path** for the allocation. A bad kernel boot must be recoverable.
- **Re-imaging (bare-metal path) is destructive and gated behind
  `ALLOW_REIMAGE=1`.** `10-baremetal-provision.sh reimage`/`all` **erase the
  node's target disk** and take it fully offline. Never set `ALLOW_REIMAGE=1`
  without first confirming, in the same exchange, that the user (a) has an
  out-of-band recovery path (serial / BMC / KVM / physical) and (b) accepts the
  disk erase. Echo the captured `REIMAGE_TARGET_DISK` and have them confirm it is
  the intended boot disk — a wrong disk is unrecoverable. Only ever run it on a
  node the user has designated disposable — never a shared or production box.
  Preserve network identity (`REIMAGE_NET=static` default) so the node returns at
  the IP in `NODE_HOSTS`; warn if `dhcp` is used without a MAC reservation.
  Secure Boot must be off (same unsigned-kernel rule); the login is key-only, so
  never put a password in a script or chat.
- **The kernel install never changes the boot default on its own.** Install →
  one-shot boot → verify healthy → *then* `promote`. Preserve that order so a
  bad boot self-recovers to the stock kernel.
- **AET requires bare metal.** If the user picked a shared/virtual instance,
  stop and tell them AET needs `resctrl`/RAPL sysfs available only on a
  bare-metal Xeon 6+ node.
- **AET is Xeon 6+ only.** Earlier Xeon 6 parts do not expose the `PERF_PKG`
  counters. If `aet-check.sh` finds no counters, suspect the wrong instance
  type before debugging software.
- **Choose the kernel source by the node's OS.** On Ubuntu 26.04 — which is
  every node this guide *provisions* — AET is already present in the node's own
  v7.0 kernel, so **always** rebuild Ubuntu's own source with the one extra
  option (`KERNEL_SOURCE=ubuntu`, the default); this keeps Ubuntu's patches and
  its security-update commitment. `KERNEL_SOURCE=git` (a mainline tag such as
  `v7.0` via `KERNEL_REPO`/`KERNEL_BRANCH`, packaged with `KERNEL_PKG=rpm`) is
  **only** for a base OS that is *not* Ubuntu 26.04 — e.g. an RPM distro whose
  shipped kernel lacks AET and has no Ubuntu source to rebuild. Never switch an
  Ubuntu 26.04 node to the git path (it needlessly forfeits Ubuntu's patches and
  security commitment), and never change the node's distro or kernel major
  version to get AET.
- **The RPM path is real and self-hosting.** `KERNEL_PKG=rpm` builds in a Rocky
  Linux container (`kernel/rocky-build.Docker`), so the build host only needs
  Docker to *build* — never tell the user to install rpm build tooling.
  `20-kernel-build.sh verify` does, however, need `bsdtar` (or `rpm2cpio`+`cpio`)
  on the build host to read the rpm's embedded config; it now FAILS rather than
  degrading if neither is present, so install one before relying on `verify`.
  `21-kernel-install.sh` auto-detects
  the node's package family (`node_pkg_family`) and installs/promotes an rpm with
  `rpm -i` + `grubby` + `grub2-reboot` instead of `dpkg -i` + `update-grub` — the
  RHEL-family node therefore needs `grubby` (and `grub2-reboot` for one-shot
  boots) present, which the standard grub2 packages provide. The install→one-shot
  →verify→promote ordering and the "never change the default on its own"
  guarantee hold identically for rpm (it forces the stock kernel to stay default
  via `grubby --set-default`).
- **Never judge AET support from the node's stock kernel config.** Ubuntu ships
  `CONFIG_X86_CPU_RESCTRL_INTEL_AET` disabled, so it is *absent* from
  `/boot/config-$(uname -r)` (and the captured `cwf-stock.config`) — that is
  expected and does **not** mean the source lacks AET. The stock config is only
  the base for driver preservation, never a feasibility signal. The one valid
  test is whether the kernel *source tree* defines the symbol; `container-build.sh`
  already enforces this (`grep 'config X86_CPU_RESCTRL_INTEL_AET' arch/x86/`, then
  re-asserts `=y` after `olddefconfig`). Do not add your own grep of the stock
  config and conclude "AET is unsupported" from it.
- **Confirm Secure Boot is off before promoting the built kernel.** It is
  unsigned; `mokutil --sb-state` must report Secure Boot disabled (it is on
  Intel Cloud bare metal) or the node will not boot it.
- **The demo is single-node.** It runs on one bare-metal Xeon 6+ instance; the
  k3s server also runs the workloads. `00-probe.sh` prints the node's CPU model
  and (if `EXPECT_CPU_MODEL` is set) confirms it matches the catalog. Do not try
  to network several nodes together.
- **Grafana credentials come from the `grafana-admin` Secret, not a default
  `admin`/`admin`.** `40-deploy-telemetry.sh` (`ensure_grafana_secret`) uses
  `GRAFANA_ADMIN_PASSWORD` from `inventory.env`; when it is unset a random
  password is generated and printed once at deploy time, and an existing Secret
  is left unchanged. Point users at that value (or have them set
  `GRAFANA_ADMIN_PASSWORD`); never publish the HTTPS tunnel without knowing the
  real admin password.
- **Never ask for, echo, or type the node password yourself.** The portal's
  default is `devcloud`/`devcloud`. When `ssh-copy-id` prompts, tell the user to
  type it directly into the terminal, and remind them to change it (`passwd`)
  once key access works. Never put it in a script, an `sshpass` call, or a chat
  message.
- **Never run destructive commands as a shortcut.** No `rm -rf`, `git clean`,
  `k3s-uninstall`, or reboot without listing exactly what happens and getting
  the user's explicit confirmation.
- **Never `git push` or commit on the user's behalf without an explicit,
  immediately-preceding "yes"** to a push/commit question you asked.

## Conventions in this repo

- Shell/YAML/Dockerfiles carry an SPDX header
  (`Apache-2.0`, `Copyright 2026 Intel Corporation`); the repo is Apache-2.0
  licensed (see [LICENSE](LICENSE)). Preserve headers when editing; Markdown
  docs do not carry them.
- Use `python3` (never bare `python`) in any example unless a virtualenv was
  activated earlier in the same shell session.
- Branding: **Intel®**, **Xeon® 6+**, **AET**. Keep the `®` and the `+`.
- Ports: Grafana NodePort **30030**, Prometheus NodePort **30090**, published
  Grafana HTTPS **3443**.
- The kernel build container's base image tracks the node's Ubuntu series, which
  `20-kernel-build.sh capture` records — do not hard-code a series or a kernel
  source version.

## When something breaks

Diagnose from evidence, do not retry blindly:

1. Re-run the stage's `status`/`verify` and read it back.
2. If **anything** SSH-shaped fails (hangs, password prompt, "permission
   denied"), run `01-ssh-config.sh check` first — it distinguishes an expired
   reservation from a real network or key problem in one command.
3. A node that answers `Permission denied (publickey,password)` while the jump
   host authenticated fine is **not** an expired reservation — the key was never
   installed on the node. Run **Skill 1c** (`ssh-copy-id`), then re-check.
4. `aet-check.sh` on the node answers "are the AET counters even present?" —
   check it before blaming the telemetry stack. If it finds none on a booted
   `-aet` kernel, confirm `20-kernel-build.sh verify` passed: `scripts/config`
   will happily set a symbol the tree does not define, so the build asserts the
   AET option both before and after `olddefconfig`.
5. `00-probe.sh` re-confirms SSH reachability, node capability, and that every
   node is the same SKU.
6. For "no data in Grafana": walk the pipeline backwards —
   `60-validate.sh snapshot` (are series live?) →
   `40-deploy-telemetry.sh verify` (are Prometheus targets up?) → Pod logs of
   `nri-resctrl-mon` / `otel-collector-resctrl`.
7. For "cannot reach Grafana": `70-grafana-tunnel.sh status` (200/200 = healthy;
   503/000 = tunnel down).
8. Bare-metal path (`PROVISION_MODE=baremetal`): if the node never returns after
   `reimage`, the install is in progress or failed — recover via the out-of-band
   console and check the `serve` HTTP log (did the node fetch the ISO + seed?)
   and the installer console. If it returns on the *old* OS, the kexec didn't
   take — re-run `reimage`. `10-baremetal-provision.sh status`/`wait` report the
   OS/kernel; `seed` refuses `REIMAGE_NET=static` without a prior `capture`.

If a step is genuinely blocked, propose an alternative or ask the user for the
missing detail — do not brute-force the same failing command.
