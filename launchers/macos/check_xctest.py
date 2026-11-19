#!/usr/bin/env python3
"""Require every discovered XCTest to finish; a trailing Swift Testing '0 tests' is not evidence."""
from collections import Counter
from pathlib import Path
import re
import sys


def main():
    discovery, execution = (Path(p).read_text() for p in sys.argv[1:])
    # Discover modules from the actual package, including frontend dependency-package tests.
    # Keep the module in each identity so equal case names in two modules remain distinct.
    module = r"[A-Za-z_][A-Za-z0-9_]*"
    expected = set(re.findall(rf"^({module}\.[^\s/]+/[^\s]+)$", discovery, re.M))
    # 结局行不要求在行首：用例自己打的调试输出没换行时，「Test Case '-[…]' passed」会接在同一行后面（11-17 门禁假红「未完成」）
    finished = re.findall(rf"Test Case '-\[({module}\.[^\s]+) ([^\s]+)\]' (passed|failed|skipped)", execution)
    observed = Counter(f"{suite}/{method}" for suite, method, _ in finished)
    missing = sorted(expected - observed.keys())
    unexpected = sorted(observed.keys() - expected)
    repeated = sorted(name for name, count in observed.items() if count != 1)
    failed = sum(state == "failed" for _, _, state in finished)
    skipped = sum(state == "skipped" for _, _, state in finished)
    if not expected or missing or unexpected or repeated or failed or skipped:   # 跳过也不算通过（11-01 审计 P2-51：原先只打印）
        # 进程中途退出（完成 < 发现、失败 0）：点名最后一个开始了却没有结局的用例——多半就是它把进程带崩的；
        #   「未完成」名单随崩溃点变，不能当红的签名（11-17 main 上 macOS 钩子「发现 380、完成 257」只列了一长串未完成）
        started = re.findall(rf"Test Case '-\[({module}\.[^\s]+) ([^\s]+)\]' started", execution)
        open_cases = [f"{a}/{b}" for a, b in started if f"{a}/{b}" not in observed]
        if missing and open_cases:
            print(f"中途退出：最后开始的用例 {open_cases[-1]}（有开始、没有结局；之后 {len(missing)} 例没跑）", file=sys.stderr)
        elif missing and finished:
            print(f"中途退出：最后有结局的用例 {finished[-1][0]}/{finished[-1][1]}（之后 {len(missing)} 例没开始）", file=sys.stderr)
        print(f"XCTest 未完整通过：发现 {len(expected)}，完成 {len(finished)}，失败 {failed}，跳过 {skipped}", file=sys.stderr)
        skipped_names = [f"{suite}/{method}" for suite, method, state in finished if state == "skipped"]
        # 失败的用例点名 + 断言原文（11-09：合入后全量红只报「失败 1」、没有用例名，定位只能二分，把一次不稳定失败归到了只改文档的提交上）
        failed_names = [f"{suite}/{method}" for suite, method, state in finished if state == "failed"]
        for name in failed_names:
            suite, method = name.split("/", 1)
            why = re.findall(rf"^(.*error: -\[{re.escape(suite)} {re.escape(method)}\] : .*)$", execution, re.M)
            print(f"失败：{name}" + "".join(f"\n    {line.strip()[:400]}" for line in why[:3]), file=sys.stderr)
        for label, names in (("未完成", missing), ("未登记", unexpected), ("重复", repeated), ("跳过", skipped_names)):
            if names:
                print(f"{label}：" + ", ".join(names), file=sys.stderr)
        return 1
    print(f"XCTest 完成核对：发现 {len(expected)}，完成 {len(finished)}，失败 {failed}，跳过 {skipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
