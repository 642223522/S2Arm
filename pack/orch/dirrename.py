"""目录改名带 Windows 占用退避（#361）。不依赖 pack 包：pack/ 下以脚本跑的出包步（romfs_image / ns2_dump，sys.path 里 pack/pack.py 盖住 pack 包）也能用。"""
import os
import time
from pathlib import Path


# 目录改名（Windows 等占用）：刚写完几十万个新文件的目录（播种 / 收纳 RomFS / 提交事务），杀软或索引程序扫描时开着里面文件的句柄，
#   Windows 上目录改名就报 WinError 5（拒绝访问）/ 32（被占用）；扫完会放开。原先一次失败整单失败（#361：Switch 2 大款 20.6 万个文件、
#   拷了 30 分钟后在 ….tmp 改名处报 Access is denied）。按退避重试约 1 分钟；仍不行报红写明哪个目录、建议把游戏库加进杀软排除。其它系统不重试
DIR_RENAME_RETRIES = (0.1, 0.2, 0.5, 1, 2, 4, 8, 15, 30)


def rename_dir(src, dst, *, sleep=time.sleep):
    src, dst = Path(src), Path(dst)
    delays = DIR_RENAME_RETRIES if os.name == 'nt' else ()
    for i, delay in enumerate((*delays, None)):
        try:
            return src.rename(dst)
        except PermissionError as e:
            if delay is None:
                if os.name != 'nt':
                    raise
                raise PermissionError(e.errno, f'目录改名 {i} 次都被拒（{e}）：{src} 里有文件被别的程序开着（多半是杀毒软件或索引程序在扫刚写完的文件）。'
                                               f'等扫描结束重试，或把游戏库文件夹加进杀毒软件的排除列表', str(src)) from e
            if getattr(e, 'winerror', 5) not in (5, 32):
                raise
            sleep(delay)
