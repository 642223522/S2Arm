#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁路由：launchers/windows/launcher/ launchers/shared/experience.v1.json
# Offline host build and protocol tests; no game, signing, device probe or UI automation.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
python3 -I "$here/tests/check_text_keys.py"
python3 "$here/tests/run.py" "$@"
