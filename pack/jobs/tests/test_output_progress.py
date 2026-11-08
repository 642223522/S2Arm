"""子进程输出按 CR/LF 双切 + 「产物就绪即结束」（11-08 Mac 启动器 iOS 平台组件）。

xcodebuild -downloadPlatform 用 CR 原地刷新进度（十几分钟没有一个 LF），收尾注册步还会挂住；
按 readline() 读会把整段下载当一行、进度停在第一个 0.0%，按进程退出来判又会一直等。"""
import io
import sys
import time
import unittest
from unittest.mock import patch

from jobcase import JobCase
from core import output_lines


class OutputProgress(JobCase):
    def test_output_lines_splits_cr_lf_and_crlf(self):
        self.assertEqual(list(output_lines(io.BytesIO(b"a\rb\r\nc\nd"))), [b"a", b"b", b"c", b"d"])
        self.assertEqual(list(output_lines(io.BytesIO(b"tail"))), [b"tail"])

    def test_child_progress_with_cr_reaches_callback(self):
        seen = []
        self.c.run([sys.executable, "-c",
                    "import sys; sys.stdout.write('1%\\r50%\\r100%\\n'); sys.stdout.flush()"], on_line=seen.append)
        self.assertEqual(seen, ["1%", "50%", "100%"])

    def test_until_ends_child_that_hangs_after_product_ready(self):
        # 沙箱里 /bin/ps 不可用（signal_child 发信号前要核对进程组），这里只验证「until 一到就提前收」，
        # 收进程换成直接 terminate；signal_child 自己的核对有单独的测试。
        start = time.monotonic()
        with patch.object(type(self.c), "signal_child", lambda context, process, sig: process.terminate()):
            self.c.run([sys.executable, "-c", "import time; print('ready', flush=True); time.sleep(30)"],
                       until=lambda: True)
        self.assertLess(time.monotonic() - start, 15)
        self.assertFalse(self.c.children)

    def test_until_false_lets_child_finish(self):
        seen = []
        self.c.run([sys.executable, "-c", "print('ok', flush=True)"], on_line=seen.append, until=lambda: False)
        self.assertEqual(seen, ["ok"])


if __name__ == "__main__":
    unittest.main()
