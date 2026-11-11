#!/usr/bin/env bash
# 门禁手动：Linux JNI 宿主合成测试，不代表 Android/NativeAOT/真实存档验收。
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ "$(uname -s)" = Linux ] || { echo 'ENV_NOT_READY: Linux JNI host required'; exit 75; }
: "${JAVA_HOME:?JAVA_HOME must point to JDK 17 or newer}"
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
"$JAVA_HOME/bin/javac" -d "$out" "$here/SaveTransferTest.java"
compile() {
    "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -shared -fPIC \
        -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" -I"$1" \
        "$here/transport.cpp" -o "$out/transport.so"
}
compile "$here/../../native"
"$JAVA_HOME/bin/java" -Xcheck:jni -cp "$out" SaveTransferTest "$out/transport.so"
# Negative control: remove just embedded-NUL rejection. A valid suffix must not
# silently disappear at the shared C ABI boundary.
python3 - "$here/../../native/save_transfer.h" "$out/save_transfer.h" <<'PY'
import sys
s=open(sys.argv[1]).read()
s=s.replace('if (std::memchr(input.get(), 0, static_cast<size_t>(length)))', 'if (false)')
open(sys.argv[2],'w').write(s)
PY
compile "$out"
if "$JAVA_HOME/bin/java" -Xcheck:jni -cp "$out" SaveTransferTest "$out/transport.so" >"$out/negative.log" 2>&1; then
    echo 'FAIL: NUL negative control escaped'; exit 1
fi
cat "$out/negative.log"
grep -q 'expected class java.lang.IllegalArgumentException' "$out/negative.log"
echo 'PASS NUL guard negative control'
