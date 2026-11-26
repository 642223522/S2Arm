#!/bin/bash
# 门禁覆盖：pack/feature_bundle.py docs/site/feature.json
# iPhone 随包新功能介绍单测：bash tests/feature_bundle_test.sh
set -u; cd "$(dirname "$0")/.." || exit 1
python3 -B tests/feature_bundle_test.py 2>&1 | tail -3; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && echo "feature_bundle 单测全过" || { echo "feature_bundle 单测有不通"; exit 1; }
