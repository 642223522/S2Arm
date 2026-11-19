# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳：手机存档在电脑上的备份（pack/jobs/install.py snapshot_phone_saves / phone_saves / restore_phone_save）。
游戏库是真的（library.setup + layout），手机是替身：backup(g) 把「手机上的存档」原样拉进 games/<号>/save_backup/<名>/（同真 ph.backup 的落点），
client(w) 记下写回 / 删除；期望按写进去的内容手写。"""
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install  # noqa: E402
import layout  # noqa: E402
import program_pack  # noqa: E402
import tests.test_jobs as tj  # noqa: E402
from core import Failure  # noqa: E402

G = "0100000000010000"


class FakeClient:
    def __init__(self):
        self.ops = []

    def put(self, src, rel):
        self.ops.append(("put", rel, Path(src).read_bytes()))

    def rm(self, rel):
        self.ops.append(("rm", rel)); return True, ""


class FakePhone:
    """手机上这款的存档 = self.saves（相对路径 → 字节）；每次 backup 拉成一个新目录（名字按次序，同真的按时刻）"""
    def __init__(self, c, key="PHONE-1"):
        self.c, self.key, self.saves, self.n, self.fail, self.running = c, key, {}, 0, None, False
        self.cl = FakeClient()

    def backup(self, g):
        if self.fail:
            raise Failure(self.fail, code="save_backup_failed")
        if not self.saves:
            return None
        self.n += 1
        dest = layout.path(self.c, g, "save_backup", f"20261117-{self.key[-1]}{self.n:05d}")
        for rel, data in self.saves.items():
            (dest / rel).parent.mkdir(parents=True, exist_ok=True); (dest / rel).write_bytes(data)
        return dest

    def app_running(self):
        return self.running

    def client(self, w):
        return self.cl


class PhoneSaves(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def bk(self):
        return layout.path(self.c, G, "save_backup", create=False)

    def snap(self, ph, on=True):
        with patch.object(program_pack, "enabled", lambda c: on), patch.object(install, "trace", lambda *a, **k: None):
            return install.snapshot_phone_saves(self.c, ph, [G])

    def marked(self):
        return sorted(d.name for d in self.bk().iterdir() if (d / install.PHONE_SAVE_MARK).is_file())

    def test_new_same_changed(self):
        ph = FakePhone(self.c); ph.saves = {"0000000000000001/0/save.dat": b"v1"}
        first = self.snap(ph)[G]
        m = json.loads((self.bk() / first / install.PHONE_SAVE_MARK).read_text())
        self.assertEqual((m["device"], m["files"], m["bytes"]), ("PHONE-1", 1, 2))
        self.assertEqual(self.snap(ph)[G], first, "内容没变：不新建，给上一份")
        self.assertEqual(self.marked(), [first])
        ph.saves["0000000000000001/0/save.dat"] = b"v2"
        second = self.snap(ph)[G]
        self.assertNotEqual(second, first)
        self.assertEqual(self.marked(), [first, second])

    def test_keep_ten_per_phone_and_legacy_untouched(self):
        old = layout.path(self.c, G, "save_backup", "20261001-120000"); old.mkdir(parents=True); (old / "x.dat").write_bytes(b"old")
        ph = FakePhone(self.c)
        for i in range(12):
            ph.saves = {"a.dat": f"v{i}".encode()}
            self.snap(ph)
        self.assertEqual(len(self.marked()), install.PHONE_SAVE_KEEP)
        self.assertTrue((old / "x.dat").is_file(), "没有记号的旧备份（覆盖装前拉的）一份不删")
        kept = [json.loads((self.bk() / d / install.PHONE_SAVE_MARK).read_text())["digest"] for d in self.marked()]
        self.assertEqual(len(set(kept)), 10)
        self.assertEqual((self.bk() / self.marked()[-1] / "a.dat").read_bytes(), b"v11", "留的是最近 10 份")

    def test_dedupe_is_per_phone(self):
        a, b = FakePhone(self.c, "PHONE-1"), FakePhone(self.c, "PHONE-2")
        a.saves = b.saves = {"a.dat": b"same"}
        ra, rb = self.snap(a)[G], self.snap(b)[G]
        self.assertNotEqual(ra, rb, "另一台手机同内容也各留一份（按台按款）")

    def test_failure_does_not_block_and_switch_off(self):
        ph = FakePhone(self.c); ph.saves = {"a.dat": b"v"}; ph.fail = "锁屏"
        self.assertEqual(self.snap(ph), {})
        ph.fail = None
        self.assertEqual(self.snap(ph, on=False), {})
        self.assertEqual(ph.n, 0, "开关关着不拉")

    def test_list_marked_and_legacy(self):
        old = layout.path(self.c, G, "save_backup", "20261001-120000"); old.mkdir(parents=True); (old / "x.dat").write_bytes(b"old")
        ph = FakePhone(self.c); ph.saves = {"a.dat": b"v1"}
        new = self.snap(ph)[G]
        self.c.catalog = lambda: {"games": [{"id": G, "name": "甲"}]}
        rows = install.phone_saves(self.c)["games"][0]["backups"]
        self.assertEqual([(r["id"], r["device"], r["legacy"], r["files"], r["bytes"]) for r in rows],
                         [(new, "PHONE-1", False, 1, 2), ("20261001-120000", None, True, 1, 3)])

    def restore(self, ph, name):
        self.c.r.update(gameId=G, backup=name)
        with patch.object(program_pack, "enabled", lambda c: True), patch.object(install, "phone_for", lambda c: ph), \
                patch.object(install, "trace", lambda *a, **k: None):
            return install.restore_phone_save(self.c)

    def test_restore_writes_backup_and_removes_extra(self):
        ph = FakePhone(self.c); ph.saves = {"a.dat": b"old-a", "b.dat": b"old-b"}
        target = self.snap(ph)[G]
        ph.saves = {"a.dat": b"new-a", "c.dat": b"new-c"}   # 之后手机上又玩过：a 变了、b 没了、多出 c
        r = self.restore(ph, target)
        self.assertEqual(r["restored"], target)
        self.assertNotEqual(r["safetyBackup"], target, "还原前先把手机现在的存档留了一份")
        base = f"{install.game_docs(G)}/{install.SAVE_REL}"
        self.assertEqual(sorted(op[:2] for op in ph.cl.ops if op[0] == "put"), [("put", f"{base}/a.dat"), ("put", f"{base}/b.dat")])
        self.assertEqual([op for op in ph.cl.ops if op[0] == "rm"], [("rm", f"{base}/c.dat")])
        self.assertEqual({op[1]: op[2] for op in ph.cl.ops if op[0] == "put"}[f"{base}/a.dat"], b"old-a")

    def test_restore_refuses_when_running_or_bad_name(self):
        ph = FakePhone(self.c); ph.saves = {"a.dat": b"v"}
        name = self.snap(ph)[G]
        ph.running = True
        with self.assertRaises(Failure) as e:
            self.restore(ph, name)
        self.assertEqual(e.exception.code, "phone_app_running")
        self.assertEqual(ph.cl.ops, [])
        ph.running = False
        for bad in ("../x", "", ".hidden", "不存在"):
            with self.assertRaises(Failure) as e:
                self.restore(ph, bad)
            self.assertEqual(e.exception.code, "save_invalid")

    def test_push_game_and_install_shell_snapshot_first(self):
        # 推一款、装壳两个作业开头都先拉存档（签名 / 组壳之前）；拉存档那步用哨兵截住，后面的不跑
        import ipa as packer
        B = "0100000000020000"
        layout.save_device(self.c, "PHONE-1", dict(shellId="SNOW", bundleId="io.example.one", games={G: {}, B: {}}))
        ph = FakePhone(self.c); ph.bid = "io.example.one"
        seen = []
        class Stop(Exception):
            pass
        def stop(c, p, games):
            seen.append((p.key, sorted(games))); raise Stop
        def no_sign(*a, **k):
            raise AssertionError("先拉存档再签名")
        with patch.object(install, "snapshot_phone_saves", stop), patch.object(install, "phone_signing", no_sign), \
                patch.object(install, "ios_pack", lambda c, g: None), patch.object(packer, "current_shell_id", lambda c: "SNOW"), \
                patch.object(packer, "assemble_shell", no_sign):
            with self.assertRaises(Stop):
                install.push_game(self.c, G.lower(), ph)
            with self.assertRaises(Stop):
                install.install_shell(self.c, ph)
        self.assertEqual(seen, [("PHONE-1", [G]), ("PHONE-1", sorted([G, B]))])


if __name__ == "__main__":
    unittest.main()
