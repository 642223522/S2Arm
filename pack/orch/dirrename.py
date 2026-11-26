"""目录改名带 Windows 占用 / 挂载卷恢复退避。不依赖 pack 包：pack/ 下以脚本跑的出包步也能用。"""
import os
import time
from pathlib import Path


# 目录改名（Windows 等占用）：刚写完几十万个新文件的目录（播种 / 收纳 RomFS / 提交事务），杀软或索引程序扫描时开着里面文件的句柄，
#   Windows 上目录改名就报 WinError 5（拒绝访问）/ 32（被占用）；扫完会放开。原先一次失败整单失败（#361：Switch 2 大款 20.6 万个文件、
#   拷了 30 分钟后在 ….tmp 改名处报 Access is denied）。按退避重试约 1 分钟；仍不行报红写明哪个目录、建议把游戏库加进杀软排除。其它系统不重试
DIR_RENAME_RETRIES = (0.1, 0.2, 0.5, 1, 2, 4, 8, 15, 30)
# 挂载卷短暂断连 / 恢复时，Windows 偶发对可改名目录返回 ERROR_NOT_SUPPORTED (50)。
# 它不是杀软占用：短暂等待卷恢复后重试，持续失败则交给上层照实报错，不做非原子的复制替换。
DIR_RENAME_UNSUPPORTED_RETRIES = (0.1, 0.2, 0.5, 1, 2)


def rename_dir(src, dst, *, sleep=time.sleep):
    src, dst = Path(src), Path(dst)
    delays = ()
    for i in range(len(DIR_RENAME_RETRIES) + 1):
        try:
            return src.rename(dst)
        except OSError as e:
            winerror = getattr(e, 'winerror', None) or (5 if isinstance(e, PermissionError) else None)
            if os.name == 'nt' and winerror in (5, 32):
                delays = DIR_RENAME_RETRIES
            elif os.name == 'nt' and winerror == 50:
                delays = DIR_RENAME_UNSUPPORTED_RETRIES
            else:
                raise
            delay = delays[i] if i < len(delays) else None
            if delay is None:
                if winerror == 50:
                    raise OSError(e.errno, f'目录改名重试后仍失败（Windows WinError 50：卷不支持该请求）：{src} → {dst}。'
                                           f'请检查游戏库所在盘是否已连接、文件系统是否恢复后重试', str(src)) from e
                raise PermissionError(e.errno, f'目录改名 {i} 次都被拒（{e}）：{src} 里有文件被别的程序开着（多半是杀毒软件或索引程序在扫刚写完的文件）。'
                                               f'等扫描结束重试，或把游戏库文件夹加进杀毒软件的排除列表', str(src)) from e
            sleep(delay)
