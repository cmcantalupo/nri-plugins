# SKILLS.md — deployment skills for the AET demo

A catalog of the discrete skills needed to deploy this Intel® Application Energy
Telemetry (AET) demo, written so a generative-AI assistant can guide a
first-time user through each one. Read [AGENT.md](AGENT.md) first for the mental
model and safety rules.

Each skill lists **when to use it**, **preconditions**, the **commands** the
toolkit provides, **success criteria** to check before moving on, and **common
failures**. Run the skills in order; every script is idempotent and safe to
re-run. All commands run from the repository's `cluster/` directory unless noted.

## Where does the user start? (skill routing)

Not every user starts at Skill 1. Before running anything, ask the four
starting-state questions in [AGENT.md](AGENT.md) ("How to work with the user",
Step 0) — *do you have a CWF node? what OS? is an AET kernel already booted? will
you re-image / rebuild?* — and enter the skill chain at the right point:

| User's situation | `inventory.env` | Enter at |
|------------------|-----------------|----------|
| No node yet — provision one | `PROVISION_MODE=icloud`, `KERNEL_SOURCE=ubuntu`, `KERNEL_PKG=auto` | Skill 1 |
| Own a CWF node, OK to wipe it | `PROVISION_MODE=baremetal`, `KERNEL_SOURCE=ubuntu`, `KERNEL_PKG=auto` | Skill 1-BM |
| Own an **Ubuntu** CWF node, keep the OS | `PROVISION_MODE=icloud` *(skip Stage 1)*, `KERNEL_SOURCE=ubuntu`, `KERNEL_PKG=auto` | Skill 3 |
| Own a **non-Ubuntu** CWF node, keep the OS | `PROVISION_MODE=icloud` *(skip Stage 1)*, `KERNEL_SOURCE=git`, `KERNEL_PKG=rpm`, `KERNEL_BRANCH`=AET tag | Skill 3 |
| Node **already runs an AET kernel** | `PROVISION_MODE=icloud` *(skip Stage 1)* | Skill 5 |

For every "keep the OS" (bring-your-own) row there is **no separate mode**: leave
`PROVISION_MODE=icloud`, run **no** Stage 1 script (Skills 1 / 1-BM / 1c), and
fill the direct-SSH block of `inventory.env` instead — `NODE_JUMPS=('')`, the
node's real login user, and its reachable IP — so Skills 2+ reach it directly.
Then start at the skill in the table and follow the rest in order.

---

## Skill 0 — (Preflight) Configure corporate proxy / firewall access

**When:** the user's workstation is on a corporate network that only reaches the
internet through an HTTP/SOCKS proxy (and may block outbound SSH). Skip entirely
if the workstation has direct outbound internet. The tell is a `git clone` or
`docker pull` that hangs — many users won't know they're proxied until then.

**Preconditions:** the user knows their corporate proxy `host:port`, the ssh
jump host, and (if the proxy inspects TLS) the path to their corporate root CA.
Ask before assuming.

**Commands:** the whole thing is driven by `cluster/05-proxy-setup.sh`, which
reads `PROXY_*` from `inventory.env` and applies the fiddly config for you. Help
the user fill in `inventory.env` (from the `PROXY_*` block in
`inventory.env.example`):
- `PROXY_URL` — the HTTP proxy, e.g. `http://proxy.example.com:912` (used for
  both `http_proxy` and `https_proxy`).
- `PROXY_JUMP_HOST` + `PROXY_SSH_TYPE` (`http`/`socks5`) — for tunnelling SSH.
- `PROXY_CA` — corporate root CA, only if the proxy re-signs TLS.
- optional: `PROXY_NO_PROXY`, `PROXY_SSH_HOSTPORT`, `PROXY_GOPROXY`.

Then run, from `cluster/`:
```bash
./05-proxy-setup.sh docker        # Docker daemon drop-in + client build proxy
./05-proxy-setup.sh ssh apply     # jump-host ProxyCommand into ~/.ssh/config
eval "$(./05-proxy-setup.sh env)" # http(s)_proxy / no_proxy / CA into this shell
./05-proxy-setup.sh check         # verify git, docker, ssh reach the outside
# or: ./05-proxy-setup.sh all      (docker + ssh apply + check)
```
The script computes a `no_proxy` that already covers loopback and the private and
k3s pod/service CIDRs, so SSH tunnels and in-cluster scrapes are never bounced to
the proxy.

**Success:** `./05-proxy-setup.sh check` passes — `git ls-remote github.com`,
`docker pull hello-world`, and `ssh <jump-host> true` all succeed.

**Common failures:** `PROXY_URL` unset (script exits telling you so); ran
`docker`/`ssh` but forgot `eval "$(... env)"` in the shell that runs the later
scripts (git/curl still bypass the proxy); TLS-inspecting proxy without
`PROXY_CA` (x509 "unknown authority" during `apt`/`git`/`go`); still no egress
even through the proxy — clone the kernel elsewhere and set `KERNEL_LOCAL_REPO`
(Skill 3).

---

## Skill 1 — Request an allocation and set up SSH access

> **Self-managed bare-metal node?** If the user already has root on their own
> Clearwater Forest node (`PROVISION_MODE=baremetal`), do **Skill 1-BM** below
> instead of this skill, then continue at Skill 1b (`apply`/`check`). Skill 1c
> (`ssh-copy-id`) is skipped — autoinstall injects the key.

**When:** the very start; the user has no node yet — **or** their previous
reservation has ended.

**Preconditions:** a Linux workstation with `ssh` and `git`. An
[Intel® Cloud Services](https://cloud.intel.com) account (created in step 1
below if the user does not have one).

> **First check whether an old allocation is in the way.** Users seldom delete
> `~/.ssh/config` stanzas when a reservation lapses, so the aliases still
> resolve and look healthy. Test one before assuming anything:
> ```bash
> ssh -o BatchMode=yes -o ConnectTimeout=10 icloud-aet0 uname -r
> ```
> A **jump-host password prompt** (`guest@<ip>'s password:`) means the key is no
> longer authorized — i.e. the reservation ended. That is a *new allocation*
> problem, not an SSH problem. Delete or rename the stale stanzas so the new
> ones cannot be confused with them, then continue below.

> Portal terminology (verified against the live console) so you can direct the
> user precisely: the console lives at
> [cloud.intel.com](https://cloud.intel.com); its top tabs (and the left
> **Cloud Services** menu) are **Overview**, **Catalog**, **Instances**, and
> **SSH keys**. The active region is encoded in the URL
> (`…/preview/compute?region=<region>`, e.g. `us-region-3`). The **Instances**
> tab lists nodes with columns **Instance Name**, **IP**, **State**, **Instance
> Type**, **Reservation Start**, **Reservation End**, and per-row **Actions**
> (**Connect** = browser session, **SSH** = shows the exact SSH command,
> **Edit**, **Extend** = push out the reservation expiration, **Delete** =
> release). Bare-metal Xeon 6+ shows an instance type like **`BM-CWF`**
> (Bare-Metal Clearwater Forest). Clicking a node opens its **Details** page
> (tabs **Details / Networking / Security / Billing**, plus **Connect**, **How
> to Connect via SSH**, and an **Actions** menu); there, **Instance Category:
> `BareMetalHost`** confirms bare metal, **Instance Type** reads *"Intel® Xeon®
> processors (codenamed Clear Water Forest)"*, and **Machine Image** names the
> stock OS (e.g. Ubuntu 26.04 LTS — deb-based). SSH public keys are managed
> under **SSH keys** and stored **separately** from any other keys. Official
> guides: [Sign In](https://cloud.intel.com/docs/how_to_register.html),
> [Request](https://cloud.intel.com/docs/how_to_request.html),
> [Access](https://cloud.intel.com/docs/how_to_access.html).

**Steps:**
1. **Sign in / register.** Click **Sign In / Sign Up** (top-right). Sign in with
   a corporate or personal email via the Intel login page; new users verify
   their email and accept the Intel® Cloud Services license agreement.
2. **Generate an SSH key on the workstation** (do this before requesting so the
   key is available in the form):
   ```bash
   ssh-keygen -t ed25519 -C "intelcloud-aet" -f ~/.ssh/id_ed25519_intelcloud
   cat ~/.ssh/id_ed25519_intelcloud.pub   # copy this into the portal
   ```
   In the console, open **SSH Keys → Upload key** and paste the `.pub` contents
   (up to 20 keys per instance; keys can also be added directly in the request
   form).
3. **Request the instance.** Open the **Catalog** tab and select a **bare-metal
   Intel® Xeon® 6+** instance (instance type such as **`BM-CWF`**, Bare-Metal
   Clearwater Forest) — AET needs `resctrl`/RAPL sysfs, available only on bare
   metal, not a shared/virtual instance. In **Request a Cloud Instance**,
   complete the required fields (**Instance name**, **Intended use**, **Use
   case**, **Duration**, and a **Deployment details** description), select your
   **SSH Public Key(s)** (so SSH access is enabled), optionally enable
   **Termination Protection**, then click **Request Instance**. Request a
   **single** bare-metal node — this demo runs entirely on one Xeon 6+ instance.
   Name it predictably (e.g. `aet-0`) so the console row maps onto the
   `icloud-aet0` alias you are about to create, and note the CPU model shown on
   the instance type / Details page so you can record it as `EXPECT_CPU_MODEL`
   in `inventory.env`; Skill 2's probe then confirms the delivered node matches.
4. **Wait for approval.** Approval arrives by email, typically within ~2–3
   business days (some requests are pre-approved / immediate; Test Drive access
   is self-service). The email reports approved / waitlisted / rejected.

   **Choose the Duration with the kernel build in mind.** The reservation clock
   starts when the instance goes `Ready`, not when you request it, and the
   AET kernel cannot be built in advance — Skill 3's `capture` step reads the
   stock config off the live node. Budget: same-day bring-up and `capture`, a
   multi-hour kernel build, then a reboot cycle before any experiment
   starts. A one-week duration is comfortable; anything under two days is not.
   Use the **Extend** action rather than letting it lapse and re-requesting.
5. **Get the exact SSH details.** Once the instance **State** shows **Ready**
   on the **Instances** tab, open the instance and click **How to Connect via
   SSH**, then select the **Linux / macOS** option. Ask the user to paste that
   whole output back — it is the authoritative source and carries every value at
   once:
   - the Intel SOCKS proxy stanza for `~/.ssh/config`, used from inside the
     Intel network:
     ```
     Host 146.152.* 192.55.48.* 134.191.*
     ProxyCommand /usr/bin/nc -x proxy-dmz.intel.com:1080 %h %p
     ```
   - a connection string of the form
     `ssh-keygen -R <node-ip> 2>/dev/null; ssh -J guest@<jump-ip> devcloud@<node-ip>`
     — which names the node user, the node IP, and the jump host (the
     `ssh-keygen -R` prefix clears the recycled IP's old host key);
   - the **default credentials**, username `devcloud` and password `devcloud`,
     which the portal itself tells you to change on first login.

   (The **Connect** action opens a browser session / JupyterLab; this demo needs
   real SSH, so use the SSH details.)
6. **Record the connection facts in `inventory.env`** (`NODE_HOSTS`,
   `NODE_JUMPS`, `NODE_USER`, `JUMP_USER`, `SSH_IDENTITY`, plus the `PROXY_*`
   block for the SOCKS stanza) rather than hand-editing `~/.ssh/config`. Skill 1b
   generates the stanza from them — and, just as importantly, can take it back
   out when the reservation ends.
7. **Plan to replace the password with a key** — that is Skill 1c. The panel's
   credentials are a bootstrap only; the toolkit needs password-free SSH.

**Success:** the instance shows **Ready** in the console (with **Instance
Category: `BareMetalHost`** on its Details page) and the panel's own command,
`ssh -J guest@<jump-ip> devcloud@<node-ip>`, logs in — with the password at this
stage. Password-free access arrives in Skill 1c.

**Common failures:** shared/virtual instance chosen (AET absent — must be
bare-metal Xeon 6+, e.g. instance type `BM-CWF`); a Xeon 6 (not 6+) part with no
AET counters (caught by `00-probe.sh`, not by the portal — request a replacement
of the matching Instance Type); stale `~/.ssh/config` aliases from an expired
reservation that fail as a jump-host password prompt; assuming the key you
uploaded to the portal is already on the node — it authorizes the *jump host*,
while the node keeps password-only login until Skill 1c; wrong region in the
URL/console so the Ready instance isn't
visible; `ProxyJump` omitted when the portal's SSH panel shows a jump host (or
included when it doesn't); the `IdentityFile` not matching the uploaded public
key. Watch the **Reservation End** — use the **Extend** action before it lapses.

---

## Skill 1-BM — Re-image a self-managed bare-metal node to clean Ubuntu 26.04

**When:** the very start, when the user already has root on their own bare-metal
Clearwater Forest node and is **not** using Intel Cloud
(`PROVISION_MODE=baremetal`). Replaces Skills 1 and 1c (and the portal half of
1b) for that path. After it, the user still does Skill 1b (`apply`/`check`) for
the jump-less SSH stanza, then Skill 2 onward unchanged.

**Why it is its own skill:** these users start from *whatever OS the node runs
now*, not a clean Intel Cloud image, and have no allocation or jump host. This
skill re-images the node **in place** to a clean Ubuntu 26.04 by kexec-ing its
running OS into the Ubuntu 26.04 live-server installer (subiquity), driven
unattended by a NoCloud autoinstall seed served over HTTP from the workstation.
The result is the same clean, stock-kernel Ubuntu 26.04 the Intel Cloud path
starts from, so Skill 3 (kernel build) proceeds identically.

**Preconditions (confirm every one before touching the node):**
- Root SSH to the node, and it is **disposable** — the re-image **erases its
  disk**.
- An **out-of-band recovery path** (serial console / BMC / KVM / physical
  access): a failed install leaves the node needing recovery.
- **Secure Boot off** in firmware (the rebuilt AET kernel is unsigned;
  autoinstall cannot toggle it).
- The node can reach the workstation over HTTP (default `SEED_HTTP_PORT=8099`).
- `curl` + `bsdtar`/`7z` on the workstation; `docker` is not needed here.
- `inventory.env` bare-metal block set: `PROVISION_MODE=baremetal`, `NODES`,
  `NODE_USER` (the user to create — **not** `devcloud`), `NODE_HOSTS` (real IP),
  `NODE_JUMPS=('')`, `SSH_IDENTITY` (its `.pub` is injected), `UBUNTU_ISO_SHA256`,
  `REIMAGE_HOSTNAME`, `REIMAGE_TARGET_DISK` (or auto-detect + confirm),
  `REIMAGE_NET`. `PROXY_*` reused on the Intel network.

**Commands (from `cluster/`; each is idempotent, `reimage` is the only
destructive one):**
```bash
./10-baremetal-provision.sh capture   # node disk + network identity (read-only)
./10-baremetal-provision.sh fetch      # download + verify ISO, extract vmlinuz/initrd
./10-baremetal-provision.sh seed       # render NoCloud user-data + meta-data
./10-baremetal-provision.sh serve      # serve ISO + seed over HTTP (background)
# confirm REIMAGE_TARGET_DISK and the recovery path, THEN:
ALLOW_REIMAGE=1 ./10-baremetal-provision.sh reimage   # kexec into installer — WIPES the disk
./10-baremetal-provision.sh wait       # block until clean Ubuntu 26.04 returns
./10-baremetal-provision.sh serve-stop
# or, all at once (still gated): ALLOW_REIMAGE=1 ./10-baremetal-provision.sh all
```

**Safety:** `reimage`/`all` refuse to run unless `ALLOW_REIMAGE=1` **and** a
target disk is resolved. Never set `ALLOW_REIMAGE=1` for the user without first
confirming, in the same exchange, that they accept the disk erase and have the
out-of-band recovery path. Echo the captured `REIMAGE_TARGET_DISK` and have them
confirm it is the intended boot disk — a wrong disk is unrecoverable. `capture`'s
static-netplan default returns the node at the IP in `NODE_HOSTS`; warn if
`REIMAGE_NET=dhcp` without a MAC reservation (the node may reappear on a
different IP and look "lost").

**Success:** `./10-baremetal-provision.sh status` reports Ubuntu 26.04, the stock
kernel, key login, and passwordless sudo; after `./01-ssh-config.sh apply`,
`./01-ssh-config.sh check` prints `LIVE`; `./00-probe.sh` then shows the same
starting state as the Intel Cloud image. Continue at Skill 3.

**Common failures:** `UBUNTU_ISO_SHA256` unset/wrong (fetch fails the checksum);
node cannot reach `SEED_HTTP_BIND:SEED_HTTP_PORT` (installer can't fetch ISO/seed
— check the `serve` log and firewall); `REIMAGE_NET=static` without a prior
`capture` (seed refuses — no network identity); the node returns on the *old* OS
(kexec didn't take — re-run `reimage`); node never returns (failed install —
recover via the out-of-band console); Secure Boot still on (node won't boot the
new install's later AET kernel).

---

## Skill 1b — Generate, check, and retire the `~/.ssh/config` stanzas

**When:** twice in the life of an allocation — right after the instances go
**Ready** (generate), and when the reservation ends or is released (retire).
Also any time SSH "suddenly stops working": run `check` before anything else.

**Why it is its own skill:** an allocation is temporary but the `~/.ssh/config`
stanzas it needs are not self-cleaning. When a reservation lapses the aliases
still resolve, the jump host rejects the key, and `sshd` falls back to password
auth — so every toolkit script stops on a prompt that no password can satisfy.
Worse, `-o BatchMode=yes` is **not** inherited by the `ProxyJump` child process,
so the prompt appears even in "non-interactive" runs. Leftover stanzas also
*shadow* a new allocation's, because ssh takes the **first** matching `Host`.

**Preconditions:** `NODES` set, plus `SSH_IDENTITY`, `NODE_USER`, `NODE_HOSTS`,
`NODE_JUMPS`, `JUMP_USER` from the portal's SSH panel (and `PROXY_*` if the
workstation is behind a corporate proxy — the generated jump stanza then carries
the right `ProxyCommand`).

**Commands:**
```bash
./01-ssh-config.sh show     # print the stanzas that WOULD be written
./01-ssh-config.sh apply    # write/refresh them (backs up ~/.ssh/config first)
./01-ssh-config.sh check    # classify every alias: LIVE / STALE / UNREACHABLE / ...
./01-ssh-config.sh remove   # delete the managed block (allocation released)
./01-ssh-config.sh prune                 # report hand-written leftovers
./01-ssh-config.sh prune --force <alias> # ...and delete them (backup taken)
```
Generated stanzas live between `# >>> aet-toolkit managed block ... >>>` markers
so they can be rewritten or removed as a unit; nothing outside the markers is
ever touched without `--force`. Each generated stanza carries `BatchMode yes`,
which is what actually prevents the ProxyJump password prompt.

**How to read `check`:**

| State | Meaning | Do this |
|-------|---------|---------|
| `LIVE` | key accepted, command ran | continue to Skill 2 |
| `STALE` | key rejected / password fallback | two causes — if the jump host authenticated but the node denied `publickey,password`, the key is not on the node: do Skill 1c. If the *jump host* rejects it, check **Reservation End**; if it lapsed, go to Skill 1 |
| `UNREACHABLE` | network path down | proxy, jump host, or VPN — see Skill 0 |
| `NO-STANZA` | alias unknown to ssh | run `apply` |
| `HOSTKEY` | host key changed | a recycled IP from a new allocation; remove the old `known_hosts` entry |

**Success:** `check` prints `LIVE` for every node and
`all N nodes reachable — next: ./00-probe.sh`.

**Common failures:** running `apply` while the previous allocation's
hand-written stanzas are still present — they come first in the file and win, so
`apply` reports them and tells you the exact `prune --force` line; `NODE_HOSTS` /
`NODE_JUMPS` not index-aligned with `NODES` (rejected up front); a node with a
direct route given a jump host anyway (use `''` in `NODE_JUMPS`).

---

## Skill 1c — Enable password-free SSH to the jump host and node

> **Bare-metal path (`PROVISION_MODE=baremetal`) skips this skill.** The
> autoinstall in Skill 1-BM already injected `SSH_IDENTITY.pub` into the new
> node's `authorized_keys`, so there is no password to convert. Use Skill 1b only
> to generate/`check` the (jump-less) stanza.

**When:** immediately after Skill 1b `apply` on a brand-new allocation — before
`check`, `00-probe.sh`, or anything else. Also whenever the node starts asking
for a password again (it was re-imaged).

**Why it is its own skill:** the portal hands out a *password*, not a key. Its
**How to Connect via SSH** panel prints `Username: devcloud Password: devcloud`
and a plain `ssh -J guest@<jump-ip> devcloud@<node-ip>` command, and a freshly
provisioned node has an empty `authorized_keys`. Every script in this toolkit
runs non-interactively — the generated stanza even sets `BatchMode yes` — so
until your key is installed each one dies on a password prompt it cannot answer,
and `01-ssh-config.sh check` reports that as `STALE`, which reads like an expired
reservation. Uploading a key in the portal is **not** sufficient on its own: it
authorizes the **jump host**, while the node still needs the key in its own
`authorized_keys`.

**Preconditions:** Skill 1b `apply` done (so the alias resolves), and the node's
default password from the panel.

**Commands:**
```bash
# 1. the jump host — often already accepts the portal-registered key, so try first
ssh -o BatchMode=yes -o ConnectTimeout=10 guest@<jump-ip> true \
  || ssh-copy-id -i ~/.ssh/id_ed25519_intelcloud.pub -o BatchMode=no guest@<jump-ip>

# 2. the node, through the jump host, using the alias from Skill 1b
ssh-copy-id -i ~/.ssh/id_ed25519_intelcloud.pub -o BatchMode=no icloud-aet0

# 3. confirm, then retire the default password
./01-ssh-config.sh check     # expect LIVE
ssh icloud-aet0 passwd       # replace the default 'devcloud' password
```
`-o BatchMode=no` is load-bearing: the managed stanza sets `BatchMode yes`, which
would suppress the one password prompt you actually need here. Each `ssh-copy-id`
asks for the password once; afterwards the key is in the remote
`~/.ssh/authorized_keys` and nothing prompts again.

If the node's IP was recycled from an earlier allocation, clear the stale host
key first — this is what the panel's `ssh-keygen -R` prefix is for:
```bash
ssh-keygen -R <node-ip>
```

**Success:** `./01-ssh-config.sh check` prints `LIVE`, and
`ssh icloud-aet0 id -un` returns `devcloud` with no prompt.

**Security:** `devcloud`/`devcloud` is published in the portal's own
instructions, so treat it as public. Change it as soon as key access works, and
never paste it into a chat, a script, or an `sshpass` invocation — type it only
at the `ssh-copy-id` prompt.

**Common failures:** omitting `-o BatchMode=no` (the command fails instantly with
`Permission denied` and never prompts); copying the key to the jump host but not
the node (jump authenticates, node still denies `publickey,password`); pointing
`-i` at the private key instead of the `.pub`; a stale `known_hosts` entry for a
recycled IP (reported as `HOSTKEY` — clear it with `ssh-keygen -R`).

---

## Skill 2 — Describe the allocation and probe it

**When:** SSH to each node works; before any change.

**Preconditions:** Skills 1b and 1c done — `./01-ssh-config.sh check` shows every
node `LIVE` with no password prompt.

**Steps:**
1. Create the inventory from the template and edit it for the allocation:
   ```bash
   cp inventory.env.example inventory.env
   ```
   Set `NODES` (the single node's alias), the kernel/Grafana variables, and
   optionally `EXPECT_CPU_MODEL` to the CPU model the catalog promised.
   `inventory.env` is the single source of truth; no secrets live in it (keys
   stay in `~/.ssh`) — it is gitignored because it holds site-specific
   hostnames.
2. Probe (read-only):
   ```bash
   ./00-probe.sh
   ```

**Success:** the probe reports the node's CPU/topology, confirms reachability
with no errors, and the summary prints the node's CPU model (matching
`EXPECT_CPU_MODEL` if set). Copy the `STOCK_KERNEL=` line it prints into
`inventory.env`.

**Common failures:** `NODES` holds more than one node (`load_inventory` rejects
it — this demo is single-node); alias in `inventory.env` that has no
`~/.ssh/config` stanza (warned, then used as a literal hostname); the CPU model
does not match `EXPECT_CPU_MODEL` — stop and check you got the right instance
type before building a kernel; *node not reachable* — check the reservation is
still live before debugging SSH.

---

## Skill 3 — Build the AET-enabled kernel

**When:** after the inventory is set; before touching the node's kernel.

**Preconditions:** `docker` on the build host (the workstation is fine);
outbound access to the source (the Ubuntu archive for a deb build, or
`KERNEL_REPO` for a git/rpm build); a **live node** (`capture` reads from it
over SSH); kernel vars in `inventory.env` (`KERNEL_SOURCE`, `KERNEL_PKG`,
`KERNEL_TAG`, `KERNEL_LOCALVERSION`, `KERNEL_BUILD_DIR`).

**Background:** AET needs three options —
`CONFIG_X86_CPU_RESCTRL_INTEL_AET`, `CONFIG_INTEL_RAPL_TPMI`, and
`CONFIG_CGROUP_BPF` — but on Ubuntu 26.04 the latter two are **already** set
(`=m` and `=y`). Only the AET option is missing, and Ubuntu 26.04's Linux v7.0
already contains the full AET implementation; Canonical just does not enable it.

So this skill does **not** install a different kernel. It rebuilds *the node's
own Ubuntu kernel* from **Ubuntu's `linux` source package**, with that one option
turned on. Ubuntu's patches and its LTS security-update commitment are preserved,
and there is no OS change — Intel Cloud already provisions Ubuntu 26.04. By
default the build takes the archive's **current** (fully patched) source, which
is usually newer than the kernel the node shipped with; Ubuntu retains only the
newest `linux` source, so pinning an older version requires an archive snapshot.
The base config is the node's live `/boot/config-$(uname -r)` (captured over SSH,
never the build host's), so all of its boot/NIC/NVMe drivers survive. Docker
gives a reproducible toolchain, with the base image tracking the node's series.

**When to build from Ubuntu source vs a git tag.** Because the node runs Ubuntu
26.04 — which every path in this guide provisions — build from **Ubuntu's
source** (`KERNEL_SOURCE=ubuntu`, the default): the AET code is already in
Ubuntu's own v7.0 kernel, so only the disabled config option has to be turned on.
Reach for `KERNEL_SOURCE=git` (a mainline tag such as `v7.0` via
`KERNEL_REPO`/`KERNEL_BRANCH`) **only** when the base OS is *not* Ubuntu 26.04 —
e.g. an RPM distro whose shipped kernel lacks AET and has no Ubuntu source to
rebuild. On an Ubuntu 26.04 node the git path is the wrong choice: it discards
Ubuntu's patches and multi-year security-update commitment for no benefit.

**Package format (`KERNEL_PKG`).** `auto` (default) detects the node's family on
`capture` (dpkg→deb, rpm→rpm). A `.deb` build runs in `ubuntu-build.Docker`; a
`.rpm` build runs in `rocky-build.Docker` (a Rocky Linux container), so the
build host needs only Docker either way — no rpm tooling. Because an RPM node has
no Ubuntu source package, `KERNEL_PKG=rpm` **requires** `KERNEL_SOURCE=git`; the
build refuses `rpm` + `ubuntu` up front. Set `KERNEL_BRANCH` to a mainline tag
that already carries the AET resctrl code.

**Secure Boot:** the rebuilt kernel is unsigned. `mokutil --sb-state` must report
Secure Boot disabled (it is on Intel Cloud bare metal) or it will not boot.

**Steps (on the build host, Docker required):**
```bash
./20-kernel-build.sh all
#   capture → node's stock /boot/config + Ubuntu series + linux source version
#             + package family (NODE_PKG: deb/rpm)
#   build   → dockerized package build (deb from Ubuntu source, rpm from a git
#             tag), AET enabled
#   verify  → confirm the package embeds the required CONFIG_* symbols
```
`all` runs capture → build → build-wait → verify and blocks until finished. The
build itself is **detached** (it survives the SSH session that started it), so
for a long build prefer driving the phases yourself and checking in:
```bash
./20-kernel-build.sh capture        # needs the node up; seconds
./20-kernel-build.sh build          # returns immediately, build runs detached
./20-kernel-build.sh build-status   # RUNNING/exit code + last 20 log lines
./20-kernel-build.sh build-wait     # block until it finishes
./20-kernel-build.sh verify
```

**Budget the reservation window.** The build is the long pole and it cannot be
done ahead of time: `capture` reads `/boot/config-$(uname -r)` from the **live**
node, so the reservation must already be running. Meanwhile the build
itself runs entirely on the build host and does **not** need the node, so the
order that wastes the least reservation time is:

1. The moment the node is `Ready`: Skill 1b → Skill 2 → `20-kernel-build.sh
   capture` → `build` (detached).
2. While it builds, do anything else that does not need the new kernel.
3. `verify`, then Skill 4 (install → one-shot boot → promote), which needs a
   reboot window.

A distro config builds thousands of modules, so on a small build host this is
hours, not minutes — measure yours with `build-status` rather than guessing, and
use the console's **Extend** action before **Reservation End** if the window
gets tight. Note the approval queue (1–2 business days) is *before* the clock
starts; the reservation counts from when the instance goes `Ready`.

**Success:** a `linux-image-<release>-aet_*.deb` (plus headers) — or, on an rpm
node, a `kernel-<release>.rpm` under `kernel/build/rpm/` — is produced next
to an `aet-build-provenance.txt`, and `verify` confirms
`X86_CPU_RESCTRL_INTEL_AET`, `INTEL_RAPL_TPMI`, and `CGROUP_BPF` are set, no
NIC/NVMe driver regressed, and the kernel release matches `KERNEL_TAG`.
(For rpm, `verify` extracts the embedded config with `bsdtar` or `rpm2cpio`+`cpio`;
install one on the build host, since `verify` fails rather than degrading if it
cannot read the embedded config.)

> The release follows the **upstream point release** of the Ubuntu source, not
> the Ubuntu version string: source `7.0.0-29.29` is upstream v7.0.12 and yields
> `7.0.12-aet`. It moves with each Ubuntu update, so take the value `verify`
> prints and put it in `KERNEL_TAG` — Skill 4 uses it to find the GRUB entry.

**Common failures:** `docker` missing; no route to the Ubuntu archive (the
container runs `apt-get source`); pinning `UBUNTU_KERNEL_VERSION` to a version
the archive no longer carries — Ubuntu keeps only the current `linux` source, so
clear the pin or use an archive snapshot; running `capture` before the node is
`Ready` (it needs a live SSH session); `KERNEL_TAG` not matching the release the
build produces (`verify` catches this — left uncorrected, Skill 4 would pin the
wrong grub entry); starting the build late in a short reservation. With
`KERNEL_SOURCE=git`, a `KERNEL_BRANCH` too old to carry the AET symbol — the
build now refuses such a tree up front instead of silently producing a kernel
without AET.

---

## Skill 4 — Install and promote the AET kernel

**When:** the `.deb` or `.rpm` is built and verified.

**Preconditions:** Skill 3 done; an **out-of-band power-cycle / recovery path**
for the allocation (a bad boot must be recoverable). On an rpm node, `grubby`
(and `grub2-reboot` for the one-shot boot) must be present — the standard grub2
packages provide them.

**Steps:**
```bash
./21-kernel-install.sh ship install   # copy package + install on the node
./21-kernel-install.sh status         # installed kernels + boot default
```
The step auto-detects the node's package family: a deb node uses `dpkg -i` +
`update-grub`; an rpm node uses `rpm -i` + `grubby`. Either way it adds the
required `rdt=perf` kernel command line and **does not change the boot default**.
Boot the node into the new kernel, verify it, then promote:
```bash
ALLOW_REBOOT=1 ./21-kernel-install.sh oneshot  <node>   # one-shot boot
ALLOW_REBOOT=1 ./21-kernel-install.sh promote  <node>   # make it the default
```

**Success:** after the one-shot boot the node comes back on the `-aet` kernel;
`status` shows it installed; after `promote` it is the grub default.

**Safety:** never set `ALLOW_REBOOT=1` without confirming the recovery path.
Keep the order install → oneshot → verify → promote so a bad boot self-recovers.

**Common failures:** promoting before verifying a healthy boot; no recovery path
when a node fails to come back; `rdt=perf` missing (install adds it — check the
command line if AET counters are absent).

---

## Skill 5 — Smoke-test AET on a booted node

**When:** right after the node boots the `-aet` kernel; before k3s. This is also
the **entry point for a bring-your-own node that already runs an AET kernel** —
run it first to confirm the counters, then continue at Skill 6.

**Preconditions:** the node is running the AET kernel; run as root on the node.

**Steps:**
```bash
sudo ./aet-check.sh   # copy to the node, or run over SSH as root
```
It mounts `resctrl`, confirms the AET/BPF/RAPL config, checks the RAPL powercap,
and verifies `rdt=perf` on the command line.

**Success:** the AET counters exist under
`/sys/fs/resctrl/mon_data/mon_PERF_PKG_00/` (`core_energy`, `activity`,
`uops_retired`, `unhalted_core_cycles`, …).

**Common failures:** wrong instance type (Xeon 6, not 6+) → no counters at all;
booted the stock kernel instead of `-aet`; `rdt=perf` not on the command line.

---

## Skill 6 — Bring up the k3s cluster

**When:** the node passes `aet-check.sh`.

**Preconditions:** kernel installed on the node.

**Steps:**
```bash
./30-k3s-up.sh up       # prereqs → NRI → server → labels
./30-k3s-up.sh status   # kubectl get nodes -o wide (via the server)
```
NRI (Node Resource Interface, required by `nri-resctrl-mon`) is enabled on the
node, and the AET-capable node is labelled `energy.intel.com/aet=true`.

**Success:** `status` shows the node `Ready`, carrying the
`energy.intel.com/aet=true` label.

**Common failures:** NRI not enabled; node not labelled (the telemetry
DaemonSets will not schedule there).

---

## Skill 7 — Deploy the AET telemetry stack

**When:** the cluster is `Ready`.

**Preconditions:** Skill 6 done. The `nri-resctrl-mon` image may need to be
built and imported first (it is not yet on a public registry). The plugin and
its `goresctrl` dependency (resctrl monitor + OTel export) live on public forks;
`build-nri-image.sh` clones them on demand from the `NRI_REPO`/`NRI_BRANCH` and
`GORESCTRL_REPO`/`GORESCTRL_BRANCH` set in `inventory.env` (defaults:
`cmcantalupo/nri-plugins@resctrl-mon-goresctrl` and
`cmcantalupo/goresctrl@resctrl-mon`). Set `NRI_SRC`/`GORESCTRL_SRC` to build
from existing local checkouts instead.
```bash
./telemetry/build-nri-image.sh   # clone/refresh forks + build + import into the node
```

**Steps:**
```bash
./40-deploy-telemetry.sh dt1      # namespace + kube-state-metrics + Prometheus + Grafana
./40-deploy-telemetry.sh dt2      # otel-collector-resctrl + rapl-node-exporter + nri-resctrl-mon
./40-deploy-telemetry.sh status
```
This applies the manifests under `cluster/telemetry/` into the `monitoring`
namespace. Prometheus is on NodePort **30090**, Grafana on NodePort **30030**,
with two dashboards pre-provisioned (**Kubernetes Pod Energy** and **Kubernetes
Pod Perf Counters**).

**Success:** `status` shows all pods `Running` in `monitoring`, including the
`nri-resctrl-mon` DaemonSet on the AET node.

**Common failures:** `nri-resctrl-mon` image not imported (ImagePullBackOff);
DaemonSet not scheduled (node missing the `energy.intel.com/aet=true` label);
namespace applied but pods `Pending` (resources/taints).

---

## Skill 8 — Validate live per-Pod telemetry

**When:** the stack pods are `Running`.

**Preconditions:** Skill 7 done.

**Steps:**
```bash
./40-deploy-telemetry.sh verify   # active Prometheus targets + AET/RAPL series present
./60-validate.sh snapshot         # per-node RAPL + AET power, live
```
`60-validate.sh` also offers `power`, `eff`, `energy <dur>`, and `query`.

**Success:** `verify` shows Prometheus targets up and AET/RAPL series present;
`snapshot` prints non-zero per-node power that tracks the node's activity.

**Common failures:** no series → walk the pipeline backwards (Pod logs of
`nri-resctrl-mon` → `otel-collector-resctrl` → Prometheus targets); counters
present on the node but not in Prometheus → collector/scrape config.

---

## Skill 9 — View or publish the Grafana dashboards

**When:** telemetry is validated.

**Preconditions:** Skill 8 done. The Intel Cloud node is reachable only from the
workstation, so a browser cannot hit the NodePort directly — use one of two
patterns.

**Operator-local view (just you):**
```bash
./70-grafana-tunnel.sh local   # then open http://localhost:3000
```

**Publish over HTTPS for a user (developer-cloud pattern):** set `PUBLISH_HOST`
(and `GRAFANA_NODE_TARGET` if needed) in `inventory.env`, then:
```bash
./70-grafana-tunnel.sh up       # reverse-tunnel Grafana to PUBLISH_HOST (run on the workstation)
./70-grafana-tunnel.sh status   # 200/200 = healthy chain; 503/000 = tunnel down
# share: https://PUBLISH_HOST:3443/   (self-signed cert expected)
./70-grafana-tunnel.sh down     # tear the tunnel down
```
The chain is: browser → `PUBLISH_HOST:3443` (TLS proxy) → `127.0.0.1:3008`
(plain-HTTP backend) → SSH reverse tunnel → `<server>:30030`. SSH never
terminates TLS.

**Success:** the dashboards load; logging in with the Grafana admin credentials
(username `admin` by default; password from the `grafana-admin` Secret — set
`GRAFANA_ADMIN_PASSWORD` in `inventory.env` or use the random one the deploy
prints once; anonymous access is disabled) shows live joules, watts, and
micro-op counters per Pod.

**Common failures:** `status` shows 503/000 (tunnel down — re-run `up`); default
credentials left in place before publishing; `PUBLISH_HOST` unset when trying to
publish (use `local` instead).

---

## Skill 10 — Deploy the user's own workloads

**When:** the dashboards are live.

**Preconditions:** a running cluster with the telemetry stack.

**Steps:** it is a normal Kubernetes cluster — deploy anything:
```bash
ssh icloud-aet0 'sudo k3s kubectl create deployment my-workload \
    --image=<your-image> --replicas=4'
```
Every Pod automatically gets its own resctrl monitoring group, so within a few
scrape intervals it appears on the AET dashboards.

**Success:** the new Pods show up on the **Kubernetes Pod Energy** / **Perf
Counters** dashboards within a scrape interval or two.

**Use it to:** compare two implementations of the same service, find which Pods
dominate a node's energy budget, or correlate joules/watts with retired
micro-ops (the unique AET efficiency signal).

---

## Skill 11 — Clean up and release the allocation

**When:** the demo is done.

**Preconditions:** the user wants to tear everything down (destructive —
confirm first).

**Steps:**
```bash
ssh icloud-aet0 'sudo /usr/local/bin/k3s-uninstall.sh'        # k3s server
```
Then release the allocation from the Intel Cloud Services console, and retire
the SSH stanza so it cannot shadow the next allocation (Skill 1b):
```bash
./01-ssh-config.sh remove
```

**Success:** k3s is removed from the node, the allocation is released so it
stops billing, and `./01-ssh-config.sh check` no longer lists the alias.

**Common failures:** forgetting to release the allocation (continued billing);
leaving the SSH stanza behind — the next allocation's `apply` will be shadowed by
it, and any toolkit command aimed at a dead alias stops on a jump-host password
prompt.
