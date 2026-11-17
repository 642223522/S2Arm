# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""游戏程序常驻与现建（pack/jobs/programs.py）：玩家删了游戏文件夹 / 释放了 iPhone 包和出包缓存，更新 S2Arm 时照样带得上这款。
期望按规格手写（改写器用替身：按「模块原始字节」出确定的产物；真改写器的逐字节对拍见常驻库验收）：
  ① 出包存下：常驻 .programs/<号>/ 有 exefs.tar.zst、recipe.tar.zst、ios.json；配方里没有原始程序各模块的改写产物，其余（表、npdm、ctl）都在
  ② 程序缓存删掉后：按配方现建，产物 = 替身改写器按原始程序出的那份，表与原 kit 逐字节同；社区补丁行表非空时交给改写器（S2A_CPATCH_TSV）
  ③ 游戏文件夹与程序缓存都删掉：usable_kit 照样认（现建）
  ④ 旧布局（image/ios/kit、original-exefs）第一次用到时进常驻、旧位置删掉，缓存里的 kit 与原来逐字节同
  ⑤ 没存原始程序的老款：整份 kit 进配方（推不出产物）
  ⑥ 释放空间：iPhone 包只列资源包；程序缓存列在「着色器与出包缓存」"""
import io
import jobcase  # noqa: E402（作业上下文替身统一工厂 jobcase.fake_context）
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ipa
import layout
import library
import programs
import rewrite_refresh
import sgrade

GID = "0100000000010000"


def fake_rewrite(binary, env, exefs, out, widen):
    """替身改写器：<模块>.patched.bin = b"P" + 原始字节，fixups / gates 记下补丁行表有没有交进来"""
    seen = "rows" if env.get("S2A_CPATCH_TSV") else "-"
    for m in programs.exefs_modules(exefs):
        (Path(out) / f"{m}.patched.bin").write_bytes(b"P" + (Path(exefs) / m).read_bytes())
        (Path(out) / f"{m}.fixups.tsv").write_text(seen)
        (Path(out) / f"{m}.gates.tsv").write_text(m)
    return []


class ProgramStoreTests(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(prefix="s2arm programs ")
        self.addCleanup(t.cleanup)
        self.root = Path(t.name)
        self.c = jobcase.fake_context(self.root, library=self.root / "library", work_root=self.root / "work", engine=self.root, env=lambda: {})
        self.c.library.mkdir()
        (self.root / "pack").symlink_to(Path(programs.__file__).resolve().parents[1], target_is_directory=True)   # 替身引擎根也带 pack（换目录从 c.engine 导入 pack.orch）
        self.store = self.c.library / ".programs" / GID
        self.cache = self.root / "work/cache/programs" / GID
        for p in (mock.patch.object(rewrite_refresh, "rewrite_modules", fake_rewrite), mock.patch.object(rewrite_refresh, "rewriter_bin", lambda c: "rw"),
                  mock.patch.object(rewrite_refresh, "rewrite_env", lambda c, kit, exefs, target: {})):
            p.start(); self.addCleanup(p.stop)

    def exefs(self):
        d = self.root / "exefs"; d.mkdir(exist_ok=True)
        (d / "main").write_bytes(bytes(0x60) + b"main"); (d / "main.npdm").write_bytes(b"npdm"); (d / "sdk").write_bytes(b"sdk")
        return d

    def product(self, rows=""):
        """出包产物根：原始程序两个模块的改写产物（同替身改写器出的）+ 表"""
        root = self.root / "product"
        (root / "ctl").mkdir(parents=True, exist_ok=True)
        ex = self.exefs()
        fake_rewrite(None, {"S2A_CPATCH_TSV": "x"} if rows else {}, ex, root, None)
        for n, v in (("main.npdm", "npdm"), ("ctl/control.nacp", "nacp"), ("cpatch.tsv", "表"), ("cpatch_rows.tsv", rows), ("widen_sites.tsv", "w")):
            (root / n).write_text(v)
        return root

    def names(self, arc):
        with tarfile.open(fileobj=io.BytesIO(programs._decompress(arc.read_bytes()))) as t:
            return sorted(m.name for m in t.getmembers())

    def export(self, rows=""):
        sgrade.save_program(self.c, GID, self.exefs())
        return library.save_container_kit(self.c, GID, self.product(rows))

    def test_store_holds_program_and_recipe_only(self):
        kit = self.export()
        layout.update_info(self.c, GID, ios=dict(shellId="S1"))
        self.assertEqual(kit, self.cache / "kit")
        self.assertEqual(sorted(p.name for p in self.store.iterdir()), ["exefs.tar.zst", "ios.json", "recipe.tar.zst"])
        self.assertEqual(self.names(self.store / "exefs.tar.zst"), ["main", "main.npdm", "sdk"])
        self.assertEqual(self.names(self.store / "recipe.tar.zst"), ["cpatch.tsv", "cpatch_rows.tsv", "ctl/control.nacp", "main.npdm", "widen_sites.tsv"])
        self.assertFalse((layout.find_game(self.c, GID) / "image/ios/kit").exists())

    def test_romfs_image_is_not_a_program_part(self):
        # RomFS 直出后产物根顶层多了游戏资源镜像 romfs.std（原先是 romfs/ 目录）：它不进程序缓存，也不进常驻配方
        product = self.product(); (product / "romfs.std").write_bytes(b"R" * 4096)
        sgrade.save_program(self.c, GID, self.exefs())
        kit = library.save_container_kit(self.c, GID, product)
        self.assertFalse((kit / "romfs.std").exists())
        self.assertNotIn("romfs.std", self.names(self.store / "recipe.tar.zst"))

    def test_rebuild_works_beside_the_kit_even_when_cache_was_cleared(self):
        # 期望手写：程序缓存整个被清掉（连 cache/programs 都不在）后现建，临时目录建在 kit 的同级（同卷），不落系统临时目录——
        #   游戏库在别的盘时跨卷 os.replace 会报 WinError 17 / EXDEV（11-16 Windows 实机实测）。现建出的 kit 照样完整
        self.export()
        shutil.rmtree(self.root / "work/cache")
        real, dirs = tempfile.mkdtemp, []
        def mkdtemp(*a, **k):
            dirs.append(k.get("dir")); return real(*a, **k)
        with mock.patch.object(programs.tempfile, "mkdtemp", mkdtemp):
            kit = programs.rebuild(self.c, GID)
        self.assertEqual(dirs, [self.cache.parent]); self.assertTrue((kit / "main.npdm").is_file())

    def test_sgrade_state_survives_rebuild(self):
        # 期望手写：出包收尾写进 kit 的 sgrade_state.json（ipa.finish_kit_state）进常驻配方；缓存清掉后按配方现建的 kit 里照样有、内容相同
        self.export()
        def write_state(c, gid, kit):
            (Path(kit) / "sgrade_state.json").write_text('{"schema": 1}')
        with mock.patch.object(sgrade, "write_kit_state", write_state):
            ipa.finish_kit_state(self.c, GID)
        shutil.rmtree(self.cache)
        kit = layout.ios_kit(self.c, GID)
        self.assertEqual((kit / "sgrade_state.json").read_text(), '{"schema": 1}')

    def test_resource_images_stay_out_unknown_small_files_stay_in(self):
        # 期望手写：资源镜像这一小类封闭集合（romfs.std / game.img / *.nsp / *.xci / *.nca，大小写不论）不进程序件也不进配方；
        #   不认识的小文件照常进（不是白名单：程序件有约 30 种、读写方各不相同，漏一项升级就坏）
        product = self.product()
        res = ("romfs.std", "game.img", "base.nsp", "card.XCI", "x.nca")
        for n in res:
            (product / n).write_bytes(b"R" * 64)
        (product / "new_table.tsv").write_text("新表")
        sgrade.save_program(self.c, GID, self.exefs())
        kit = library.save_container_kit(self.c, GID, product)
        recipe = self.names(self.store / "recipe.tar.zst")
        for n in res:
            self.assertFalse((kit / n).exists(), n); self.assertNotIn(n, recipe)
        self.assertEqual((kit / "new_table.tsv").read_text(), "新表"); self.assertIn("new_table.tsv", recipe)

    def test_oversized_kit_is_loud_and_names_the_biggest_file(self):
        # 期望手写（阈值换成 1000 字节）：除改写产物外合计超过阈值 → 报 kit_oversized（告警、不拦），点名最大的文件；
        #   改写产物（main.patched.bin 再大）不算；没超过不报
        said = []
        self.c.diagnostic = lambda msg, code="job_failed", severity="error", **kw: said.append((code, severity, msg))
        product = self.product()
        (product / "main.patched.bin").write_bytes(b"P" * 5000)
        sgrade.save_program(self.c, GID, self.exefs())
        with mock.patch.object(library, "KIT_LOUD_BYTES", 1000):
            library.save_container_kit(self.c, GID, product)
            self.assertEqual(said, [])
            (product / "mystery.bin").write_bytes(b"M" * 2000)
            kit = library.save_container_kit(self.c, GID, product)
        self.assertEqual([(c, s) for c, s, _ in said], [("kit_oversized", "warning")])
        self.assertIn("mystery.bin", said[0][2])
        self.assertTrue((kit / "mystery.bin").is_file())   # 只报不拦：照常存

    def test_cache_deleted_rebuilds_same_kit(self):
        for rows, seen in (("", "-"), ("p main 1 2 3 # x\n", "rows")):
            with self.subTest(rows=bool(rows)):
                shutil.rmtree(self.store, ignore_errors=True); shutil.rmtree(self.cache, ignore_errors=True)
                kit = self.export(rows)
                before = {p.relative_to(kit).as_posix(): p.read_bytes() for p in kit.rglob("*") if p.is_file()}
                shutil.rmtree(self.cache)
                rebuilt = layout.ios_kit(self.c, GID)
                after = {p.relative_to(rebuilt).as_posix(): p.read_bytes() for p in rebuilt.rglob("*") if p.is_file()}
                self.assertEqual(after, before)
                self.assertEqual((rebuilt / "main.fixups.tsv").read_text(), seen)

    def test_game_folder_and_cache_deleted_kit_still_usable(self):
        self.export()
        layout.update_info(self.c, GID, ios=dict(shellId="S1"))
        shutil.rmtree(layout.find_game(self.c, GID)); shutil.rmtree(self.cache)
        self.assertIsNone(layout.find_game(self.c, GID))
        self.assertTrue(layout.has_ios_kit(self.c, GID))
        self.assertEqual(Path(ipa.usable_kit(self.c, GID, "S1")).resolve(), (self.cache / "kit").resolve())
        self.assertEqual((self.cache / "kit/main.patched.bin").read_bytes(), b"P" + bytes(0x60) + b"main")
        self.assertEqual(sgrade.saved_program(self.c, GID), self.cache / "exefs")

    def test_legacy_layout_moves_into_the_store(self):
        product = self.product()
        game = layout.game_dir(self.c, GID)
        shutil.copytree(product, game / "image/ios/kit"); shutil.copytree(self.exefs(), game / "original-exefs")
        want = {p.relative_to(product).as_posix(): p.read_bytes() for p in product.rglob("*") if p.is_file()}
        kit = layout.ios_kit(self.c, GID)
        self.assertEqual({p.relative_to(kit).as_posix(): p.read_bytes() for p in kit.rglob("*") if p.is_file()}, want)
        self.assertFalse((game / "image/ios/kit").exists()); self.assertFalse((game / "original-exefs").exists())
        self.assertNotIn("main.patched.bin", self.names(self.store / "recipe.tar.zst"))

    def test_catalog_badge_never_migrates(self):
        # 11-16 Windows 0.4.4 → 0.5.0 首启：清单画金色 S 调到迁移，与后台作业撞上 WinError 32、整个清单读失败。
        #   期望手写：旧布局里带宽屏已验证表的款照亮 S，但清单里一步迁移都不做（旧位置原样在、常驻没有归档、kit_dir 没被调）
        product = self.product(); (product / "widen_verified.tsv").write_text("x")
        game = layout.game_dir(self.c, GID)
        shutil.copytree(product, game / "image/ios/kit"); shutil.copytree(self.exefs(), game / "original-exefs")
        with mock.patch.object(programs, "kit_dir", side_effect=AssertionError("清单里不该迁移 / 现建")):
            self.assertTrue(library.sgrade_badge(self.c, GID, self.root / "no-mac-image"))
        self.assertTrue((game / "image/ios/kit/main.npdm").is_file()); self.assertFalse((self.store / "exefs.tar.zst").exists())
        shutil.rmtree(game / "image/ios/kit")   # 一份程序件都没有：不亮、不报错
        self.assertFalse(library.sgrade_badge(self.c, GID, self.root / "no-mac-image"))

    def test_migration_holds_its_own_lock(self):
        # 并发第一次用到同一款：迁移整段持 programs-migrate-<号>（不是交付 / 装机持着的 program-<号>，那把不可重入）
        import contextlib
        taken = []
        @contextlib.contextmanager
        def lock(name, wait=None):
            taken.append(name); yield
        self.c.lock = lock
        game = layout.game_dir(self.c, GID)
        shutil.copytree(self.product(), game / "image/ios/kit"); shutil.copytree(self.exefs(), game / "original-exefs")
        layout.ios_kit(self.c, GID)
        self.assertEqual(taken, ["programs-migrate-" + GID])

    def test_two_concurrent_first_uses_migrate_once(self):
        # 真并发（11-16 Windows 升级首启：清单与两单作业同一秒迁移同一款撞 WinError 32）：两个线程同时第一次用到同一款旧布局，
        #   用真文件锁（filelock.held，同 c.lock）。期望手写：原始程序只存一次（第二个等第一个搬完、再看已没有旧件）；两边都拿到同一份完整 kit；
        #   旧位置删掉、没有 .partial / .old- 残留、没有异常
        import contextlib, filelock, threading
        @contextlib.contextmanager
        def lock(name, wait=None):
            with filelock.held(self.c.library / f".{name}.lock", wait_s=60):
                yield
        self.c.lock = lock
        game = layout.game_dir(self.c, GID)
        shutil.copytree(self.product(), game / "image/ios/kit"); shutil.copytree(self.exefs(), game / "original-exefs")
        real, saves = programs.save_exefs, []
        def slow_save(c, gid, exefs):   # 拉长迁移，两个线程必然重叠
            saves.append(threading.get_ident()); threading.Event().wait(0.3); return real(c, gid, exefs)
        got, errs, start = {}, [], threading.Barrier(2)
        def use(i):
            try:
                start.wait(); got[i] = layout.ios_kit(self.c, GID)
            except BaseException as e:
                errs.append(e)
        with mock.patch.object(programs, "save_exefs", slow_save):
            ts = [threading.Thread(target=use, args=(i,)) for i in range(2)]
            [t.start() for t in ts]; [t.join(30) for t in ts]
        self.assertEqual(errs, []); self.assertEqual(len(saves), 1)
        self.assertEqual(got[0], got[1]); self.assertTrue((got[0] / "main.npdm").is_file())
        self.assertFalse((game / "image/ios/kit").exists()); self.assertFalse((game / "original-exefs").exists())
        left = [p for p in self.root.rglob("*") if ".partial" in p.name or ".old-" in p.name]
        self.assertEqual(left, [])

    def test_archive_write_is_safe_when_target_is_busy(self):
        # 期望手写：同一内容再写一遍不换文件（别的进程正开着读也不碰它）；Windows 换文件被占（WinError 32）退避后成功，临时文件不留
        programs.save_exefs(self.c, GID, self.exefs())   # 直接测写归档这一层（sgrade.save_program 主程序没变就不写）
        arc = self.store / "exefs.tar.zst"; first = arc.read_bytes()
        with mock.patch.object(programs, "_replace_file", side_effect=AssertionError("同一内容不该再换")):
            programs.save_exefs(self.c, GID, self.exefs())
        self.assertEqual(arc.read_bytes(), first)
        busy = PermissionError(13, "另一个程序正在使用此文件"); busy.winerror = 32
        real, calls = os.replace, []
        def replace(a, b):   # 只数换归档那一下（save_exefs 换缓存目录也走 os.replace）
            if str(b).endswith("exefs.tar.zst"):
                calls.append(1)
                if len(calls) == 1:
                    raise busy
            return real(a, b)
        ex = self.exefs(); (ex / "sdk").write_bytes(b"sdk v2")   # 内容变了，要换（exefs() 每次重写原样，改要在它之后）
        with mock.patch.object(programs, "REPLACE_RETRIES", (0,)), mock.patch("os.replace", replace):
            programs.save_exefs(self.c, GID, ex)
        self.assertEqual(len(calls), 2); self.assertNotEqual(arc.read_bytes(), first)
        self.assertEqual([p.name for p in self.store.iterdir() if p.name.endswith(".partial")], [])

    def test_legacy_kit_that_does_not_rebuild_the_same_keeps_whole_kit(self):
        # 旧 kit 的改写产物和按配方现建的对不上（老版本改写器出的 / S 级补进时没同步补丁行表）：整份 kit 进配方，现建出来与原 kit 逐字节同
        product = self.product()
        (product / "main.patched.bin").write_bytes(b"old rewriter output")
        game = layout.game_dir(self.c, GID)
        shutil.copytree(product, game / "image/ios/kit"); shutil.copytree(self.exefs(), game / "original-exefs")
        layout.ios_kit(self.c, GID)
        self.assertIn("main.patched.bin", self.names(self.store / "recipe.tar.zst"))
        shutil.rmtree(self.cache)
        self.assertEqual((layout.ios_kit(self.c, GID) / "main.patched.bin").read_bytes(), b"old rewriter output")

    def test_no_saved_program_keeps_whole_kit_in_recipe(self):
        library.save_container_kit(self.c, GID, self.product())
        self.assertIn("main.patched.bin", self.names(self.store / "recipe.tar.zst"))
        shutil.rmtree(self.cache)
        self.assertEqual((layout.ios_kit(self.c, GID) / "main.patched.bin").read_bytes(), b"P" + bytes(0x60) + b"main")

    def test_free_space_parts(self):
        self.export()
        pack = layout.image_ios(self.c, GID) / ".pack"; pack.mkdir(parents=True); (pack / "manifest.json").write_text("{}")
        with mock.patch.object(library, "game_caches", lambda c, gid: []):
            parts = library.space_parts(self.c, GID)
        self.assertEqual(parts["ipa"], [pack])
        self.assertEqual(parts["shaders"], [self.cache])


class PutDir(unittest.TestCase):
    """换目录（programs._put_dir）：期望手写——旧的整份被新的取代、不留挪开的旧目录；Windows 上改名被拒（WinError 5，杀软扫描）退避重试后成功"""
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t, True)
        self.part, self.dest = self.t / "kit.partial", self.t / "kit"
        self.part.mkdir(); (self.part / "new.txt").write_text("新")
        self.dest.mkdir(); (self.dest / "old.txt").write_text("旧")
        self.c = SimpleNamespace(engine=Path(programs.__file__).resolve().parents[2])   # 仓库树里引擎根 = 仓库根

    def test_existing_dest_is_replaced_whole(self):
        programs._put_dir(self.c, self.part, self.dest)
        self.assertEqual(sorted(p.name for p in self.dest.iterdir()), ["new.txt"])
        self.assertEqual(sorted(p.name for p in self.t.iterdir()), ["kit"])   # 没留 kit.partial / kit.old-*

    def test_busy_rename_is_retried_on_windows(self):
        sys.path.append(str(Path(programs.__file__).resolve().parents[2]))
        from pack.orch import dirrename
        real, calls = Path.rename, []
        def rename(src, dst):
            calls.append(src.name)
            if len(calls) == 1:
                raise PermissionError(13, "被占用")   # 没有 winerror 属性按 5 认（同 dirrename）
            return real(src, dst)
        with mock.patch.object(dirrename, "os", SimpleNamespace(name="nt")), mock.patch.object(dirrename, "DIR_RENAME_RETRIES", (0, 0)), \
             mock.patch.object(Path, "rename", rename):
            programs._put_dir(self.c, self.part, self.dest)
        self.assertEqual(calls, ["kit", "kit", "kit.partial"])   # 挪开旧的：第一次被拒、第二次成功；再把新的改名就位
        self.assertEqual((self.dest / "new.txt").read_text(), "新")

    def test_app_layout_imports_from_engine_root(self):
        # App 里作业层（Resources/Jobs）和引擎（Resources/Engine）是兄弟目录：按本文件位置往上推找不到 pack，
        # 必须从 c.engine 导入（11-16 第 4 份候选出包即 No module named 'pack'）。独立进程、只把作业层放进 sys.path，同作业主程序
        res = self.t / "Resources"; jobs = res / "Jobs"
        shutil.copytree(Path(programs.__file__).resolve().parent, jobs, ignore=shutil.ignore_patterns("tests", "__pycache__"))
        (res / "Engine").symlink_to(self.c.engine, target_is_directory=True)
        code = ("import sys; from pathlib import Path; from types import SimpleNamespace; import programs; "
                "t = Path(sys.argv[1]); programs._put_dir(SimpleNamespace(engine=Path(sys.argv[2])), t / 'kit.partial', t / 'kit'); "
                "print(sorted(p.name for p in (t / 'kit').iterdir()))")
        r = subprocess.run([sys.executable, "-I", "-c", f"import sys; sys.path.insert(0, {str(jobs)!r}); exec({code!r})", str(self.t), str(res / "Engine")],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr[-600:])
        self.assertEqual(r.stdout.strip(), "['new.txt']")


if __name__ == "__main__":
    unittest.main()
