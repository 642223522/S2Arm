#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
REPO=${1:-"$ROOT"}
SRC=${2:-"$REPO/android/native/nvn"}
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/nvk-warm-build.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
CC=${CC:-cc}
# POSIX declaration is renamed only in the production translation unit.
"$CC" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
 -I"$SRC" -I"$REPO/android/native" -I"$REPO/graphics/nvn/replay" \
 -Dread=nvk_warm_transaction_test_read -c "$SRC/nvn_vk_prog_warm.c" -o "$BUILD/warm.o"
"$CC" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
 -I"$SRC" -I"$REPO/android/native" -I"$REPO/graphics/nvn/replay" \
 "$ROOT/android/tests/nvn_prog_warm_transaction_test.c" "$REPO/android/native/direct/sha256.c" "$BUILD/warm.o" -o "$BUILD/test"
"$BUILD/test"
