#!/bin/sh
# Usage: sh nvk_prog_warm_recency_test.sh CANDIDATE_TREE [LEGACY_TREE]
# Legacy exercises read compatibility via the older production writer only.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
REPO=${1:-"$ROOT"}
LEGACY=${2:-}
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/nvk-warm-recency.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
CC=${CC:-cc}
compile() {
    tree=$1 name=$2
    native="$tree/android/native"
    "$CC" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
        -I"$native/nvn" -I"$native" -I"$tree/graphics/nvn/replay" \
        -Dclock_gettime=nvk_recency_test_clock_gettime \
        -c "$native/nvn/nvn_vk_prog_warm.c" -o "$BUILD/$name.o"
    "$CC" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
        -I"$native/nvn" -I"$native" -I"$tree/graphics/nvn/replay" \
        "$ROOT/android/tests/nvn_prog_warm_recency_test.c" "$native/direct/sha256.c" \
        "$BUILD/$name.o" -o "$BUILD/$name"
}
compile "$REPO" candidate
mkdir "$BUILD/fresh"
result=0
"$BUILD/candidate" fresh "$BUILD/fresh" || result=$?
if [ -n "$LEGACY" ]; then
    compile "$LEGACY" legacy
    for scenario in legacy-after legacy-preload; do
        mkdir "$BUILD/$scenario"
        "$BUILD/legacy" seed-legacy "$BUILD/$scenario"
        "$BUILD/candidate" "$scenario" "$BUILD/$scenario" || result=$?
    done
fi
exit "$result"
