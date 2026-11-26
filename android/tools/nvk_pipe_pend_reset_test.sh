#!/bin/sh
# Standalone host-only regression; requires a POSIX C compiler and pthreads.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SRC=${1:-"$ROOT/android/native/nvn"}
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/nvk-pend-reset.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
CC=${CC:-cc}
# Redirect only the production TU. pthread.h supplies the renamed POSIX prototype.
"$CC" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
    -Dpthread_cond_timedwait=nvk_pp_reset_test_timedwait \
    -I"$SRC" -c "$SRC/nvn_pipe_pend.c" -o "$BUILD/pend.o"
"$CC" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
    -I"$SRC" -c "$ROOT/android/tests/nvn_pipe_pend_reset_test.c" -o "$BUILD/test.o"
"$CC" -pthread "$BUILD/test.o" "$BUILD/pend.o" -o "$BUILD/test"
"$BUILD/test"
