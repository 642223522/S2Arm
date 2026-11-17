#!/bin/bash
# Mac-only frontend checks; no game files, device access or network installation.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
cd "$R"
source "$R/tools/toolchain.sh"   # 门禁用统一工具链（tools/toolchain.env）；S2A_DEVELOPER_DIR 可覆盖
export CLANG_MODULE_CACHE_PATH="$R/build/macos/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$R/build/macos/swift-cache"
mkdir -p build/macos/tests
# 两套 Python 单测与下面的 Swift 编译 / XCTest 互不依赖（不读 build/macos）：放后台同时跑，输出进日志，末尾按原顺序打印、任一不通整步不通
trap 'kill $(jobs -p) 2> /dev/null || :' EXIT   # 中途失败退出时不留后台单测
python3 -B -m unittest discover -s launchers/macos/Tests -p 'test_*.py' -v > build/macos/tests/py-tests.log 2>&1 & py_tests=$!
python3 -B -m unittest discover -s launchers/macos/gui_jobs/tests -v > build/macos/tests/py-gui-jobs.log 2>&1 & py_gui=$!
python3 launchers/macos/sparkle_vendor.py > /dev/null   # Sparkle 二进制包不随仓库，按校验值备到 frontend/Vendor/
swift_args=(--disable-sandbox --cache-path "$R/build/macos/spm-cache" --package-path launchers/macos --scratch-path build/macos/spm)
swift test "${swift_args[@]}" list > build/macos/tests/swift-discovery.log
# 三个 XCTest 模块（S2ArmLauncherTests / S2ArmAppleTests / S2ArmAppleAdapterTests）各起一个进程同时跑（11-14 门禁提速：原先一个 swift test 串着跑，
#   约 29 + 25 + 0.6 秒，整步取决于最慢那个模块）。按模块切、不在模块内再切：S2ArmAppleTests 里有用例改写 xctest 进程共用的
#   UserDefaults「appLanguage」（跨进程可见），同一模块的用例仍在同一进程里按原顺序跑，与原先完全一样。
#   上面 list 已编好，这里 --skip-build；SwiftPM 默认对 scratch 目录加锁、三个进程会互等，只读跑测试用 --ignore-lock。
#   各模块输出按模块顺序拼成同一份 swift-execution.log，check_xctest.py 照旧核「发现的每个用例恰好跑完一次」——漏切、多切都会红
swift_rc=0; mods=(); while IFS= read -r m; do mods+=("$m"); done < <(sed -nE 's#^([A-Za-z0-9_]+)\.[^/[:space:]]+/[^[:space:]]+$#\1#p' build/macos/tests/swift-discovery.log | LC_ALL=C sort -u)
pids=(); for m in "${mods[@]}"; do
  swift test "${swift_args[@]}" --skip-build --ignore-lock --filter "^${m}\\." > "build/macos/tests/swift-execution.$m.log" 2>&1 & pids+=($!); done
for i in "${!pids[@]}"; do wait "${pids[$i]}" || swift_rc=$?; done
for m in "${mods[@]}"; do cat "build/macos/tests/swift-execution.$m.log"; done > build/macos/tests/swift-execution.log
py_rc=0; wait "$py_tests" || py_rc=$?; cat build/macos/tests/py-tests.log
wait "$py_gui" || py_rc=$?; cat build/macos/tests/py-gui-jobs.log
[ "$py_rc" = 0 ] || exit "$py_rc"
cat build/macos/tests/swift-execution.log
python3 launchers/macos/check_xctest.py build/macos/tests/swift-discovery.log build/macos/tests/swift-execution.log
[ "$swift_rc" = 0 ] || exit "$swift_rc"
# SwiftPM does not run a dependency package's tests with the parent package.
# Keep frontend layout, controller and language regressions in the standard Mac test entry point.
frontend_args=(--disable-sandbox --cache-path "$R/build/macos/spm-cache" --package-path launchers/macos/frontend --scratch-path build/macos/frontend-ui)
swift test "${frontend_args[@]}" list > build/macos/tests/frontend-discovery.log
frontend_rc=0
swift test "${frontend_args[@]}" > build/macos/tests/frontend-execution.log 2>&1 || frontend_rc=$?
cat build/macos/tests/frontend-execution.log
python3 launchers/macos/check_xctest.py build/macos/tests/frontend-discovery.log build/macos/tests/frontend-execution.log
[ "$frontend_rc" = 0 ] || exit "$frontend_rc"
# 原生输入（input_test.m）与系统键盘桥接（textinput_test.m）的 C / ObjC 单测挪到 tests/macos_native_input_test.sh（合入前层、按依赖文件路由；
#   11-10：#417 Joy-Con 体感改走 HID 后 input_test 漏链 joycon_imu.m，这里只在合入后层跑，守望才发现）
