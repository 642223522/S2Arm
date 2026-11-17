"""发版应用里作业层的布局，只此一份：build_app.py 打 Mac 应用用它放 Contents/Resources/Jobs，
tools/app_layout_check.py（门禁）用它搭同样的布局核导入——两边同一个函数，打包加了文件、门禁自动跟上。
Mac 应用里作业层在 Contents/Resources/Jobs，引擎是另一处的快照克隆（请求里的 engineDir = 作业的 c.engine）：
Jobs 里的代码按自己的位置往上推（Path(__file__).parents[2]）只到 Contents，那里没有 pack/、tools/。"""
import shutil
from pathlib import Path

# 作业层直接 import、但源码不在 pack/jobs 里的单个文件：随 Jobs 一起带（Jobs 往上推找不到引擎树）
EXTRA = (
    ("tools/redact.py", "redact.py"),               # 脱敏规则只有一份：任务代码在引擎准备好之前也要脱敏
    ("tools/sha256_fast.py", "sha256_fast.py"),     # 导入算原件 SHA（pack/jobs/core.py digest，Windows 走 CNG）
    ("graphics/nvn/tools/romfs_list.py", "romfs_list.py"),   # clone_tree 统一盘点用（pack/jobs/build.py）
    ("tools/pool_workers.py", "pool_workers.py"),   # romfs_list 取核数经它（#1332：核数 / 进程池路数唯一来源）；应用里同目录就是 Jobs、已在导入路径上
    ("pack/romfs_img.py", "romfs_img.py"),          # romfs_list 读 RomFS 镜像（romfs.std）用：它先找同目录，应用里同目录就是 Jobs
    ("runtime/include/s2a_host_abi.h", "s2a_host_abi.h"),   # 宿主约定号（pack/jobs/host_update.py HOST_ABI 读它）：先找同目录，应用里同目录就是 Jobs；Windows 作业层在引擎快照里、按仓库路径读
)


def stage_jobs(root, resources):
    """把作业层放进 <resources>/Jobs（root = 仓库根）"""
    root, jobs = Path(root), Path(resources) / "Jobs"
    shutil.copytree(root / "pack/jobs", jobs, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    for src, name in EXTRA:
        shutil.copy2(root / src, jobs / name)
    return jobs
