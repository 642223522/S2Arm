import sys, unittest
import unittest.mock as um
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ipa as packer
import layout
from core import Failure
import tests.test_jobs as tj
from tests.jobcase import ios_fixture


class LibraryIpa(unittest.TestCase):
    """#360：出 iPhone 包成功就把默认位置根 S2Arm.ipa 换成含库里本版能用的全部各款的容器（期望按夹具手写）"""
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown
    A, B, C = "0100000000010000", "0100000000020000", "0100000000030000"

    def refresh(self, assembled, fail=False):
        def assemble(c, gid, others=(), **kw):
            assembled.append((gid, list(others)))
            if fail:
                raise Failure("组不起来", code="container_stale")
            d = Path(c.library) / ".container-t"; d.mkdir(exist_ok=True)
            ipa = d / "S2Arm.ipa"; ipa.write_bytes(("IPA" + ",".join(others)).encode())
            return ipa, list(others), "SID1"
        with um.patch.object(packer, "current_shell_id", return_value="SID1"), um.patch.object(packer, "assemble", assemble), \
             um.patch.object(packer, "ipa_games", return_value=([], "SID1")):
            return packer.refresh_library_ipa(self.c)

    def test_root_ipa_holds_every_ready_game(self):
        ios_fixture(self.c, self.A, shell="SID1"); ios_fixture(self.c, self.B, shell="SID1")   # C 没出过 iPhone 版 → 不带
        self.c.catalog = lambda: {"games": [{"id": g, "name": g} for g in (self.A, self.B, self.C)]}
        assembled = []
        self.assertEqual(self.refresh(assembled), layout.phone_ipa(self.c))
        self.assertEqual(assembled, [(None, [self.A, self.B])])
        self.assertEqual(layout.phone_ipa(self.c).read_bytes(), f"IPA{self.A},{self.B}".encode())

    def test_assembly_failure_only_warns_and_keeps_old_ipa(self):
        ios_fixture(self.c, self.A, shell="SID1")
        self.c.catalog = lambda: {"games": [{"id": self.A, "name": "A"}]}
        old = layout.phone_ipa(self.c); old.parent.mkdir(parents=True, exist_ok=True); old.write_bytes(b"OLD")
        warned = []
        with um.patch.object(self.c, "diagnostic", lambda msg, **kw: warned.append(kw.get("severity"))):
            self.assertIsNone(self.refresh([], fail=True))
        self.assertEqual((old.read_bytes(), warned), (b"OLD", ["warning"]))

    def test_nothing_ready_leaves_root_alone(self):
        self.c.catalog = lambda: {"games": [{"id": self.A, "name": "A"}]}
        assembled = []
        self.refresh(assembled)
        self.assertEqual(assembled, [])
        self.assertFalse(layout.phone_ipa(self.c).exists())


if __name__ == "__main__":
    unittest.main()
