#!/bin/bash
# S2A_DAV1D=0 可选关闭 dav1d 软件兜底（仅适合所有目标机都有 AV1 硬件解码的本地构建）：
#   默认仍构建/链接；关闭时 host/iOS 链接参数都不含 dav1d，启动器依赖检查不再要求 meson/ninja，出包预编库清单不含 dav1d。
# 门禁覆盖：Makefile services/build.mk launchers/macos/prepare_build.py launchers/macos/bundle_engine.py
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/s2a-dav1d-optional.XXXXXX")
trap 'rm -rf "$T"' EXIT

fail() { echo "不通：$*" >&2; exit 1; }

# 1) services/build.mk：host / iOS 链接参数随开关变化
D="$T/mk"
mkdir -p "$D/services/vpx" "$D/services/opus" "$D/services/dav1d" "$D/build"
cp "$H/services/build.mk" "$D/services/build.mk"
stub() { printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$1"; chmod +x "$1"; }
stub "$D/services/nxaot.sh" "$T/libs2a_cs.a"
stub "$D/services/vpx/build.sh" "$T/libs2a_vpx.a"
stub "$D/services/opus/build.sh" "$T/libs2a_opus.a"
stub "$D/services/dav1d/build.sh" "$T/libs2a_dav1d.a"
cat > "$D/Makefile" <<'EOF'
BUILD := build
include services/build.mk
.PHONY: print
print:
	@printf 'HOST=%s\n' '$(HOST_LIBS)'
	@printf 'IOS=%s\n' '$(IOS_LIBS)'
EOF
out0=$(make -s -C "$D" S2A_CS=1 S2A_DAV1D=0 print)
out1=$(make -s -C "$D" S2A_CS=1 S2A_DAV1D=1 print)
case "$out0" in *libs2a_dav1d.a*) fail "S2A_DAV1D=0 仍链了 dav1d：$out0";; esac
n1=$(grep -o 'libs2a_dav1d.a' <<<"$out1" | wc -l | tr -d ' ' || true)
[ "$n1" = 2 ] || fail "S2A_DAV1D=1 没有同时链 host/iOS dav1d：$out1"
for lib in libs2a_vpx.a libs2a_opus.a libs2a_cs.a; do
  grep -q "$lib" <<<"$out0" || fail "S2A_DAV1D=0 丢了 $lib：$out0"
  grep -q "$lib" <<<"$out1" || fail "S2A_DAV1D=1 丢了 $lib：$out1"
done

# 2) prepare_build.py：S2A_DAV1D=0 不再要求 meson/ninja；默认仍要求
for v in 0 1; do
  S2A_DAV1D=$v python3 - "$H" "$v" <<'PY'
import importlib.util
import os
import sys
h, v = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("prepare_build", os.path.join(h, "launchers/macos/prepare_build.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
has = "meson" in m.FORMULAS and "ninja" in m.FORMULAS
if has != (v != "0"):
    raise SystemExit("S2A_DAV1D=%s 时 FORMULAS meson/ninja=%s" % (v, has))
PY
done

# 3) bundle_engine.py：S2A_DAV1D=0 的预编库清单不含 dav1d；默认含
for v in 0 1; do
  S2A_DAV1D=$v python3 - "$H" "$v" <<'PY'
import sys
import types
h, v = sys.argv[1], sys.argv[2]
for name in ("core", "build", "toolchain"):
    m = types.ModuleType(name)
    if name == "core":
        m.Context = m.atomic = m.digest = m.tree_hash = object
    elif name == "build":
        m.compile_host = object
    sys.modules[name] = m
sys.path.insert(0, h + "/launchers/macos")
import bundle_engine
has = any(name == "dav1d" for name, _ in bundle_engine.PREBUILT_LIBS)
if has != (v != "0"):
    raise SystemExit("S2A_DAV1D=%s 时 PREBUILT_LIBS 含 dav1d=%s" % (v, has))
PY
done

# 4) runtime/tests/mk/nvn2_codec.mk：S2A_DAV1D=0 时不注册依赖 dav1d 的 codec 单测目标（该片段只在 Darwin 生效）
if [ "$(uname -s)" = Darwin ]; then
  D2="$T/tests-mk"
  mkdir -p "$D2/runtime/tests/mk"
  cp "$H/runtime/tests/mk/nvn2_codec.mk" "$D2/runtime/tests/mk/nvn2_codec.mk"
  cat > "$D2/Makefile" <<'EOF'
BUILD := build
CC := clang
NATIVE_INC :=
NATIVE_TEST_OWN :=
TEST_TARGETS :=
include runtime/tests/mk/nvn2_codec.mk
.PHONY: print
print:
	@printf '%s\n' '$(TEST_TARGETS)'
EOF
  out0=$(make -s -C "$D2" S2A_DAV1D=0 print)
  out1=$(make -s -C "$D2" S2A_DAV1D=1 print)
  case "$out0" in *native-test-nvn2_codec*) fail "S2A_DAV1D=0 仍注册了 codec 单测：$out0";; esac
  case "$out1" in *native-test-nvn2_codec*) ;; *) fail "S2A_DAV1D=1 没注册 codec 单测：$out1";; esac
fi

echo "dav1d 可选构建单测全过"
