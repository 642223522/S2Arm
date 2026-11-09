#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁只看：launchers/shared/runtime_cache.py launchers/windows/bundle_runtime_win.py launchers/macos/bundle_runtime.py launchers/macos/requirements-runtime.txt tests/runtime_cache_test.py
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/runtime_cache_test.py
