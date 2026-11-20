#!/bin/sh
# Host-only production shutdown boundary: normal two sessions + isolated omission.
# Run directly: sh android/tools/nvk_prog_warm_session_test.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/nvk-warm-session.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
CC=${CC:-cc}
cd "$ROOT"
if [ "$(uname -s)" != Linux ]; then
    echo "requires a Linux host compiler/linker with --gc-sections" >&2
    exit 2
fi

compile() {
    "$CC" -std=c11 -O1 -pthread -D_GNU_SOURCE -ffunction-sections -fdata-sections \
        -Iandroid/native -Iandroid/native/nvn -Iandroid/native/direct -Iandroid/native/gfx_plat \
        -Igraphics/nvn -Igraphics/nvn/replay -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
        -Igraphics/nvn/gfx/tex -Iruntime/include -Iandroid/tests/vkhost \
        -Igraphics/nvn/third_party/vulkan-headers/include "$@"
}
shader=android/native/gfx_plat/nvk_shader.c
compile -c "$shader" -o "$BUILD/shader.o"
compile -c graphics/nvn/replay/rp_entry.c -o "$BUILD/replay.o"
compile -c android/native/nvn/nvn_vk_prog_warm.c -o "$BUILD/warm.o"
compile -c android/native/direct/sha256.c -o "$BUILD/sha256.o"
compile -Wall -Wextra -Werror -c android/tests/nvn_prog_warm_session_test.c -o "$BUILD/test.o"

link() {
    "$CC" -pthread -Wl,--gc-sections "$BUILD/test.o" "$1" "$BUILD/replay.o" \
        "$BUILD/warm.o" "$BUILD/sha256.o" -o "$2"
}
link "$BUILD/shader.o" "$BUILD/positive"
mkdir "$BUILD/a" "$BUILD/b"
"$BUILD/positive" "$BUILD/a" "$BUILD/b"

# Omit a normal session reset call in exactly one scratch TU. No binary fixtures.
"${S2A_PY:-${PY:-python3}}" - "$shader" "$BUILD/omit.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("void rp_shader_reset(void) {")
end = source.index("\n}", start)
line = "    nvk_prog_warm_reset();\n"
assert source[start:end].count(line) == 1, "reset negative-control anchor changed"
Path(sys.argv[2]).write_text(
    source[:start] + source[start:end].replace(line, "", 1) + source[end:],
    encoding="utf-8",
)
PY
compile -c "$BUILD/omit.c" -o "$BUILD/omit.o"
link "$BUILD/omit.o" "$BUILD/negative"
mkdir "$BUILD/omit-a" "$BUILD/omit-b"
status=0
"$BUILD/negative" "$BUILD/omit-a" "$BUILD/omit-b" > "$BUILD/negative.out" 2>&1 || status=$?
if [ "$status" -ne 1 ] ||
    ! grep -Fq 'FAIL: real reset clears stats and plan' "$BUILD/negative.out" ||
    ! grep -Fq 'FAIL: real reset clears live table' "$BUILD/negative.out" ||
    ! grep -Fq 'FAIL: session B has no previous-session record or plan' "$BUILD/negative.out" ||
    ! grep -Fq 'FAIL: second real shutdown clears session B' "$BUILD/negative.out" ||
    ! grep -Fxq 'two normal sessions: checks=17 failures=4' "$BUILD/negative.out"
then
    cat "$BUILD/negative.out" >&2
    echo "warm session reset omission: unexpected result (exit $status)" >&2
    exit 1
fi
echo "warm session reset omission: detected (4 expected failed assertions, exit 1)"
