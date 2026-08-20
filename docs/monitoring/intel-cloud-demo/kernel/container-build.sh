#!/bin/bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Trust model: by default the source is Ubuntu's own `linux` source package,
# fetched from the distro archive over HTTPS (TLS authenticates the server, the
# archive signature authenticates the package) and pinned to the exact version
# the target node runs. That keeps Ubuntu's patches and its LTS security-update
# commitment, so the only delta this script introduces is the config below.
# Set AET_KERNEL_SOURCE=git to build a mainline tag instead (AET_KERNEL_REPO at
# AET_KERNEL_BRANCH); a tag ref makes that checkout deterministic, and you can
# add `git tag -v` to verify its PGP signature.
#
# The resulting kernel is UNSIGNED by design: SYSTEM_TRUSTED_KEYS /
# SYSTEM_REVOCATION_KEYS are cleared below (Ubuntu points them at
# debian/canonical-certs.pem, which only exists inside Ubuntu's own packaging)
# and the demo boots with Secure Boot OFF.

set -euo pipefail

WORKSPACE=${AET_WORKSPACE:-/workspace}
SRC_ROOT=${AET_SRC_DIR:-${WORKSPACE}/src}
BUILD_DIR=${AET_BUILD_DIR:-${WORKSPACE}/build}
TMP_DIR=${AET_TMP_DIR:-${WORKSPACE}/tmp}
HOST_CONFIG=${HOST_KERNEL_CONFIG:-${WORKSPACE}/host-kernel.config}
KERNEL_SOURCE=${AET_KERNEL_SOURCE:-ubuntu}
UBUNTU_KERNEL_VERSION=${AET_UBUNTU_KERNEL_VERSION:-}
UBUNTU_SERIES=${AET_UBUNTU_SERIES:-}
KERNEL_REPO=${AET_KERNEL_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}
KERNEL_BRANCH=${AET_KERNEL_BRANCH:-v7.0}
LOCALVERSION=${AET_KERNEL_LOCALVERSION:--aet}
SLIM_DEBUG=${AET_SLIM_DEBUG:-0}
TARGET_UID=${AET_TARGET_UID:-0}
TARGET_GID=${AET_TARGET_GID:-0}
ARCH_DIR=${AET_RPM_ARCH_DIR:-$(uname -m)}
REPO_DIR=""
SRC_VERSION=""

export TMPDIR="${TMP_DIR}"
export LOCALVERSION="${LOCALVERSION}"
umask 022

mkdir -p "${WORKSPACE}" "${BUILD_DIR}"
rm -rf "${SRC_ROOT}" "${TMP_DIR}"
mkdir -p "${SRC_ROOT}" "${TMP_DIR}"
find "${BUILD_DIR}" -mindepth 1 -delete 2>/dev/null || true

if [[ ! -f "${HOST_CONFIG}" ]]; then
    echo "Missing host kernel config at ${HOST_CONFIG}" >&2
    exit 1
fi

PATCH_DIR=${AET_PATCH_DIR:-/tmp/patches}

case "${KERNEL_SOURCE}" in
ubuntu)
    apt-get update
    cd "${SRC_ROOT}"
    # Sandboxed downloads fail as root; the archive signature still gates the source.
    apt-get -o APT::Sandbox::User=root source \
        "linux${UBUNTU_KERNEL_VERSION:+=${UBUNTU_KERNEL_VERSION}}"
    REPO_DIR=$(find "${SRC_ROOT}" -maxdepth 1 -mindepth 1 -type d -name 'linux-*' | head -1)
    [[ -n "${REPO_DIR}" ]] || { echo "apt-get source produced no linux-* tree" >&2; exit 1; }
    cd "${REPO_DIR}"
    SRC_VERSION=$(dpkg-parsechangelog -S Version)
    echo "Using Ubuntu source package linux ${SRC_VERSION}"
    # Upstream `bindeb-pkg` generates its own debian/, so Ubuntu's packaging
    # directories must go; the config references to canonical-certs.pem are
    # cleared below for the same reason.
    rm -rf debian debian.master debian.hwe* 2>/dev/null || true
    ;;
git)
    REPO_DIR="${SRC_ROOT}/linux"
    git clone --depth 1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${REPO_DIR}"
    cd "${REPO_DIR}"
    git config --global --add safe.directory "${REPO_DIR}" >/dev/null 2>&1 || true
    SRC_VERSION="${KERNEL_BRANCH}"
    ;;
*)
    echo "AET_KERNEL_SOURCE must be 'ubuntu' or 'git' (got '${KERNEL_SOURCE}')" >&2
    exit 1
    ;;
esac

if [[ -d "${PATCH_DIR}" ]]; then
    for p in "${PATCH_DIR}"/*.patch; do
        [[ -f "${p}" ]] || continue
        echo "Applying patch: $(basename "${p}")"
        git apply "${p}"
    done
fi

# scripts/config happily writes a symbol the tree does not define, and
# olddefconfig then strips it — yielding a kernel with no AET support that only
# fails hours later. Validate AFTER patches so a patch that adds AET support to
# an older tree is honoured; refuse to build a tree that still lacks the symbol.
grep -rqs 'config X86_CPU_RESCTRL_INTEL_AET' arch/x86/ || {
    echo "FATAL: this kernel tree defines no X86_CPU_RESCTRL_INTEL_AET symbol" >&2
    echo "       (source=${KERNEL_SOURCE} version=${SRC_VERSION}) — AET is unsupported here" >&2
    echo "       (checked after applying any patches in ${PATCH_DIR})" >&2
    exit 1
}

cp "${HOST_CONFIG}" .config
scripts/config --file .config --set-str SYSTEM_TRUSTED_KEYS ""
scripts/config --file .config --set-str SYSTEM_REVOCATION_KEYS ""
scripts/config --file .config --enable X86_CPU_RESCTRL
scripts/config --file .config --enable X86_CPU_RESCTRL_INTEL_AET
scripts/config --file .config --enable CPU_SUP_INTEL
scripts/config --file .config --enable INTEL_PMT
scripts/config --file .config --enable INTEL_PMT_TELEMETRY
scripts/config --file .config --enable INTEL_TPMI
scripts/config --file .config --enable INTEL_VSEC
scripts/config --file .config --enable CGROUP_BPF
scripts/config --file .config --module INTEL_RAPL_TPMI

if [[ "${SLIM_DEBUG}" == "1" ]]; then
    # Much faster build and no ~1.6GB -dbg package, but it also drops BTF, which
    # Ubuntu ships enabled and BPF/CO-RE tooling depends on. Opt-in only.
    scripts/config --file .config --disable DEBUG_INFO_BTF
    scripts/config --file .config --enable DEBUG_INFO_NONE
fi

make olddefconfig

grep -qx 'CONFIG_X86_CPU_RESCTRL_INTEL_AET=y' .config || {
    echo "FATAL: CONFIG_X86_CPU_RESCTRL_INTEL_AET is unset after olddefconfig" >&2
    exit 1
}

KERNEL_RELEASE=$(make -s kernelrelease)

{
    echo "kernel-release=${KERNEL_RELEASE}"
    echo "source-mode=${KERNEL_SOURCE}"
    if [[ "${KERNEL_SOURCE}" == "ubuntu" ]]; then
        echo "ubuntu-series=${UBUNTU_SERIES}"
        echo "ubuntu-source-version=${SRC_VERSION}"
    else
        echo "git-repo=${KERNEL_REPO}"
        echo "git-ref=${KERNEL_BRANCH}"
    fi
    echo "localversion=${LOCALVERSION}"
    echo "slim-debug=${SLIM_DEBUG}"
    echo "built-at=$(date -Is)"
} > "${BUILD_DIR}/aet-build-provenance.txt"

if [[ -f /etc/lsb-release ]]; then
    export DEB_BUILD_OPTIONS="parallel=$(nproc)"

    make -j"$(nproc)" bindeb-pkg

    find "${SRC_ROOT}" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.changes' -o -name '*.buildinfo' \) -exec cp -p {} "${BUILD_DIR}" \;
else
    RPMBUILD_ROOT=${REPO_DIR}/rpmbuild
    mkdir -p "${RPMBUILD_ROOT}/BUILD" "${RPMBUILD_ROOT}/RPMS" \
             "${RPMBUILD_ROOT}/SOURCES" "${RPMBUILD_ROOT}/SPECS" \
             "${RPMBUILD_ROOT}/SRPMS"

    rpmdev-setuptree >/dev/null 2>&1 || true

    make -j"$(nproc)" rpm-pkg

    RPM_OUTPUT_DIR="${RPMBUILD_ROOT}/RPMS/${ARCH_DIR}"
    SRPM_OUTPUT_DIR="${RPMBUILD_ROOT}/SRPMS"

    if [[ -d "${RPM_OUTPUT_DIR}" ]]; then
        find "${RPM_OUTPUT_DIR}" -maxdepth 1 -type f -name '*.rpm' -exec cp -p {} "${BUILD_DIR}" \;
    fi

    if [[ -d "${SRPM_OUTPUT_DIR}" ]]; then
        find "${SRPM_OUTPUT_DIR}" -maxdepth 1 -type f -name '*.src.rpm' -exec cp -p {} "${BUILD_DIR}" \;
    fi
fi

if [[ "${TARGET_UID}" != "0" ]]; then
    chown -R "${TARGET_UID}:${TARGET_GID}" "${BUILD_DIR}" "${SRC_ROOT}" || true
fi

find "${BUILD_DIR}"
