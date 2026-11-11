#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
javac -encoding UTF-8 -Xlint:all -Werror -d "$out" \
    "$root/android/app/src/main/java/org/s2arm/android/DiagnosticBundlePolicy.java" \
    "$root/android/tests/diagnostics/DiagnosticBundlePolicyTest.java"
java -ea -cp "$out" org.s2arm.android.DiagnosticBundlePolicyTest
