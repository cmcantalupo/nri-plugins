#!/bin/bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -euox pipefail

if [[ $# -eq 1 ]]; then
    MODE=$1
    if [[ "${MODE}" != "rpm" ]] && [[ "${MODE}" != "deb" ]]; then
        echo "Usage $0 [rpm|deb]" 1>&2
	exit 1
    fi
elif [[ -f /etc/lsb-release ]]; then
    MODE="deb"
else
    MODE="rpm"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOST_CONFIG="${SCRIPT_DIR}/host-kernel.config"
HOST_CONFIG_SOURCE="${AET_HOST_CONFIG_SOURCE:-}"
REMOVE_HOST_CONFIG=0
CONTAINER_CONFIG_PATH="/tmp/host-kernel.config"
CONTAINER_BUILD_PATH="/workspace/build"
CONTAINER_SRC_PATH="/workspace/src"
CONTAINER_TMP_PATH="/workspace/tmp"
VOLUME_PREFIX="aet-kernel-build"
CONTAINER_ID=""
WORKSPACE_VOLUME=""


if [[ "${MODE}" == "deb" ]]; then
    IMAGE_TAG="ubuntu-build-aet-kernel"
    DOCKERFILE="${SCRIPT_DIR}/ubuntu-build.Docker"
else
    IMAGE_TAG="rocky-build-aet-kernel"
    DOCKERFILE="${SCRIPT_DIR}/rocky-build.Docker"
fi
BUILD_DIR="${SCRIPT_DIR}/build/${MODE}"

if [[ -n "${HOST_CONFIG_SOURCE}" ]]; then
    if [[ ! -f "${HOST_CONFIG_SOURCE}" ]]; then
        echo "Provided AET_HOST_CONFIG_SOURCE not found: ${HOST_CONFIG_SOURCE}" >&2
        exit 1
    fi
    cp -p "${HOST_CONFIG_SOURCE}" "${HOST_CONFIG}"
    REMOVE_HOST_CONFIG=1
elif [[ -f /boot/config-$(uname -r) ]]; then
    cp -p "/boot/config-$(uname -r)" "${HOST_CONFIG}"
    REMOVE_HOST_CONFIG=1
elif [[ -f "${HOST_CONFIG}" ]]; then
    echo "Using existing host kernel config at ${HOST_CONFIG}" >&2
else
    echo "No kernel configuration available. Set AET_HOST_CONFIG_SOURCE or ensure /boot/config-$(uname -r) exists." >&2
    exit 1
fi

cleanup() {
    if [[ "${REMOVE_HOST_CONFIG}" == "1" ]]; then
        rm -f "${HOST_CONFIG}"
    fi
    if [[ -n "${CONTAINER_ID}" ]]; then
        docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${WORKSPACE_VOLUME}" ]]; then
        docker volume rm "${WORKSPACE_VOLUME}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

docker build "${SCRIPT_DIR}" \
    -f "${DOCKERFILE}" \
    ${AET_UBUNTU_IMAGE:+--build-arg UBUNTU_IMAGE="${AET_UBUNTU_IMAGE}"} \
    -t "${IMAGE_TAG}"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

WORKSPACE_VOLUME="${VOLUME_PREFIX}-$(date +%s)-$RANDOM"
docker volume create "${WORKSPACE_VOLUME}" >/dev/null

CONTAINER_ID=$(docker create \
    -e HOST_KERNEL_CONFIG="${CONTAINER_CONFIG_PATH}" \
    -e AET_BUILD_DIR="${CONTAINER_BUILD_PATH}" \
    -e AET_SRC_DIR="${CONTAINER_SRC_PATH}" \
    -e AET_TMP_DIR="${CONTAINER_TMP_PATH}" \
    -e AET_TARGET_UID="$(id -u)" \
    -e AET_TARGET_GID="$(id -g)" \
    ${AET_KERNEL_LOCALVERSION:+-e AET_KERNEL_LOCALVERSION="${AET_KERNEL_LOCALVERSION}"} \
    ${AET_KERNEL_SOURCE:+-e AET_KERNEL_SOURCE="${AET_KERNEL_SOURCE}"} \
    ${AET_UBUNTU_KERNEL_VERSION:+-e AET_UBUNTU_KERNEL_VERSION="${AET_UBUNTU_KERNEL_VERSION}"} \
    ${AET_UBUNTU_SERIES:+-e AET_UBUNTU_SERIES="${AET_UBUNTU_SERIES}"} \
    ${AET_SLIM_DEBUG:+-e AET_SLIM_DEBUG="${AET_SLIM_DEBUG}"} \
    ${AET_KERNEL_REPO:+-e AET_KERNEL_REPO="${AET_KERNEL_REPO}"} \
    ${AET_KERNEL_BRANCH:+-e AET_KERNEL_BRANCH="${AET_KERNEL_BRANCH}"} \
    -v "${WORKSPACE_VOLUME}:/workspace" \
    "${IMAGE_TAG}")

docker cp "${HOST_CONFIG}" "${CONTAINER_ID}:${CONTAINER_CONFIG_PATH}"

PATCH_DIR="${SCRIPT_DIR}/patches"
CONTAINER_PATCH_PATH="/tmp/patches"
if [[ -d "${PATCH_DIR}" ]] && ls "${PATCH_DIR}"/*.patch &>/dev/null; then
    docker cp "${PATCH_DIR}" "${CONTAINER_ID}:${CONTAINER_PATCH_PATH}"
fi

docker start -a "${CONTAINER_ID}"

docker cp "${CONTAINER_ID}:${CONTAINER_BUILD_PATH}/." "${BUILD_DIR}/"
chown -R "$(id -u):$(id -g)" "${BUILD_DIR}" || true

docker rm "${CONTAINER_ID}" >/dev/null
CONTAINER_ID=""
docker volume rm "${WORKSPACE_VOLUME}" >/dev/null
WORKSPACE_VOLUME=""
