#!/bin/bash
# 门禁覆盖：launchers/shared/experience_strings.py launchers/shared/experience.v1.json pack/jobs/errors.py launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json
# 体验规格 → iOS .strings 片段生成工具单测：bash tests/experience_strings_test.sh
set -u; cd "$(dirname "$0")/.." || exit 1
python3 -B tests/experience_strings_test.py 2>&1 | tail -3; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && echo "experience_strings 单测全过" || { echo "experience_strings 单测有不通"; exit 1; }
