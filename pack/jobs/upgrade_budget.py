# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S 级优化升级（队列作业 sgradeUpgradeBatch / 单款 sgradeUpgradeGame，pack/jobs/sgrade.py；同一时刻只升一款）的并行度与内存预算：不让一次升级把玩家的电脑吃满。

升级里的重活（重出直连着色器库、抽取、改写）都由 c.run 起的出包阶段脚本做，脚本按 S2A_JOBS / S2A_CPU_BAKE 开路数
（pack/stage_direct.sh、stage_extract.sh、stage_rewrite.sh；不给就按本机全部核数开）。升级作业每次起子进程前（core.Context.env）
按此刻的机器状况重算一次，所以内存紧了、玩家开了游戏，下一个阶段就自动降下来：
  核数上限  = 物理核数的一半（下限 1）
  内存预算  = 此刻可用内存的一半（留一半给系统与玩家别的程序）
  吃内存的重活路数 S2A_CPU_BAKE = min(核数上限, 内存预算 ÷ 每路 1.5 GB)，下限 1（同 tools/cores.sh 的每路估计）
  文件级并行 S2A_JOBS        = min(核数上限, 内存预算 ÷ 每路 0.5 GB)，下限 1
  玩家正在玩（游戏库 execution 锁有人拿着：开始游戏 / 出包 / 推送）→ 两项都降到 1
直连库编译也按 S2A_CPU_BAKE（stage_direct.sh J 缺省取它；这里不另给 J），比出包入口的 S2A_DIRECT_J 保守。
进程优先级另由 main.background_priority 降到后台档（nice 19 / macOS 后台档 / Windows 空闲优先级，子进程继承）。"""
import os
import subprocess
import sys

BAKE_MB = 1536    # 每路吃内存的重活（改写、抽取、直连库编译）估计，同 tools/cores.sh S2A_CPU_BAKE 的 1.5 GB
FILE_MB = 512     # 每路文件级并行（make -j、逐文件核对）估计
OPERATIONS = ("sgradeUpgradeGame", "sgradeUpgradeBatch", "sgradeMac")   # 按此预算起子进程的作业（sgradeMac 带 gameId 时等同单款升级）


def physical_cores():
    """物理核数：macOS sysctl hw.physicalcpu；其余平台取逻辑核数（Windows / Linux 不另查，偏多一些，再除以 2 后仍在安全一侧以内）"""
    if sys.platform == "darwin":
        try:
            n = int(subprocess.run(["sysctl", "-n", "hw.physicalcpu"], capture_output=True, text=True, timeout=5).stdout.strip())
            if n >= 1:
                return n
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return os.cpu_count() or 1


def available_mb():
    """此刻可用内存（MB）。S2A_MEM_AVAIL_MB 覆盖（单测 / 模拟小内存机器，同 tools/cores.sh）；
    macOS vm_stat 空闲 + 非活跃 + 预读 + 可清除页；Windows GlobalMemoryStatusEx；Linux MemAvailable；都读不到 → None"""
    o = os.environ.get("S2A_MEM_AVAIL_MB")
    if o:
        try:
            return max(0, int(o))
        except ValueError:
            pass
    if sys.platform == "darwin":
        try:
            out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
            page, pages = 0, 0
            for line in out.splitlines():
                if "page size of" in line:
                    page = int(line.split("page size of")[1].split()[0])
                elif line.startswith(("Pages free:", "Pages inactive:", "Pages speculative:", "Pages purgeable:")):
                    pages += int(line.rsplit(None, 1)[1].rstrip("."))
            if page and pages:
                return pages * page >> 20
        except (OSError, ValueError, IndexError, subprocess.SubprocessError):
            pass
        return None
    if sys.platform == "win32":
        import ctypes
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong), ("ullTotalPhys", ctypes.c_ulonglong),
                        ("ullAvailPhys", ctypes.c_ulonglong), ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong), ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
        st = MEMORYSTATUSEX(); st.dwLength = ctypes.sizeof(st)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
            return st.ullAvailPhys >> 20
        return None
    try:
        with open("/proc/meminfo", encoding="ascii") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) >> 10
    except (OSError, ValueError):
        pass
    return None


def plan(cores, avail_mb, busy=False):
    """→ {jobs, bake, budgetMb, cap}（见文件头）。avail_mb None（读不到）：只按核数上限的一半开、重活 1 路，不猜内存"""
    cap = max(1, cores // 2)
    if busy:
        return dict(jobs=1, bake=1, budgetMb=(avail_mb or 0) // 2, cap=cap, cores=cores, busy=True)
    if avail_mb is None:
        return dict(jobs=max(1, cap // 2), bake=1, budgetMb=None, cap=cap, cores=cores, busy=False)
    budget = avail_mb // 2
    return dict(jobs=max(1, min(cap, budget // FILE_MB)), bake=max(1, min(cap, budget // BAKE_MB)), budgetMb=budget, cap=cap, cores=cores, busy=False)


def execution_busy(c):
    """游戏库的 execution 锁有人拿着（开始游戏在玩 / 出包 / 推送）：试拿一下立刻放，不等、不挡对方（对方用 c.lock 排队，至多等这一瞬）"""
    try:
        with c.idle("execution") as free:
            return not free
    except Exception:   # noqa: BLE001 —— 读不到锁（单测裸上下文）当没人在用
        return False


def env(c):
    """升级作业起子进程时加进环境的并行度（core.Context.env 调）；每次重算并把决定写进任务日志（同值不重复写）"""
    p = plan(physical_cores(), available_mb(), execution_busy(c))
    key = (p["jobs"], p["bake"], p["busy"])
    if getattr(c, "_budget_seen", None) != key:
        c._budget_seen = key
        try:
            from core import trace
            trace(c, f"升级并行度：物理核 {p['cores']}、上限 {p['cap']} 路、内存预算 {p['budgetMb']} MB、"
                       f"{'有游戏在运行 → 降到 1 路、' if p['busy'] else ''}文件级 {p['jobs']} 路、重活 {p['bake']} 路")   # 非玩家句
        except Exception:   # noqa: BLE001 —— 记日志不挡作业
            pass
    return {"S2A_JOBS": str(p["jobs"]), "S2A_CPU_BAKE": str(p["bake"]), "S2A_DIRECT_J": str(p["bake"]), "MallocLargeCache": "0"}
