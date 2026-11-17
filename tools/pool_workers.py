"""进程池路数的唯一取法（#1332 / D-VV4J）：凡按核数（或按阶段分到的路数）开进程池的，都经 process_pool_size。
Windows 上进程池最多 61 个工作进程：multiprocessing.Pool 的结果线程、ProcessPoolExecutor 的管理线程都用 WaitForMultipleObjects 等全部子进程，
系统上限 64 个句柄、扣掉池自己占的几个。超了 multiprocessing.Pool 卡死（88 核玩家出 iPhone 包停在「资源包 N/N」几个小时；
Windows 实测 Pool(61) 0.6 秒、Pool(62) 不动），ProcessPoolExecutor 直接抛 ValueError。这是 Windows 的固定上限，跟机器无关；
少于 61 路的照给，别的系统不封顶。线程池没有这个上限，不经这里。"""
import os

WINDOWS_MAX = 61


def _windows():   # 单测在 Mac 上模拟 Windows 时只换这一处，不碰全局 os.name（别处的 Windows 专用代码不受牵连）
    return os.name == "nt"


def process_pool_size(n):
    """要开 n 路的进程池 → 实际给几路：至少 1；Windows 上至多 61"""
    n = max(1, int(n or 1))
    return min(n, WINDOWS_MAX) if _windows() else n
