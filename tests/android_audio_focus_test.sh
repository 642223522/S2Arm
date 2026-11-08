#!/bin/bash
# 门禁覆盖：android/native/aaudio_sink.c
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${S2A_CONTRIB_TMP:-${S2A_HOST_OUT_ROOT:-${TMPDIR:-/tmp}}}/s2a-audio-focus.XXXXXXXX")
trap 'rm -rf "$out"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -UNDEBUG \
    -I "$root/android/tests/aaudio_stubs" -I "$root/android/native" \
    "$root/android/tests/aaudio_format_test.c" \
    "$root/android/native/aaudio_sink.c" "$root/android/native/pcm_ring.c" \
    -o "$out/aaudio" -lm -pthread
"$out/aaudio"
# Real managed audio session + real native sink; only Android's AAudio API is fake.
shared=(-shared); suffix=so
if [ "$(uname -s)" = Darwin ]; then shared=(-dynamiclib); suffix=dylib; fi
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -fPIC "${shared[@]}" \
    -I "$root/android/tests/aaudio_stubs" -I "$root/android/native" \
    "$root/android/tests/audio-focus-managed/fake_aaudio.c" \
    "$root/android/native/aaudio_sink.c" "$root/android/native/pcm_ring.c" \
    -o "$out/libs2arm_android.$suffix" -lm -pthread
dotnet build "$root/android/tests/audio-focus-managed/AudioFocusManaged.Tests.csproj" \
    -c Release -nologo -v q -p:ArtifactsPath="$out/managed"
dotnet "$out/managed/bin/AudioFocusManaged.Tests/release/AudioFocusManaged.Tests.dll" "$out/libs2arm_android.$suffix"
bash "$root/android/core-runtime/tests/run_shutdown_thread.sh" "$out/runtime"
