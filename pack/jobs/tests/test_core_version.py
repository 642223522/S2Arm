import json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from core import display_version, release_version


class ReleaseVersion(unittest.TestCase):
    """三端同号的唯一来源：发布快照读 engine.json 的 version；开发树取最近 tag 的数字段（期望按手写夹具）"""
    def test_snapshot_reads_engine_json(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "engine.json").write_text(json.dumps({"schema": 1, "version": "0.2.3"}))
            self.assertEqual(release_version(d), "0.2.3")

    def test_dev_tree_uses_latest_tag_numbers(self):
        with tempfile.TemporaryDirectory() as d:
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
            for args in (["init", "-q"], ["commit", "-q", "--allow-empty", "-m", "x"], ["tag", "v0.3.1-beta.2"]):
                subprocess.run(["git", "-C", d, *args], check=True, env=env)
            self.assertEqual(release_version(d), "0.3.1")

    def test_nothing_known_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(release_version(d), "")


class DisplayVersion(unittest.TestCase):
    """界面版本字（11-11 维护者，三端同口径）：正式版 v0.3.0；开发版 v<最近 tag 数字段>-dev+<7 位短提交号>。
    期望手写：提交号用 git rev-parse 现取（不经被测实现），其余字面量"""
    ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}

    def git(self, d, *args):
        return subprocess.run(["git", "-C", d, "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args],
                              check=True, env=self.ENV, capture_output=True, text=True).stdout.strip()

    def repo_on_tag(self, d):   # 一个已跟踪文件 + 发版 tag v0.3.0 落在 HEAD
        Path(d, "a.txt").write_text("1")
        self.git(d, "init", "-q"); self.git(d, "add", "a.txt"); self.git(d, "commit", "-q", "-m", "x"); self.git(d, "tag", "v0.3.0")

    def test_snapshot_reads_engine_json(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "engine.json").write_text(json.dumps({"schema": 1, "version": "0.2.6", "displayVersion": "v0.2.6-dev+ba0ef07"}))
            self.assertEqual(display_version(d), "v0.2.6-dev+ba0ef07")

    def test_on_tag_clean_is_release(self):
        with tempfile.TemporaryDirectory() as d:
            self.repo_on_tag(d)
            Path(d, "untracked.txt").write_text("u")   # 未跟踪文件不算改动
            self.assertEqual(display_version(d), "v0.3.0")

    def test_on_tag_with_changes_is_dev(self):
        with tempfile.TemporaryDirectory() as d:
            self.repo_on_tag(d)
            Path(d, "a.txt").write_text("2")
            self.assertEqual(display_version(d), "v0.3.0-dev+" + self.git(d, "rev-parse", "--short=7", "HEAD")[:7])

    def test_after_tag_is_dev(self):
        with tempfile.TemporaryDirectory() as d:
            self.repo_on_tag(d)
            self.git(d, "commit", "-q", "--allow-empty", "-m", "y")
            sha = self.git(d, "rev-parse", "HEAD")[:7]
            self.assertEqual(display_version(d), f"v0.3.0-dev+{sha}")

    def test_no_git_falls_back_to_release_version(self):   # 旧快照：engine.json 只有 version、目录不是 Git 库
        with tempfile.TemporaryDirectory() as d:
            Path(d, "engine.json").write_text(json.dumps({"schema": 1, "version": "0.2.3"}))
            self.assertEqual(display_version(d), "v0.2.3")

    def test_nothing_known_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(display_version(d), "")


if __name__ == "__main__":
    unittest.main()
