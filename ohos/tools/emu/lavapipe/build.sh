#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Cross-build Mesa lavapipe (plus OpenSSL) for the OpenHarmony emulator into ${OHOS_EMU_HOME}/lavapipe/out.
#
# Why: the emulator's SwiftShader lacks shaderImageGatherExtended (and shaderInt16, optional since #1340),
# which the direct backend requires, so no session gets past device selection. lavapipe (llvmpipe) has them. The emulator image has
# no system swapchain layer, so lvp_ohos.c adds VK_OHOS_surface + swapchain (CPU copy into OHNativeWindow).
# OpenSSL: .NET's crypto aborts without a loadable libssl and OpenHarmony gives apps none (same as Android).
# Sources are downloaded and checked against the SHA-256 below; nothing is redistributed. Takes ~40 min once.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../common.sh
source "${here}/../common.sh"
need cmake 'brew install cmake'
need ninja 'brew install ninja'
need python3 'brew install python'
bison=/opt/homebrew/opt/bison/bin/bison
[[ -x "${bison}" ]] || bison=$(command -v bison || true)
[[ -n "${bison}" ]] && "${bison}" --version | head -1 | grep -q -E ' 3\.' || die 'Mesa needs bison 3 (macOS ships 2.3): brew install bison'

W="${OHOS_EMU_HOME}/lavapipe"
OUT="${W}/out"
NDK="${SDK_DIR}/native"
[[ -x "${NDK}/llvm/bin/clang" ]] || die 'OpenHarmony SDK missing; run setup.sh first.'
mkdir -p "${W}/dl" "${W}/deps" "${OUT}"

LLVM_V=18.1.8; LLVM_SHA=0b58557a6d32ceee97c8d533a59b9212d87e0fc4d2833924eb6c611247db2f2a
MESA_V=24.3.4; MESA_SHA=e641ae27191d387599219694560d221b7feaa91c900bcec46bf444218ed66025
ZLIB_V=1.3.1;  ZLIB_SHA=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
DRM_V=2.4.124; DRM_SHA=ac36293f61ca4aafaf4b16a2a7afff312aa4f5c37c9fbd797de9e3c0863ca379
SSL_V=3.5.9;   SSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a   # = android/openssl/build.sh
fetch "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_V}/llvm-project-${LLVM_V}.src.tar.xz" "${LLVM_SHA}" "${W}/dl/llvm.tar.xz"
fetch "https://archive.mesa3d.org/mesa-${MESA_V}.tar.xz" "${MESA_SHA}" "${W}/dl/mesa.tar.xz"
fetch "https://zlib.net/fossils/zlib-${ZLIB_V}.tar.gz" "${ZLIB_SHA}" "${W}/dl/zlib.tar.gz"
fetch "https://dri.freedesktop.org/libdrm/libdrm-${DRM_V}.tar.xz" "${DRM_SHA}" "${W}/dl/libdrm.tar.xz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-${SSL_V}/openssl-${SSL_V}.tar.gz" "${SSL_SHA}" "${W}/dl/openssl.tar.gz"

# Build tools for Mesa, pinned, in their own venv.
if [[ ! -x "${W}/venv/bin/meson" ]]; then
    python3 -m venv "${W}/venv"
    "${W}/venv/bin/pip" install -q meson==1.12.1 Mako==1.4.3 MarkupSafe==3.0.4 PyYAML==6.0.3 packaging==26.3
fi
export PATH="$(dirname "${bison}"):${W}/venv/bin:${PATH}"
CC=("${NDK}/llvm/bin/clang" --target=aarch64-linux-ohos "--sysroot=${NDK}/sysroot")
TOOLCHAIN="${NDK}/build/cmake/ohos.toolchain.cmake"
src() { # src <archive> <dir>: fresh extraction
    rm -rf "${W}/$2"; mkdir -p "${W}/$2"; tar -xf "${W}/dl/$1" -C "${W}/$2" --strip-components 1
}

# 1) LLVM: native llvm-tblgen / llvm-config, then static AArch64 libraries for aarch64-linux-ohos.
if [[ ! -f "${W}/llvm/lib/libLLVMCore.a" ]]; then
    log "LLVM ${LLVM_V} (the longest step)"
    src llvm.tar.xz llvm-src
    cmake -G Ninja -S "${W}/llvm-src/llvm" -B "${W}/llvm-native" -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=AArch64 \
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_ZLIB=OFF > "${W}/llvm-native.log"
    ninja -C "${W}/llvm-native" llvm-tblgen llvm-config >> "${W}/llvm-native.log"
    cmake -G Ninja -S "${W}/llvm-src/llvm" -B "${W}/llvm-build" -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" -DOHOS_ARCH=arm64-v8a \
        -DCMAKE_MAKE_PROGRAM="$(command -v ninja)" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${W}/llvm" \
        -DLLVM_TARGETS_TO_BUILD=AArch64 -DLLVM_HOST_TRIPLE=aarch64-linux-ohos -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-linux-ohos \
        -DLLVM_TABLEGEN="${W}/llvm-native/bin/llvm-tblgen" -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_UTILS=OFF -DLLVM_INCLUDE_TOOLS=OFF \
        -DLLVM_INCLUDE_UTILS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_DOCS=OFF -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_RTTI=ON -DLLVM_ENABLE_PIC=ON -DLLVM_ENABLE_PLUGINS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON > "${W}/llvm-cross.log"
    ninja -C "${W}/llvm-build" install >> "${W}/llvm-cross.log"
    rm -rf "${W}/llvm-src" "${W}/llvm-build"
fi
# Mesa asks llvm-config: the native one, run from the cross prefix, reports the cross libraries; drop host system libs.
mkdir -p "${W}/llvm/bin"
cp "${W}/llvm-native/bin/llvm-config" "${W}/llvm/bin/llvm-config.real"
cat > "${W}/llvm/bin/llvm-config" <<'EOF'
#!/bin/bash
d=$(cd "$(dirname "$0")" && pwd)
args=(); for a in "$@"; do [ "$a" = --system-libs ] || args+=("$a"); done
[ ${#args[@]} -eq 0 ] && { echo ""; exit 0; }
out=$("$d/llvm-config.real" "${args[@]}") || exit $?
printf '%s\n' "$out" | sed -e 's/-Wl,-search_paths_first//g' -e 's/-Wl,-headerpad_max_install_names//g'
EOF
chmod +x "${W}/llvm/bin/llvm-config"

# 2) zlib and libdrm (static; Mesa requires both, nothing at run time).
if [[ ! -f "${W}/deps/lib/libz.a" ]]; then
    log "zlib ${ZLIB_V}"
    src zlib.tar.gz zlib-src
    mkdir -p "${W}/deps/lib/pkgconfig" "${W}/deps/include"
    objs=()
    for f in adler32 crc32 deflate infback inffast inflate inftrees trees zutil compress uncompr gzclose gzlib gzread gzwrite; do
        "${CC[@]}" -O2 -fPIC -DHAVE_HIDDEN -c "${W}/zlib-src/${f}.c" -o "${W}/zlib-src/${f}.o"; objs+=("${W}/zlib-src/${f}.o")
    done
    "${NDK}/llvm/bin/llvm-ar" rcs "${W}/deps/lib/libz.a" "${objs[@]}"
    cp "${W}/zlib-src/zlib.h" "${W}/zlib-src/zconf.h" "${W}/deps/include/"
    printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\nName: zlib\nDescription: zlib\nVersion: %s\nLibs: -L${libdir} -lz\nCflags: -I${includedir}\n' \
        "${W}/deps" "${ZLIB_V}" > "${W}/deps/lib/pkgconfig/zlib.pc"
    rm -rf "${W}/zlib-src"
fi
cross="${W}/ohos-cross.ini"
cat > "${cross}" <<EOF
[binaries]
c = ['${NDK}/llvm/bin/clang', '--target=aarch64-linux-ohos', '--sysroot=${NDK}/sysroot']
cpp = ['${NDK}/llvm/bin/clang++', '--target=aarch64-linux-ohos', '--sysroot=${NDK}/sysroot']
ar = '${NDK}/llvm/bin/llvm-ar'
strip = '${NDK}/llvm/bin/llvm-strip'
pkg-config = '$(command -v pkgconf || command -v pkg-config || echo pkgconf)'
llvm-config = '${W}/llvm/bin/llvm-config'

[built-in options]
c_args = ['-fPIC', '-include', '${here}/ohos_compat.h']
cpp_args = ['-fPIC']
c_link_args = ['-static-libstdc++']
cpp_link_args = ['-static-libstdc++']

[properties]
pkg_config_libdir = '${W}/deps/lib/pkgconfig'
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
command -v pkgconf >/dev/null || command -v pkg-config >/dev/null || die 'Missing pkg-config: brew install pkgconf'
if [[ ! -f "${W}/deps/lib/libdrm.a" ]]; then
    log "libdrm ${DRM_V}"
    src libdrm.tar.xz libdrm-src
    (cd "${W}/libdrm-src" && meson setup "${W}/libdrm-build" --cross-file "${cross}" --buildtype=release -Dprefix="${W}/deps" \
        -Ddefault_library=static -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
        -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled -Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled \
        -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dinstall-test-programs=false) > "${W}/libdrm.log"
    ninja -C "${W}/libdrm-build" install >> "${W}/libdrm.log"
    rm -rf "${W}/libdrm-src" "${W}/libdrm-build"
fi

# 3) Mesa: lavapipe only, plus the OHOS WSI.
stamp_file="${W}/mesa-inputs.cat"
cat "${here}/lvp_ohos.c" "${here}/mesa-${MESA_V}-ohos.patch" "${here}/ohos_compat.h" "${BASH_SOURCE[0]}" > "${stamp_file}"
stamp=$(sha256_of "${stamp_file}")
if [[ ! -f "${OUT}/libvulkan_lvp.so" || "$(cat "${OUT}/mesa.stamp" 2>/dev/null)" != "${stamp}" ]]; then
    log "Mesa ${MESA_V} lavapipe"
    src mesa.tar.xz mesa-src
    (cd "${W}/mesa-src" && patch -p1 -s < "${here}/mesa-${MESA_V}-ohos.patch")
    cp "${here}/lvp_ohos.c" "${W}/mesa-src/src/gallium/frontends/lavapipe/lvp_ohos.c"
    rm -rf "${W}/mesa-build"
    (cd "${W}/mesa-src" && meson setup "${W}/mesa-build" --cross-file "${cross}" --buildtype=release -Dprefix="${W}/mesa" \
        -Dvulkan-drivers=swrast -Dgallium-drivers=llvmpipe -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
        -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dllvm=enabled -Dshared-llvm=disabled -Dxmlconfig=disabled \
        -Dzstd=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dbuild-tests=false -Dshared-glapi=disabled \
        -Dvulkan-layers= -Dtools= -Dexpat=disabled -Dllvm-orcjit=false -Dcpp_rtti=false) > "${W}/mesa.log"
    ninja -C "${W}/mesa-build" >> "${W}/mesa.log"
    "${NDK}/llvm/bin/llvm-strip" -o "${OUT}/libvulkan_lvp.so" "${W}/mesa-build/src/gallium/targets/lavapipe/libvulkan_lvp.so"
    printf '%s\n' "${stamp}" > "${OUT}/mesa.stamp"
    rm -rf "${W}/mesa-src" "${W}/mesa-build"
fi

# 4) OpenSSL (same version and digest as android/openssl/build.sh); .NET loads libssl.so.3 by name.
if [[ ! -f "${OUT}/libssl.so.3" ]]; then
    log "OpenSSL ${SSL_V}"
    src openssl.tar.gz openssl-src
    (cd "${W}/openssl-src" && CC="${CC[*]}" AR="${NDK}/llvm/bin/llvm-ar" RANLIB="${NDK}/llvm/bin/llvm-ranlib" \
        ./Configure linux-aarch64 shared no-tests no-docs no-apps no-engine no-dso no-async -fPIC && make -j8 build_libs) > "${W}/openssl.log" 2>&1
    for l in libssl.so.3 libcrypto.so.3; do "${NDK}/llvm/bin/llvm-strip" -o "${OUT}/${l}" "${W}/openssl-src/${l}"; done
    rm -rf "${W}/openssl-src"
fi
log "lavapipe ready: $(ls "${OUT}" | grep -v stamp | tr '\n' ' ')"
