"""clone_tree 保留空目录（10-23 走查起因是快照 .git 的空 refs 目录；快照不再带 .git 后，RomFS 等目录里的空目录照样要原样拷）。"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build import clone_tree  # noqa: E402

ENV = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")


def git(d, *a):
    subprocess.run(["git", "-C", str(d), *a], check=True, env=ENV, capture_output=True)


class CloneKeepsEmptyDirs(unittest.TestCase):
    def test_clone_keeps_empty_dirs(self):
        t = Path(tempfile.mkdtemp())
        src = t / "src"; (src / "romfs" / "empty" / "nested").mkdir(parents=True); (src / "romfs" / "a.bin").write_bytes(b"x")
        dst = t / "dst"; dst.mkdir()
        clone_tree(types.SimpleNamespace(check=lambda: None, progress=lambda *a: None), src, dst)
        self.assertTrue((dst / "romfs" / "empty" / "nested").is_dir())
        self.assertEqual((dst / "romfs" / "a.bin").read_bytes(), b"x")


class SnapshotIgnoresBuildOutputs(unittest.TestCase):
    """11-02 beta.3 走查：快照没带根 .gitignore，出包在副本里编出的 bin/ obj/ 被 pack/ipa.sh 的
    「git status --porcelain -- runtime ios graphics translator services compat Makefile」当成改动，玩家导出 iPhone 版死在最后一步。
    用真仓库的根 .gitignore 和 bundle_engine 的输入清单搭快照、造产物，期望那条检查看到的是空的；去掉 .gitignore 的反证要非空。"""
    ROOT = Path(__file__).resolve().parents[3]

    def snapshot(self, with_ignore):
        d = Path(tempfile.mkdtemp())
        (d / "graphics" / "widen").mkdir(parents=True); (d / "graphics" / "widen" / "a.cs").write_text("x\n")
        (d / "services" / "aot").mkdir(parents=True); (d / "services" / "aot" / "b.cs").write_text("y\n")
        if with_ignore:
            (d / ".gitignore").write_bytes((self.ROOT / ".gitignore").read_bytes())
        for a in (["init", "-q", "--template="], ["add", "--force", "--all"], ["commit", "-qm", "s"]):
            git(d, *a)
        for out in ("graphics/widen/bin/Release/x.dll", "graphics/widen/obj/project.assets.json", "services/aot/bin/y", "services/aot/obj/z"):
            (d / out).parent.mkdir(parents=True, exist_ok=True); (d / out).write_text("o\n")
        return subprocess.run(["git", "-C", str(d), "status", "--porcelain", "--", "runtime", "ios", "graphics", "translator", "services", "compat", "Makefile"],
                              env=ENV, capture_output=True, text=True, check=True).stdout

    def test_root_gitignore_is_an_engine_input(self):
        sys.path.insert(0, str(self.ROOT))
        from launchers.macos.bundle_engine import INPUTS
        self.assertIn(".gitignore", INPUTS)

    def test_build_outputs_do_not_count_as_changes(self):
        self.assertEqual(self.snapshot(True), "")
        self.assertIn("?? graphics/widen/bin/", self.snapshot(False))   # 反证：没有忽略规则就是旧的红

