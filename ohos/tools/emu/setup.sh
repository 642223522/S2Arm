#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Install the SDK, build tools and emulator image in the cache.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ohos/tools/emu/common.sh
source "${SCRIPT_DIR}/common.sh"
trap 'die "Setup failed; inspect the error above, fix it and rerun setup.sh."' ERR

need curl 'install curl'
need tar 'install tar'
need unzip 'install unzip'
need node 'brew install node'
need npm 'brew install node (includes npm)'
need qemu-system-aarch64 'brew install qemu'
need ninja 'brew install ninja'
JAVA_HOME=$(java_home)
export JAVA_HOME
mkdir -p "${OHOS_EMU_HOME}/dl" "${SDK_DIR}" "${HVIGOR_DIR}"
archive="${OHOS_EMU_HOME}/dl/sdk.tar.gz"
fetch "${OHOS_SDK_URL}" "${OHOS_SDK_SHA256}" "${archive}"
tmp=$(mktemp -d "${OHOS_EMU_HOME}/sdk-unpack.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT
# One pass over the 1.3 GB archive for whichever component zips are still missing.
wanted=()
for component in ets js native previewer toolchains; do
    [[ -f "${SDK_DIR}/${component}/oh-uni-package.json" ]] || wanted+=("sdk/packages/ohos-sdk/darwin/${component}-darwin-arm64-*.zip")
done
if [[ ${#wanted[@]} -gt 0 ]]; then
    tar -xzf "${archive}" -C "${tmp}" --wildcards "${wanted[@]}" 2>/dev/null || tar -xzf "${archive}" -C "${tmp}" "${wanted[@]}"
    for zip in "${tmp}"/sdk/packages/ohos-sdk/darwin/*.zip; do
        unzip -oq "${zip}" -d "${SDK_DIR}"
    done
fi
for component in ets js native previewer toolchains; do
    [[ -f "${SDK_DIR}/${component}/oh-uni-package.json" ]] || die "Missing ${component} metadata; check the SDK archive and rerun setup.sh."
done
rm -rf "${tmp}"
trap - EXIT
[[ "${KEEP_DOWNLOADS:-0}" == 1 ]] || rm -f "${archive}"
if [[ ! -e "${SDK_ROOT}/26" && ! -L "${SDK_ROOT}/26" ]]; then
    ln -s "${OHOS_SDK_API}" "${SDK_ROOT}/26"
fi
sdk_ninja="${SDK_DIR}/native/build-tools/cmake/bin/ninja"
if ! "${sdk_ninja}" --version >/dev/null 2>&1; then
    mv "${sdk_ninja}" "${sdk_ninja}.x86_64"
    ln -s "$(command -v ninja)" "${sdk_ninja}"
fi
package="${HVIGOR_DIR}/node_modules/@ohos/hvigor/package.json"
version=''
if [[ -f "${package}" ]]; then
    version=$(node -p 'require(process.argv[1]).version' "${package}")
fi
if [[ "${version}" != "${HVIGOR_VERSION}" ]]; then
    (
        cd "${HVIGOR_DIR}"
        [[ -f package.json ]] || npm init -y
        npm install --no-audit --no-fund --registry "${HVIGOR_REGISTRY}" \
            "@ohos/hvigor@${HVIGOR_VERSION}" "@ohos/hvigor-ohos-plugin@${HVIGOR_VERSION}"
    ) || die 'hvigor installation failed; check npm output and rerun setup.sh.'
fi
archive="${OHOS_EMU_HOME}/dl/image.tar.gz"
if [[ ! -f "${IMAGES}/Image" ]]; then
    fetch "${OHOS_IMAGE_URL}" "${OHOS_IMAGE_SHA256}" "${archive}"
    mkdir -p "${OHOS_EMU_HOME}/image"
    tar -xzf "${archive}" -C "${OHOS_EMU_HOME}/image"
fi
[[ -f "${IMAGES}/Image" ]] || die 'Image missing after extraction; check OHOS_IMAGE_URL and rerun setup.sh.'
[[ "${KEEP_DOWNLOADS:-0}" == 1 ]] || rm -f "${archive}"
log "SDK: ${SDK_DIR}"
log "Images: ${IMAGES}"
log "hvigor: ${HVIGOR_VERSION}"
log "Java: ${JAVA_HOME}/bin/java"
log 'next: bash ohos/tools/emu/boot.sh'
