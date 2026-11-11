# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""后台查商店元数据（library.store_meta_background 起）：参数 私有目录 库 库标识 引擎目录 [游戏号…]。
查横图 + 英文标题存进游戏库（library.store_meta），再把拿到英文名的游戏号文件夹改名（layout.heal_folder_names：拿不到执行锁就留给下个作业）。
同一个库同一时刻只跑一个（库里 .store-meta.lock）；任何异常都静默退出：元数据是锦上添花，不报错、不挡任何作业。"""
from __future__ import annotations
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))


def main(argv):
    if len(argv) < 4:
        return 2
    private, library, library_id, engine, *ids = argv
    import filelock
    from core import Context
    import layout
    import library as lib
    import os
    import time
    lock = Path(library) / ".store-meta.lock"
    try:
        # 已有一个在查，或删游戏 / 移动 / 搬家正在进行（library.store_meta_quiet）就这次不查；拿到时记下占锁者，删游戏等它时说得清在等谁
        with filelock.held(lock, holder=dict(taskId="store-meta", operation="storeMeta", pid=os.getpid(), startedAt=round(time.time(), 3))):
            # 起进程到拿到锁之间库可能已经搬走或换了：标识对不上就什么都不写（不建任务上下文，免得把任务记录写进已搬走的旧位置）
            marker = json.loads((Path(library) / ".s2arm-library.json").read_text(encoding="utf-8"))
            if not library_id or marker.get("id") != library_id:
                return 0
            c = Context(dict(schema=1, taskId="store-meta", operation="storeMeta", engineDir=engine, privateRoot=private,
                             library=library, libraryId=library_id))
            lib.store_meta(c, set(ids) or None)
            layout.heal_folder_names(c)
    except filelock.Busy:
        return 0
    except Exception:   # noqa: BLE001
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
