# Kernel Build Helpers

This directory contains the tooling used to generate Application Energy
Telemetry capable kernels inside containerized build environments. It provides
separate flows for Debian-based and RPM-based packaging while keeping the host
workspace clean.

## Host entry point

- **build.sh** – builds the appropriate container image, creates a temporary
  Docker volume, copies the host kernel configuration and any patches into the
  container, runs the kernel build, and copies the resulting artifacts back to
  the host. The package format is chosen by the first argument (`deb` or `rpm`);
  with no argument it auto-detects — if `/etc/lsb-release` exists the Debian
  workflow runs and populates `build/deb/`, otherwise the RPM workflow runs and
  populates `build/rpm/`. The `.deb` build uses `ubuntu-build.Docker` and the
  `.rpm` build uses `rocky-build.Docker`, so the build host only needs Docker for
  either format. The `cluster/20-kernel-build.sh` wrapper passes this argument
  automatically from the node's detected package family (`KERNEL_PKG`).

Run the helper from the repository root:

```bash
cd kernel
./build.sh          # auto-detect from the build host
./build.sh rpm      # or force a format (rpm requires AET_KERNEL_SOURCE=git)
```

Ensure the running host's /boot/config-$(uname -r) is present before invoking
the helper; the container entry point requires this configuration.

By default the wrapper copies /boot/config-$(uname -r) into
host-kernel.config at the start of each run. To supply an alternate
configuration (for example, when building on WSL or using a tuned config), set
``AET_HOST_CONFIG_SOURCE`` to the path of the desired file before invoking
build.sh. The file is copied into host-kernel.config for the container to
consume and removed after the build completes.

The `build/deb/` and `build/rpm/` directories are populated by this script and
can be safely pruned between runs.

## Patches

Place `.patch` files (in `git apply` format) in the `patches/` subdirectory.
They are automatically copied into the container and applied to the kernel
source tree after cloning, before the build begins. Patches are applied in
filename sort order. If no `patches/` directory exists or it contains no
`.patch` files the step is skipped.

## Container entry point

- **container-build.sh** – shared entrypoint for both the Ubuntu and Rocky
  images. It obtains the kernel source in one of two modes selected by
  `AET_KERNEL_SOURCE`: `ubuntu` (the default) rebuilds the distro's own `linux`
  source package with `apt-get source`, keeping Ubuntu's patches and its LTS
  security updates, while `git` clones `AET_KERNEL_REPO` at `AET_KERNEL_BRANCH`.
  It then applies any patches found in the patch directory, applies the provided
  kernel configuration (enabling the AET options and refusing to build a tree
  that does not define them), and chooses between Debian (`make bindeb-pkg`) or
  RPM (`make rpm-pkg`) flows based on the presence of `/etc/lsb-release`.

## Dockerfiles

- **ubuntu-build.Docker** – Ubuntu base image that installs kernel build
  dependencies and sets `container-build.sh` as its entry point. The
  `UBUNTU_IMAGE` build argument selects the base (default `ubuntu:26.04`) and
  should track the Ubuntu series of the node whose kernel is being rebuilt.
- **rocky-build.Docker** – Rocky Linux 10 image configured with the
  required development toolchains and the same `container-build.sh` entry
  point. The `ROCKY_BASE_IMAGE` build argument allows overriding the default
  registry source.
- **host-kernel.config** (generated) – temporary copy of the host's running
  kernel configuration seeded into the container when available.

## Environment Variables

### Host variables (set before invoking `build.sh`)

| Variable | Default | Description |
|---|---|---|
| `AET_HOST_CONFIG_SOURCE` | *(unset)* | Path to a kernel `.config` file. When set, this is used instead of `/boot/config-$(uname -r)`. |
| `AET_KERNEL_LOCALVERSION` | *(unset; container defaults to `-aet`)* | Suffix appended to the kernel version string (e.g. `-aet-monotone` produces `7.0.0-aet-monotone`). Forwarded into the container when set. |
| `AET_UBUNTU_IMAGE` | *(unset; Dockerfile defaults to `ubuntu:26.04`)* | Base image for the Ubuntu Dockerfile, passed as the `UBUNTU_IMAGE` build argument. Should track the target node's Ubuntu series; append `@sha256:...` to pin it. |

### Container variables (used by `container-build.sh`)

These are set automatically by `build.sh` but can be overridden when running the container directly.

| Variable | Default | Description |
|---|---|---|
| `AET_WORKSPACE` | `/workspace` | Root workspace directory inside the container. |
| `AET_SRC_DIR` | `${AET_WORKSPACE}/src` | Directory where the kernel source tree is cloned. |
| `AET_BUILD_DIR` | `${AET_WORKSPACE}/build` | Output directory for built packages (`.deb` or `.rpm`). |
| `AET_TMP_DIR` | `${AET_WORKSPACE}/tmp` | Temporary directory used during the build (`TMPDIR`). |
| `AET_KERNEL_SOURCE` | `ubuntu` | Where the source comes from: `ubuntu` (the distro's `linux` source package) or `git` (a mainline clone). |
| `AET_UBUNTU_KERNEL_VERSION` | *(unset)* | Exact `linux` source package version to rebuild, e.g. `7.0.0-22.22`. Unset fetches the archive's current version. `ubuntu` mode only. |
| `AET_UBUNTU_SERIES` | *(unset)* | Ubuntu codename of the target node, recorded in the build provenance. |
| `AET_SLIM_DEBUG` | `0` | `1` disables debug info: much faster build and no large `-dbg` package, but **drops BTF**, which Ubuntu ships enabled and BPF/CO-RE tooling relies on. |
| `AET_KERNEL_REPO` | `https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git` | Git repository URL to clone. `git` mode only. |
| `AET_KERNEL_BRANCH` | `v7.0` | Git branch or tag to check out. `git` mode only. |
| `AET_KERNEL_LOCALVERSION` | `-aet` | Kernel `LOCALVERSION` suffix. |
| `AET_PATCH_DIR` | `/tmp/patches` | Directory containing `.patch` files to apply after cloning. Populated automatically by `build.sh` from the host `patches/` subdirectory. |
| `AET_TARGET_UID` | `0` | UID to chown build artifacts to (set by `build.sh` to the host user). |
| `AET_TARGET_GID` | `0` | GID to chown build artifacts to (set by `build.sh` to the host group). |
| `AET_RPM_ARCH_DIR` | `$(uname -m)` | Architecture subdirectory under `rpmbuild/RPMS/` for RPM output. |
| `HOST_KERNEL_CONFIG` | `${AET_WORKSPACE}/host-kernel.config` | Path to the host kernel `.config` copied into the container. |

### Docker build arguments

| Argument | Default | Description |
|---|---|---|
| `UBUNTU_IMAGE` | `ubuntu:26.04` | Base image for the Ubuntu Dockerfile. |
| `ROCKY_BASE_IMAGE` | `quay.io/rockylinux/rockylinux:10` | Base image for the Rocky Linux Dockerfile. |

## Installing and promoting the built kernel

The `build/deb/` and `build/rpm/` artifacts are shipped to and installed on the
node by `cluster/21-kernel-install.sh`, which handles both package families:

- **deb node** – `dpkg -i` the image + headers, append `rdt=perf` to
  `GRUB_CMDLINE_LINUX`, and manage the boot entry with `update-grub` /
  `grub-reboot` / `grub-set-default`.
- **rpm node** – `rpm -i` the kernel package and manage the boot entry with
  `grubby` (`--args=rdt=perf`, `--set-default`) and `grub2-reboot` for one-shot
  boots.

In both cases the install **never changes the boot default on its own**: the
stock kernel stays default until an explicit `promote`, so a bad boot
self-recovers. See the demo `README.md` "Update the kernel" section and
`SKILLS.md` Skill 4 for the ship → install → one-shot → verify → promote flow.
