#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 宽屏离线扫描并行与热路径单测（graphics/widen/scan/wide_scan.py scan）：约 5 秒，退出 0 = 全过。
# 背景（11-16 出包提速）：_parts 原先只靠 fork 并行，Windows 没有 fork 就本进程顺序跑（一款主程序 1–2 分钟）；现在没有 fork 时用 spawn + 共享内存。
#   另把 _main_part 每条指令都跑的逐档 movz / 生成器判断换成查表（与原写法逐字等价）。
# 构造（期望按构造手算，不跑被测实现）：13 万条 NOP（0xd503201f）里放三处特征——
#   ① 第 1000 条 MOVZ W0,#1920、第 1003 条 MOVZ W1,#1080 → movz @0xfa0、movzh @0xfac
#   ② 第 50000 条 MOVZ W2,#0x8e39、紧跟 MOVK W2,#0x3fe3,LSL#16 → asp @0x30d40（证据两字）
#   ③ 第 73120 条 MOVZ W4,#720、第 73130 条 MOVZ W3,#1280（高在宽之前 10 条；jobs=4 时分 16 块、每块 8125 条，第 73125 条是块边界：宽在后一块、高在前一块）
#      → movzh @0x47680、movz @0x476a8
#   单进程、fork（4 进程）、spawn（4 进程）三种跑法结果都 = 上面 5 项，且逐项相同；跑完共享内存已释放（再跑一遍 spawn 不报错）
import multiprocessing, os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'graphics', 'widen', 'scan'))
import wide_scan as W

NOP = 0xd503201f
def movz_w(rd, imm): return 0x52800000 | (imm << 5) | rd
def movk16_w(rd, imm): return 0x72A00000 | (imm << 5) | rd


def image():
    n = 130000; w = [NOP] * n
    w[1000] = movz_w(0, 1920); w[1003] = movz_w(1, 1080)
    w[50000] = movz_w(2, 0x8e39); w[50001] = movk16_w(2, 0x3fe3)
    w[73120] = movz_w(4, 720); w[73130] = movz_w(3, 1280)
    return struct.pack('<%dI' % n, *w)


def main():
    b = image()
    want = sorted([(1000 * 4, 'movz', '%08x' % movz_w(0, 1920)), (1003 * 4, 'movzh', '%08x' % movz_w(1, 1080)),
                   (50000 * 4, 'asp', '%08x %08x' % (movz_w(2, 0x8e39), movk16_w(2, 0x3fe3))),
                   (73120 * 4, 'movzh', '%08x' % movz_w(4, 720)), (73130 * 4, 'movz', '%08x' % movz_w(3, 1280))])
    runs = [('单进程', 1, None), ('fork 4 进程', 4, 'fork'), ('spawn 4 进程', 4, 'spawn'), ('spawn 再跑一遍（共享内存已释放）', 4, 'spawn')]
    runs = [r for r in runs if r[2] is None or r[2] in multiprocessing.get_all_start_methods()]
    bad = 0
    for name, jobs, start in runs:
        got = W.scan(b, jobs=jobs, start=start)
        ok = got == want
        bad += not ok
        print(('通 ' if ok else '不通 ') + f'{name}：{len(got)} 项' + ('' if ok else f'，实得 {got}，期望 {want}'))
    print('✓ widen_scan_parallel 全过' if not bad else f'✗ widen_scan_parallel {bad} 项不通')
    return 1 if bad else 0


if __name__ == '__main__':   # spawn 的子进程会重新导入本文件：只在主进程跑
    sys.exit(main())
