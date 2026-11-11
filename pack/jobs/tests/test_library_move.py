"""换游戏库：打开已有的、认领旧产物、搬家（同盘 / 跨盘）和失败回滚。"""
import hashlib
import json
import os
import sys
import tempfile
import unittest
import unittest.mock as um
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import library
from core import Failure

GID = "0100000000010000"


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


class MoveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.private = self.root / "private"; self.private.mkdir()

    def ctx(self, library_path, **request):
        notes = []
        c = SimpleNamespace(library=library_path, private=self.private, engine=self.root / "engine", r=request, begin=lambda *a, **k: None, check=lambda: None,
                            progress=lambda *a: None, redact=lambda s: s, diagnostic=lambda m, **k: notes.append(m), notes=notes)
        return c

    def old(self, name="old"):
        lib = self.root / name; (lib / "saves" / GID).mkdir(parents=True); (lib / "iPhone" / GID / "t资源包").mkdir(parents=True); (lib / "games" / GID).mkdir(parents=True)
        (lib / ".s2arm-library.json").write_text(json.dumps({"schema": 1, "id": "library-id"}))
        (lib / "catalog.json").write_text(json.dumps({"schema": 1, "games": [{"id": GID, "name": "甲", "display": "", "packages": []}]}))
        (lib / "saves" / GID / "save.bin").write_bytes(b"save-data-1234")
        (lib / "iPhone" / GID / "t.ipa").write_bytes(b"ipa" * 1000)
        (lib / "iPhone" / GID / "t资源包" / "romfs.img").write_bytes(b"pack" * 100)
        (lib / ".s2arm-work" / "cache" / "air").mkdir(parents=True); (lib / ".s2arm-work" / "cache" / "air" / "shader.bin").write_bytes(b"shader")
        (lib / ".execution.lock").write_text(""); (lib / ".catalog.lock").write_text("")
        return lib

    def run_setup(self, target, **request):
        with um.patch.object(library, "require_apfs"), um.patch.object(library, "require_local"):
            return library.setup(self.ctx(target, **request))

    def assert_moved(self, old, new):
        self.assertEqual(sha(new / "saves" / GID / "save.bin"), hashlib.sha256(b"save-data-1234").hexdigest())
        self.assertTrue((new / "iPhone" / GID / "t.ipa").is_file())
        self.assertTrue((new / "iPhone" / GID / "t资源包" / "romfs.img").is_file())
        self.assertTrue((new / ".s2arm-work" / "cache" / "air" / "shader.bin").is_file())
        self.assertEqual(json.loads((new / "catalog.json").read_text())["games"][0]["id"], GID)
        self.assertFalse((old / "iPhone").exists()); self.assertFalse((new / ".s2arm-moving").exists())

    def assert_untouched(self, old, new):
        self.assertEqual((old / "saves" / GID / "save.bin").read_bytes(), b"save-data-1234")
        self.assertTrue((old / "iPhone" / GID / "t.ipa").is_file()); self.assertTrue((old / ".s2arm-library.json").is_file())
        self.assertFalse((new / ".s2arm-library.json").exists()); self.assertFalse((new / ".s2arm-moving").exists())

    def test_opens_existing_library(self):
        lib = self.old("lib")
        r = self.run_setup(lib)
        self.assertEqual((r["outcome"], r["libraryId"]), ("opened", "library-id"))

    def test_empty_folder_without_move_is_new_and_empty(self):
        r = self.run_setup(self.root / "fresh")
        self.assertEqual(r["outcome"], "created")
        self.assertEqual(json.loads((self.root / "fresh/catalog.json").read_text())["games"], [])

    def test_adopts_copied_products_with_their_catalog(self):
        lib = self.old("copied"); (lib / ".s2arm-library.json").unlink()
        r = self.run_setup(lib)
        self.assertEqual(r["outcome"], "adopted"); self.assertTrue(r["libraryId"])
        self.assertEqual(json.loads((lib / "catalog.json").read_text())["games"][0]["name"], "甲")

    def test_adopts_products_without_a_catalog(self):
        lib = self.old("copied"); (lib / ".s2arm-library.json").unlink(); (lib / "catalog.json").unlink()
        self.assertEqual(self.run_setup(lib)["outcome"], "adopted")
        games = json.loads((lib / "catalog.json").read_text())["games"]
        self.assertEqual([g["id"] for g in games], [GID]); self.assertEqual(games[0]["name"], GID)

    def test_unrelated_folder_is_refused_and_left_alone(self):
        d = self.root / "docs"; d.mkdir(); (d / "a.txt").write_text("x")
        with self.assertRaises(Failure): self.run_setup(d)
        self.assertEqual([p.name for p in d.iterdir()], ["a.txt"])

    def test_same_volume_move(self):
        old, new = self.old(), self.root / "new"
        r = self.run_setup(new, moveFrom=str(old))
        self.assertEqual((r["outcome"], r["libraryId"]), ("moved", "library-id"))
        self.assert_moved(old, new)
        self.assertFalse(old.exists())

    @unittest.skipUnless(os.name == "nt", "Windows directory-handle sharing errors")
    def test_same_volume_rename_retries_after_temporary_lock(self):
        old, new = self.old(), self.root / "new"
        real, failures, sleeps = os.rename, [0], []

        def locked_once(src, dst):
            if Path(src) == old / "games" and not failures[0]:
                failures[0] += 1
                error = PermissionError(13, "Access is denied", str(src))
                error.winerror = 5
                raise error
            return real(src, dst)

        with um.patch.object(library, "_same_volume", return_value=True), \
             um.patch.object(library.os, "rename", locked_once), \
             um.patch.object(library.time, "sleep", sleeps.append):
            r = self.run_setup(new, moveFrom=str(old))
        self.assertEqual(failures, [1])
        self.assertEqual(sleeps, [library._LIBRARY_RENAME_RETRIES[0]])
        self.assertEqual((r["outcome"], r["libraryId"]), ("moved", "library-id"))
        self.assert_moved(old, new)
        self.assertFalse(old.exists())

    @unittest.skipUnless(os.name == "nt", "Windows directory-handle sharing errors")
    def test_same_volume_persistent_lock_times_out_and_preserves_source(self):
        old, new = self.old(), self.root / "new"
        real, refusals, sleeps = os.rename, [0], []

        def always_locked(src, dst):
            if Path(src) == old / "games":
                refusals[0] += 1
                error = PermissionError(13, "Access is denied", str(src))
                error.winerror = 32
                raise error
            return real(src, dst)

        with um.patch.object(library, "_same_volume", return_value=True), \
             um.patch.object(library.os, "rename", always_locked), \
             um.patch.object(library.time, "sleep", sleeps.append), \
             self.assertRaises(Failure) as caught:
            self.run_setup(new, moveFrom=str(old))
        self.assertEqual(caught.exception.code, "library_move_failed")
        self.assertIn("重试约 1 分钟", str(caught.exception))
        self.assertIn("资源管理器", str(caught.exception))
        self.assertIn("原游戏库仍保留在原位置", str(caught.exception))
        self.assertEqual(refusals, [len(library._LIBRARY_RENAME_RETRIES) + 1])
        self.assertEqual(sleeps, list(library._LIBRARY_RENAME_RETRIES))
        self.assert_untouched(old, new)
        self.assertEqual(list(new.iterdir()), [])

    def test_nonretryable_no_space_rename_fails_immediately_and_preserves_source(self):
        old, new = self.old(), self.root / "new"
        real, failed, sleeps = os.rename, [0], []

        def no_space(src, dst):
            if Path(src) == old / "games":
                failed[0] += 1
                raise OSError(28, "No space left on device", str(src))
            return real(src, dst)

        with um.patch.object(library, "_same_volume", return_value=True), \
             um.patch.object(library.os, "rename", no_space), \
             um.patch.object(library.time, "sleep", sleeps.append), \
             self.assertRaises(OSError) as caught:
            self.run_setup(new, moveFrom=str(old))
        self.assertEqual(caught.exception.errno, 28)
        self.assertEqual(failed, [1])
        self.assertEqual(sleeps, [])
        self.assert_untouched(old, new)
        self.assertEqual(list(new.iterdir()), [])

    @unittest.skipUnless(os.name == "nt", "Windows directory-handle sharing semantics")
    def test_windows_directory_handle_times_out_without_moving_source(self):
        import ctypes
        from ctypes import wintypes

        old, new = self.old(), self.root / "new"
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        create_file = kernel32.CreateFileW
        create_file.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        create_file.restype = wintypes.HANDLE
        close_handle = kernel32.CloseHandle
        close_handle.argtypes = [wintypes.HANDLE]
        close_handle.restype = wintypes.BOOL
        handle = create_file(str(old / "games"), 0x80000000, 0x1 | 0x2, None, 3, 0x02000000, None)
        self.assertNotEqual(handle, wintypes.HANDLE(-1).value)
        errors = []
        real = os.rename

        def observe_rename(src, dst):
            try:
                return real(src, dst)
            except PermissionError as error:
                errors.append(getattr(error, "winerror", None))
                raise

        try:
            with um.patch.object(library.os, "rename", observe_rename), \
                 um.patch.object(library.time, "sleep", lambda _: None), \
                 self.assertRaises(Failure) as caught:
                self.run_setup(new, moveFrom=str(old))
        finally:
            close_handle(handle)
        self.assertTrue(errors and errors[0] in (5, 32), errors)
        self.assertEqual(len(errors), len(library._LIBRARY_RENAME_RETRIES) + 1)
        self.assertIn("资源管理器", str(caught.exception))
        self.assert_untouched(old, new)
        self.assertEqual(list(new.iterdir()), [])

    def test_cross_volume_move(self):
        old, new = self.old(), self.root / "new"
        with um.patch.object(library, "_same_volume", return_value=False):
            r = self.run_setup(new, moveFrom=str(old))
        self.assertEqual(r["outcome"], "moved"); self.assert_moved(old, new); self.assertFalse(old.exists())

    def test_cross_volume_failed_verification_rolls_back(self):
        old, new = self.old(), self.root / "new"
        real = library._verify_copy
        def corrupt(src, dst, strict):
            if src.name == "saves": (dst / GID / "save.bin").write_bytes(b"damaged-data-!")
            real(src, dst, strict)
        with um.patch.object(library, "_same_volume", return_value=False), um.patch.object(library, "_verify_copy", corrupt), self.assertRaises(Failure) as e:
            self.run_setup(new, moveFrom=str(old))
        self.assertEqual(e.exception.code, "library_move_failed"); self.assert_untouched(old, new)

    def test_interrupted_rename_rolls_back(self):
        old, new = self.old(), self.root / "new"
        real, calls = os.rename, [0]
        def flaky(a, b):
            calls[0] += 1
            if calls[0] == 3: raise OSError(28, "no space")
            real(a, b)
        with um.patch.object(library.os, "rename", flaky), self.assertRaises(OSError):
            self.run_setup(new, moveFrom=str(old))
        self.assert_untouched(old, new)
        self.assertEqual(sorted(p.name for p in new.iterdir()), [])

    def test_not_enough_space_changes_nothing(self):
        old, new = self.old(), self.root / "new"
        usage = SimpleNamespace(free=0, total=1, used=1)
        with um.patch.object(library, "_same_volume", return_value=False), um.patch.object(library.shutil, "disk_usage", return_value=usage), self.assertRaises(Failure) as e:
            self.run_setup(new, moveFrom=str(old))
        self.assertEqual(e.exception.code, "disk_full"); self.assert_untouched(old, new)

    def test_refuses_a_target_inside_the_library(self):
        old = self.old()
        with self.assertRaises(Failure): self.run_setup(old / "inner", moveFrom=str(old))
        self.assertTrue((old / "iPhone" / GID / "t.ipa").is_file())

    def test_default_library_brings_private_caches_along(self):
        old = self.private / "lib"; old.parent.mkdir(exist_ok=True)
        src = self.old(); os.rename(src, old); new = self.root / "new"
        (self.private / "cache" / "pso").mkdir(parents=True); (self.private / "cache" / "pso" / "p.bin").write_bytes(b"pso")
        import shutil; shutil.rmtree(old / ".s2arm-work")
        self.run_setup(new, moveFrom=str(old))
        self.assertTrue((new / ".s2arm-work" / "cache" / "pso" / "p.bin").is_file())
        self.assertFalse((self.private / "cache").exists())

    def test_absolute_links_follow_the_move(self):
        old, new = self.old(), self.root / "new"
        os.symlink(old / "iPhone" / GID / "t.ipa", old / "iPhone" / GID / "current.ipa")
        self.run_setup(new, moveFrom=str(old))
        self.assertEqual(os.readlink(new / "iPhone" / GID / "current.ipa").removeprefix("\\\\?\\"), str(new / "iPhone" / GID / "t.ipa"))
        self.assertTrue((new / "iPhone" / GID / "current.ipa").is_file())


if __name__ == "__main__":
    unittest.main()
